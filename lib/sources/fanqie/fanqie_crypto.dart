// Protocol port from ch6vip/fqapp (GPL-3.0), credited in README.md.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart'
    show
        AESEngine,
        CBCBlockCipher,
        KeyParameter,
        ParametersWithIV,
        PaddedBlockCipherImpl,
        PaddedBlockCipherParameters,
        PKCS7Padding;
import '../../domain/models.dart';
import 'fanqie_signature.dart';
import '../native_chapter_crypto.dart';

typedef FanqieDecryptedBlob = ({Uint8List? bytes, SourceException? error});

class FanqieCrypto {
  static Uint8List ttEncrypt(List<int> data, {List<int>? random}) {
    final seed = random ?? randomBytes(32);
    final fixed = base64Decode(
      'TdTC5rgxYgkOUrPHpnM7pByyRiuCmrWKGWs521cXdST0m69/COjWjSanLjfBqVovHwWlGJKu8pSXMrYqOKrdWA==',
    );
    final hash = sha512.convert([
      ...sha512.convert(seed).bytes,
      ...fixed,
    ]).bytes;
    return Uint8List.fromList([
      0x74,
      0x63,
      5,
      16,
      0,
      0,
      ...seed,
      ...aes(
        [...sha512.convert(data).bytes, ...data],
        hash.sublist(0, 16),
        hash.sublist(16, 32),
      ),
    ]);
  }

  static final _random = Random.secure();
  static Uint8List randomBytes(int count) =>
      Uint8List.fromList(List.generate(count, (_) => _random.nextInt(256)));
  static Uint8List hex(String value) => Uint8List.fromList([
    for (var i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ]);
  static Uint8List aes(
    List<int> data,
    List<int> key,
    List<int> iv, {
    bool encrypt = true,
  }) {
    if (![16, 24, 32].contains(key.length) ||
        iv.length != 16 ||
        !encrypt && (data.isEmpty || data.length % 16 != 0)) {
      throw const SourceException('番茄加密数据格式无效');
    }
    try {
      if (!encrypt) {
        return NativeChapterCrypto.decrypt(
          ChapterDecryptInput(
            data: Uint8List.fromList(data),
            key: Uint8List.fromList(key),
            iv: Uint8List.fromList(iv),
          ),
        );
      }
      final cipher = PaddedBlockCipherImpl(
        PKCS7Padding(),
        CBCBlockCipher(AESEngine()),
      );
      cipher.init(
        encrypt,
        PaddedBlockCipherParameters(
          ParametersWithIV(
            KeyParameter(Uint8List.fromList(key)),
            Uint8List.fromList(iv),
          ),
          null,
        ),
      );
      return cipher.process(Uint8List.fromList(data));
    } catch (_) {
      throw const SourceException('番茄加密数据校验失败');
    }
  }

  static List<BigInt> simonBlock(
    List<BigInt> block,
    List<BigInt> initialKey, {
    bool decrypt = false,
  }) => FanqieSignature.simonBlock(block, initialKey, decrypt: decrypt);

  static String ladon(int timestamp, int aid, List<int> random) =>
      FanqieSignature.ladon(timestamp, aid, random);

  static String argus(
    String query,
    int timestamp,
    int nonce, {
    List<int>? body,
  }) => FanqieSignature.argus(query, timestamp, nonce, body: body);

  static Map<String, String> sign(
    Uri uri, {
    List<int>? body,
    int? timestamp,
    int? nonce,
    List<int>? random,
  }) {
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final aid = int.tryParse(uri.queryParameters['aid'] ?? '') ?? 1967;
    return {
      'x-ss-req-ticket': '${ts * 1000}',
      'x-khronos': '$ts',
      'x-ladon': ladon(ts, aid, random ?? randomBytes(4)),
      'x-argus': argus(
        uri.query,
        ts,
        nonce ?? _random.nextInt(0x100000000),
        body: body,
      ),
      if (body != null && body.isNotEmpty)
        'x-ss-stub': md5.convert(body).toString(),
    };
  }

  static String registerRequest(
    String deviceId, {
    String userId = '0',
    List<int>? iv,
  }) {
    final n = BigInt.parse(deviceId);
    final uid = BigInt.parse(userId);
    if (n <= BigInt.zero ||
        n.bitLength > 64 ||
        uid < BigInt.zero ||
        uid.bitLength > 64) {
      throw const SourceException('番茄设备标识无效');
    }
    final bytes = [
      for (final word in [n, uid])
        for (var i = 0; i < 8; i++)
          ((word >> (i * 8)) & BigInt.from(255)).toInt(),
    ];
    final vector = iv ?? randomBytes(16);
    return base64Encode([
      ...vector,
      ...aes(bytes, hex('ac25c67ddd8f38c1b37a2348828e222e'), vector),
    ]);
  }

  static Uint8List decryptBlob(String encrypted, List<int> key) {
    try {
      final blob = base64Decode(encrypted);
      if (blob.length < 32) throw const FormatException();
      return aes(blob.sublist(16), key, blob.sublist(0, 16), encrypt: false);
    } on SourceException {
      rethrow;
    } catch (_) {
      throw const SourceException('番茄加密正文格式无效');
    }
  }

  static List<FanqieDecryptedBlob> decryptBlobs(
    List<String> encrypted,
    List<int> key,
  ) {
    final results = List<FanqieDecryptedBlob>.filled(encrypted.length, (
      bytes: null,
      error: null,
    ));
    final jobs = <ChapterDecryptInput>[];
    final indices = <int>[];
    final secret = Uint8List.fromList(key);
    for (var i = 0; i < encrypted.length; i++) {
      try {
        final blob = base64Decode(encrypted[i]);
        if (blob.length < 32) throw const FormatException();
        jobs.add(
          ChapterDecryptInput(
            data: Uint8List.sublistView(blob, 16),
            key: secret,
            iv: Uint8List.sublistView(blob, 0, 16),
          ),
        );
        indices.add(i);
      } catch (_) {
        results[i] = (bytes: null, error: const SourceException('番茄加密正文格式无效'));
      }
    }
    final decoded = NativeChapterCrypto.decryptBatch(jobs);
    for (var i = 0; i < decoded.length; i++) {
      final bytes = decoded[i];
      results[indices[i]] = (
        bytes: bytes,
        error: bytes == null ? const SourceException('番茄加密数据校验失败') : null,
      );
    }
    return results;
  }
}
