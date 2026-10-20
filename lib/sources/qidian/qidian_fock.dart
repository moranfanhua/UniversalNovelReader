import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../domain/models.dart';
import '../native_chapter_crypto.dart';

/// Independent implementation of the Android App's libfock chapter container.
/// Keys stay in memory and are bound to the requesting device and book version.
class QidianReadingKey {
  QidianReadingKey({required this.version, required this.encrypted});
  final String version;
  final Uint8List encrypted;

  factory QidianReadingKey.fromJson(Map<String, dynamic> data) {
    try {
      final version = '${data['Version']}';
      final bytes = base64Decode(data['Key'] as String);
      if (!RegExp(r'^[1-9]\d{0,9}$').hasMatch(version) ||
          bytes.isEmpty ||
          bytes.length % 16 != 0) {
        throw const FormatException();
      }
      return QidianReadingKey(version: version, encrypted: bytes);
    } catch (_) {
      throw const SourceException('起点阅读密钥格式无效，请重试');
    }
  }
}

class QidianFock {
  // Derived from the official 7.9.480 APK's fixed interoperability profile.
  static const _salt = 'TAOO8ZUCX129QZU5';
  static const _algorithms = <int, String>{
    0x1425033: 'AA',
    0x1427398: 'DA',
    0x1bfc2e4: 'CD',
    0x1c79ff4: 'AC',
    0x1de4727: 'DC',
    0x1e741d1: 'AD',
    0x20a5a31: 'CC',
    0x2152864: 'DD',
    0x5a76f73: 'CA',
  };

  static Uint8List _cbc(
    Uint8List input,
    Uint8List key, {
    bool des = false,
    bool padded = true,
  }) {
    return NativeChapterCrypto.decrypt(
      ChapterDecryptInput(
        data: input,
        key: des
            ? Uint8List.fromList(List.generate(24, (i) => key[i % 8]))
            : key,
        iv: Uint8List.sublistView(key, 0, des ? 8 : 16),
        cipher: des ? ChapterCipher.des3Cbc : ChapterCipher.aesCbc,
        padding: padded,
      ),
    );
  }

  static int _number(Uint8List bytes) {
    final zero = bytes.indexOf(0);
    final value = ascii.decode(zero < 0 ? bytes : bytes.sublist(0, zero));
    if (!RegExp(r'^\d+$').hasMatch(value)) throw const FormatException();
    return int.parse(value);
  }

  static void _checkDigest(Uint8List expected, List<int> value) {
    if (expected.every((b) => b == 0)) return;
    final actual = md5.convert(value).bytes;
    var difference = 0;
    for (var i = 0; i < 16; i++) {
      difference |= expected[i] ^ actual[i];
    }
    if (difference != 0) throw const FormatException();
  }

  static String decode(
    String content, {
    required String chapterId,
    required String device,
    required QidianReadingKey readingKey,
  }) {
    try {
      final bytes = base64Decode(content);
      if (bytes.length < 256) throw const FormatException();
      final root = Uint8List.fromList(
        sha256.convert(utf8.encode('$device$_salt')).bytes,
      );
      final header = _cbc(
        Uint8List.sublistView(bytes, 0, 256),
        root,
        padded: false,
      );
      final algorithm = _algorithms[_number(header.sublist(0, 8))];
      final index = _number(header.sublist(8, 16));
      final version = '${_number(header.sublist(16, 26))}';
      if (algorithm == null ||
          version != readingKey.version ||
          header[26] > 1) {
        throw const FormatException();
      }
      _checkDigest(header.sublist(43, 59), utf8.encode(device));
      final pool = _cbc(readingKey.encrypted, root);
      if (index >= pool.length ~/ 17) throw const FormatException();
      final material = <int>[
        ...pool.sublist(index * 17, index * 17 + 16),
        ...utf8.encode('$device$chapterId'),
      ];
      // Native hashing uses a NUL-terminated key string.
      final zero = material.indexOf(0);
      final key = Uint8List.fromList(
        sha256.convert(zero < 0 ? material : material.sublist(0, zero)).bytes,
      );
      var plain = header.skip(128).any((b) => b != 0)
          ? Uint8List.fromList([...header.skip(128), ...bytes.skip(256)])
          : Uint8List.sublistView(bytes, 256);
      for (final step in algorithm.split('')) {
        if (step == 'C') {
          // The App uses GCM update without a tag; its payload stream starts
          // at nonce || 2. Container MD5 is checked below before returning text.
          plain = NativeChapterCrypto.decrypt(
            ChapterDecryptInput(
              data: plain,
              key: key,
              iv: Uint8List.fromList([...key.take(12), 0, 0, 0, 2]),
              cipher: ChapterCipher.aesCtr,
              padding: false,
            ),
          );
        } else {
          plain = _cbc(plain, key, des: step == 'D');
        }
      }
      _checkDigest(header.sublist(27, 43), plain);
      if (header[26] == 1) return _restore(plain);
      return utf8.decode(plain);
    } catch (_) {
      throw const SourceException('起点付费正文校验或解密失败，请联网重试');
    }
  }

  static String _restore(Uint8List plain) {
    if (plain.length < 2) throw const FormatException();
    final count = ByteData.sublistView(plain).getUint16(0, Endian.little);
    final end = 2 + count * 3;
    if (end > plain.length) throw const FormatException();
    final originals = utf8.decode(plain.sublist(2, end)).runes.toList();
    if (originals.length != count) throw const FormatException();
    final text = utf8.decode(plain.sublist(end));
    final encountered = <int>{
      for (final rune in text.runes)
        if (rune >= 0x4e00 && rune <= 0x9fa5) rune,
    }.toList();
    if (encountered.length != count) throw const FormatException();
    final replacements = {
      for (var i = 0; i < count; i++) encountered[i]: originals[i],
    };
    return String.fromCharCodes(
      text.runes.map((rune) => replacements[rune] ?? rune),
    );
  }
}
