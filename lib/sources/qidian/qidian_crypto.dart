import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../../domain/models.dart';

/// Interoperability profile verified against the official Android 7.9.480 APK
/// (1996): a.c.sign, a.d.c, ye.cihai and libload-jni. No APK code is bundled.
class QidianCrypto {
  static const version = '7.9.480';
  static const versionCode = '1996';
  static const deviceModel = '2211133C';
  static const source = '10000431';
  static const _signKey = '{1dYgqE)h9,R)hKqEcv4]k[h';
  static const _deviceKey = '0821CAAD409B8402';
  static const _sdkKey = 'sewxf03hhz3ew9qcCXMHiDMk';
  // MD5 of the official package signing certificate's DER hex representation.
  static const _packageSignature = 'f189adc92b816b3e9da29ea304d4a7e4';

  static Uint8List des(
    List<int> input,
    String key, {
    bool decrypt = false,
    String? iv,
  }) {
    final bytes = utf8.encode(key);
    final expanded = bytes.length == 16 ? [...bytes, ...bytes.take(8)] : bytes;
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(DESedeEngine()),
    );
    cipher.init(
      !decrypt,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
        ParametersWithIV(
          KeyParameter(Uint8List.fromList(expanded)),
          iv == null ? Uint8List(8) : Uint8List.fromList(utf8.encode(iv)),
        ),
        null,
      ),
    );
    return cipher.process(Uint8List.fromList(input));
  }

  static String appBase64(List<int> bytes) {
    final value = base64Encode(bytes);
    return [
      for (var i = 0; i < value.length; i += 60)
        value.substring(i, (i + 60).clamp(0, value.length)),
    ].join(' ');
  }

  static Map<String, String> headers(
    Map<String, String> parameters, {
    required String device,
    required int timestamp,
    String userId = '0',
  }) {
    final sorted = <String, String>{
      for (final entry in parameters.entries)
        entry.key.toLowerCase(): entry.value,
    };
    final names = sorted.keys.toList()..sort();
    final canonical = names.map((k) => '$k=${sorted[k]}').join('&');
    final signature = [
      'Rv1rPTnczce',
      timestamp,
      userId,
      device,
      '1',
      version,
      '0',
      md5.convert(utf8.encode(canonical)),
      _packageSignature,
    ].join('|');
    final info = [
      device,
      version,
      '1080',
      '1920',
      source,
      '15',
      '1',
      deviceModel,
      versionCode,
      source,
      '4',
      userId,
      timestamp,
      '0',
      device,
      '',
      '',
      '',
      device,
      '0',
    ].join('|');
    return {
      'User-Agent':
          'QDReader/$version/$versionCode/$source/Xiaomi/$deviceModel/15',
      'QDSign': appBase64(
        des(utf8.encode(signature), _signKey, iv: '01234567'),
      ),
      'QDInfo': base64Encode(des(utf8.encode(info), _deviceKey)),
      'tstamp': '$timestamp',
    };
  }

  static String sdkSignature(String device, int timestamp) => appBase64(
    des(
      utf8.encode('$device|$device|${timestamp ~/ 1000}|$device'),
      _sdkKey,
      iv: 'sh331nt1',
    ),
  );

  static Map<String, dynamic> decodeChapter(
    Uint8List bytes, {
    required String chapterId,
    required String device,
    required String userId,
  }) {
    try {
      final blocks = <Uint8List>[];
      var offset = 0;
      for (var i = 0; i < 5; i++) {
        if (offset + 4 > bytes.length) throw const FormatException();
        final length = ByteData.sublistView(
          bytes,
        ).getUint32(offset, Endian.little);
        offset += 4;
        if (length > bytes.length - offset) throw const FormatException();
        blocks.add(Uint8List.sublistView(bytes, offset, offset + length));
        offset += length;
      }
      if (offset != bytes.length || blocks[1].isEmpty) {
        throw const FormatException();
      }
      if (blocks[0].isNotEmpty) {
        final expires = int.tryParse(
          utf8.decode(des(blocks[0], _deviceKey, decrypt: true)),
        );
        if (expires == null ||
            expires > 0 && expires < DateTime.now().millisecondsSinceEpoch) {
          throw const SourceException('起点章节阅读权限已过期，请联网重新获取');
        }
      }
      final first = base64Encode(
        Hmac(sha1, utf8.encode(device))
            .convert(
              utf8.encode(
                '$userId$device${chapterId}2EEE1433A152E84B3756301D8FA3E69A',
              ),
            )
            .bytes,
      ).substring(0, 24);
      final second = base64Encode(
        Hmac(
          md5,
          utf8.encode(userId),
        ).convert(utf8.encode('$first$device')).bytes,
      );
      final content = des(
        des(blocks[1], second, decrypt: true),
        first,
        decrypt: true,
      );
      return jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
    } on SourceException {
      rethrow;
    } catch (_) {
      throw const SourceException('起点章节数据不完整或无法解密，请重试');
    }
  }
}
