import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:unr/sources/fanqie/fanqie_crypto.dart';
import 'package:unr/sources/native_chapter_crypto.dart';

Uint8List hex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

Uint8List encrypt(
  Uint8List plain,
  Uint8List key,
  Uint8List iv, {
  ChapterCipher cipher = ChapterCipher.aesCbc,
  bool padding = true,
}) {
  final parameters = ParametersWithIV(KeyParameter(key), iv);
  if (cipher == ChapterCipher.aesCtr) {
    return (SICStreamCipher(
      AESEngine(),
    )..init(true, parameters)).process(plain);
  }
  final cbc = CBCBlockCipher(
    cipher == ChapterCipher.des3Cbc ? DESedeEngine() : AESEngine(),
  );
  if (padding) {
    final count = cbc.blockSize - plain.length % cbc.blockSize;
    return encrypt(
      Uint8List.fromList([...plain, ...List.filled(count, count)]),
      key,
      iv,
      cipher: cipher,
      padding: false,
    );
  }
  cbc.init(true, parameters);
  final output = Uint8List(plain.length);
  for (var i = 0; i < plain.length; i += cbc.blockSize) {
    cbc.processBlock(plain, i, output, i);
  }
  return output;
}

void main() {
  test('AES-CBC 与 CTR 匹配 NIST SP 800-38A 独立固定向量', () {
    final key = hex('2b7e151628aed2a6abf7158809cf4f3c');
    final plain = hex('6bc1bee22e409f96e93d7e117393172a');
    expect(
      NativeChapterCrypto.decrypt(
        ChapterDecryptInput(
          data: hex('7649abac8119b246cee98e9b12e9197d'),
          key: key,
          iv: hex('000102030405060708090a0b0c0d0e0f'),
          padding: false,
        ),
      ),
      plain,
    );
    expect(
      NativeChapterCrypto.decrypt(
        ChapterDecryptInput(
          data: hex('874d6191b620e3261bef6864990db6ce'),
          key: key,
          iv: hex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'),
          cipher: ChapterCipher.aesCtr,
          padding: false,
        ),
      ),
      plain,
    );
  });

  for (final cipher in ChapterCipher.values) {
    for (final keySize
        in cipher == ChapterCipher.des3Cbc ? [16, 24] : [16, 24, 32]) {
      test('原生 $cipher / $keySize 字节密钥兼容旧密码实现与分组边界', () {
        final random = Random(keySize);
        final key = Uint8List.fromList(
          List.generate(keySize, (_) => random.nextInt(256)),
        );
        final block = cipher == ChapterCipher.des3Cbc ? 8 : 16;
        final iv = Uint8List.fromList(
          List.generate(block, (_) => random.nextInt(256)),
        );
        final jobs = <ChapterDecryptInput>[];
        final expected = <Uint8List>[];
        for (final size in [
          0,
          1,
          7,
          8,
          15,
          16,
          17,
          31,
          32,
          33,
          255,
          256,
          4096,
          65537,
        ]) {
          final plain = Uint8List.fromList(
            List.generate(size, (i) => (i * 37) & 255),
          );
          jobs.add(
            ChapterDecryptInput(
              data: encrypt(plain, key, iv, cipher: cipher),
              key: key,
              iv: iv,
              cipher: cipher,
              padding: cipher != ChapterCipher.aesCtr,
            ),
          );
          expected.add(plain);
        }
        final beforeKey = key.toList(), beforeIv = iv.toList();
        expect(NativeChapterCrypto.decryptBatch(jobs), expected);
        expect(key, beforeKey);
        expect(iv, beforeIv);
        if (cipher != ChapterCipher.aesCtr) {
          final plain = Uint8List.fromList(List.generate(block * 10, (i) => i));
          expect(
            NativeChapterCrypto.decrypt(
              ChapterDecryptInput(
                data: encrypt(plain, key, iv, cipher: cipher, padding: false),
                key: key,
                iv: iv,
                cipher: cipher,
                padding: false,
              ),
            ),
            plain,
          );
        }
      });
    }
  }

  test('CTR 完整 128 位计数器进位兼容原实现', () {
    final key = Uint8List(32), iv = Uint8List.fromList(List.filled(16, 255));
    final plain = Uint8List.fromList(List.generate(127, (i) => i));
    expect(
      NativeChapterCrypto.decrypt(
        ChapterDecryptInput(
          data: encrypt(plain, key, iv, cipher: ChapterCipher.aesCtr),
          key: key,
          iv: iv,
          cipher: ChapterCipher.aesCtr,
          padding: false,
        ),
      ),
      plain,
    );
  });

  test('同批中的无效参数、截断与损坏填充逐项失败，其他章节保留', () {
    final key = Uint8List(16), iv = Uint8List(16);
    final plain = Uint8List(31);
    final good = encrypt(plain, key, iv);
    final badPadding = Uint8List.fromList(good)..[15] ^= 1;
    final partialPadding = encrypt(Uint8List(30), key, iv)..[14] ^= 1;
    ChapterDecryptInput job(
      Uint8List data, {
      Uint8List? secret,
      Uint8List? vector,
    }) => ChapterDecryptInput(data: data, key: secret ?? key, iv: vector ?? iv);
    final results = NativeChapterCrypto.decryptBatch([
      job(good),
      job(badPadding),
      job(partialPadding),
      job(Uint8List(0)),
      job(Uint8List(15)),
      job(good, secret: Uint8List(15)),
      job(good, vector: Uint8List(8)),
      job(good),
    ]);
    expect(results.first, plain);
    expect(results.sublist(1, 7), everyElement(isNull));
    expect(results.last, plain);
    expect(
      () => NativeChapterCrypto.decrypt(job(badPadding)),
      throwsFormatException,
    );
    expect(NativeChapterCrypto.decryptBatch([]), isEmpty);
  });

  test('后台 isolate 并发批量解密可重复调用且不共享密钥状态', () async {
    final key = Uint8List.fromList(List.filled(32, 17)), iv = Uint8List(16);
    final plain = Uint8List.fromList(utf8.encode('合成正文😀\n' * 100));
    final job = ChapterDecryptInput(
      data: encrypt(plain, key, iv),
      key: key,
      iv: iv,
    );
    final results = await Future.wait(
      List.generate(
        8,
        (_) => Isolate.run(() {
          return NativeChapterCrypto.decryptBatch(List.filled(30, job));
        }),
      ),
    );
    for (final batch in results) {
      expect(batch, everyElement(plain));
    }
  });

  test('番茄批量解密保持输入顺序和独立错误，不污染原阅读密钥', () {
    final key = Uint8List.fromList(List.filled(16, 9)), iv = Uint8List(16);
    final plain = Uint8List.fromList(utf8.encode('合成批量章节'));
    final encrypted = encrypt(plain, key, iv);
    final good = base64Encode([...iv, ...encrypted]);
    final bad = Uint8List.fromList(encrypt(Uint8List(31), key, iv))..[15] ^= 1;
    final results = FanqieCrypto.decryptBlobs([
      good,
      'bad-base64',
      base64Encode([...iv, ...bad]),
      good,
    ], key);
    expect(results.map((r) => r.bytes), [plain, null, null, plain]);
    expect(results[1].error, isNotNull);
    expect(results[2].error, isNotNull);
    expect(key, List.filled(16, 9));
  });

  test('Mbed TLS 精简源码与已核实版本的文件摘要一致', () {
    final manifest = File('third_party/mbedtls/UPSTREAM').readAsStringSync();
    for (final match in RegExp(
      r'^([a-f0-9]{64})  (.+)$',
      multiLine: true,
    ).allMatches(manifest)) {
      final text = File(
        'third_party/mbedtls/${match[2]}',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        sha256.convert(utf8.encode(text)).toString(),
        match[1],
        reason: match[2],
      );
    }
  });
}
