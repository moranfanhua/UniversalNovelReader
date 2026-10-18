import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../../domain/models.dart';

/// Protocol verified against the official Android App 2.9.367.
class CiweimaoCrypto {
  static const version = '2.9.367';
  // Md5Encode hashes the certificate's hexadecimal string without its first
  // and last characters. This is a public App fingerprint, not an account key.
  static const fingerprint = 'a90f3731745f1c30ee77cb13fc00005a';
  static const responseSeed = 'sD6doAOcW7hm7iaeK6UlcdtAIWlZGlBr';
  static const _salt = 'CkMxWNB666d65e99d6231bc9a104dd44b3ed3607a0';

  static String nonce(DateTime now, {Random? random}) {
    final rng = random ?? Random.secure();
    final entropy = List.generate(16, (_) => rng.nextInt(256));
    // The App prefixes a truncated MD5 with the current minute and second.
    final digest = md5.convert(entropy.sublist(1, 15)).toString();
    return '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}${digest.substring(0, 12)}';
  }

  static String form(Map<String, String> params, {required String nonce}) {
    if (!RegExp(r'^\d{4}[a-f0-9]{12}$').hasMatch(nonce)) {
      throw const SourceException('刺猬猫请求标识无效');
    }
    final values = params.map(
      (k, v) => MapEntry(k, Uri.encodeQueryComponent(v)),
    );
    final account = values['account'] ?? 'cwm666';
    final message =
        'account=$account&app_version=$version&rand_str=$nonce'
        '&signatures=$fingerprint$_salt';
    final signature = base64Encode(
      Hmac(
        sha256,
        utf8.encode(fingerprint),
      ).convert(utf8.encode(message)).bytes,
    );
    final keys = values.keys.toList()..sort();
    return 'p=${Uri.encodeQueryComponent(signature)}&'
        '${keys.map((k) => '$k=${values[k]}&').join()}rand_str=$nonce&';
  }

  static String decrypt(String encoded, {String seed = responseSeed}) {
    try {
      final bytes = base64Decode(encoded.replaceAll(RegExp(r'\s'), ''));
      if (bytes.isEmpty || bytes.length % 16 != 0) {
        throw const FormatException();
      }
      final cipher =
          PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
            ..init(
              false,
              PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
                ParametersWithIV(
                  KeyParameter(
                    Uint8List.fromList(sha256.convert(utf8.encode(seed)).bytes),
                  ),
                  Uint8List(16),
                ),
                null,
              ),
            );
      return utf8.decode(cipher.process(bytes));
    } catch (_) {
      throw const SourceException('刺猬猫返回无法识别的数据，请重试');
    }
  }

  static String encrypt(String text, {String seed = responseSeed}) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
          ..init(
            true,
            PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
              ParametersWithIV(
                KeyParameter(
                  Uint8List.fromList(sha256.convert(utf8.encode(seed)).bytes),
                ),
                Uint8List(16),
              ),
              null,
            ),
          );
    return base64Encode(cipher.process(Uint8List.fromList(utf8.encode(text))));
  }

  static String encryptPassword(String text) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > 245) throw const SourceException('刺猬猫账号或密码过长');
    final key = RSAPublicKey(
      BigInt.parse(
        'c57e403001920e14f1b0811a842e6d271ca9cbcab23e28ce4f6aec321b940ef1'
        '0db56a65e1ac6c7cb4690f5025821cc14a93608b589dc99fceb4916f66c8e3f9'
        'dadd10eeeb0b3c4c04e959770efd1b0a34e901520fc24bf17e1fe3d61c1a5dbe'
        '2c8e5dd0a058db05dd87bbab107402c4b2bf2f1bbd7bd0031d7cd8dbab69089c'
        'af1792c84ca64f9f36231ade1f842121ba83e879594975100c9867a845943f0de'
        '453480435892dc7a9a95361170ce002222ee9a2be4defa73f1116c4d3d1208a5'
        'f4ce0151c31902f29c9af7f2ecee300bb61d74ad425369cedfbfff34d4333ac9b'
        '016dc8a8b805154b9c3b0c94176a29441e401dda1469ae61e076fabf0465b5',
        radix: 16,
      ),
      BigInt.from(65537),
    );
    final rng = Random.secure();
    final random = FortunaRandom()
      ..seed(
        KeyParameter(
          Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256))),
        ),
      );
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(
        true,
        ParametersWithRandom(PublicKeyParameter<RSAPublicKey>(key), random),
      );
    return base64Encode(cipher.process(bytes));
  }
}
