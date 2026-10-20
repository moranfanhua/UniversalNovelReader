import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/fanqie/fanqie_crypto.dart';

void main() {
  final fixture =
      jsonDecode(
            File('test/fixtures/fanqie_signatures.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final vectors = fixture['vectors'] as List;
  for (var i = 0; i < vectors.length; i++) {
    test('C++ 请求签名逐字节兼容旧实现：向量 $i', () {
      final vector = vectors[i] as Map<String, dynamic>;
      final size = vector['bodyLength'] as int;
      final seed = vector['bodySeed'] as int;
      final body = size < 0
          ? null
          : List<int>.generate(size, (j) => (j * 37 + seed) & 255);
      final actual = FanqieCrypto.sign(
        Uri.parse('https://reading.snssdk.com/synthetic?${vector['query']}'),
        body: body,
        timestamp: vector['timestamp'] as int,
        nonce: vector['nonce'] as int,
        random: (vector['random'] as List).cast<int>(),
      );
      expect(actual, vector['headers']);
    });
  }

  test('后台 isolate 并发调用原生签名，不共享可变计算状态', () async {
    final results = await Future.wait(
      List.generate(
        8,
        (_) => Isolate.run(() {
          return FanqieCrypto.sign(
            Uri.parse('https://reading.snssdk.com/synthetic'),
            timestamp: 0,
            nonce: 0,
            random: [0, 255, 0, 0],
          );
        }),
      ),
    );
    for (final result in results) {
      expect(result, (vectors.first as Map)['headers']);
    }
  });

  test('C++ Simon 支持完整无符号 64 位分组及逆运算', () {
    final random = Random(1967);
    BigInt word() =>
        (BigInt.from(random.nextInt(0x100000000)) << 32) |
        BigInt.from(random.nextInt(0x100000000));
    final maximum = (BigInt.one << 64) - BigInt.one;
    for (var i = 0; i < 100; i++) {
      final key = [word(), word(), word(), word()];
      final block = i == 0 ? [BigInt.zero, maximum] : [word(), word()];
      final encrypted = FanqieCrypto.simonBlock(block, key);
      expect(FanqieCrypto.simonBlock(encrypted, key, decrypt: true), block);
    }
  });

  test('拒绝不完整随机数与越界分组，随后仍可正常签名', () {
    for (final random in [
      <int>[],
      [1, 2, 3],
      [1, 2, 3, 4, 5],
      [0, 0, 0, 256],
      [-1, 0, 0, 0],
    ]) {
      expect(
        () => FanqieCrypto.ladon(1700000000, 1967, random),
        throwsA(isA<SourceException>()),
      );
    }
    expect(
      () => FanqieCrypto.simonBlock([BigInt.zero], List.filled(4, BigInt.zero)),
      throwsA(isA<SourceException>()),
    );
    expect(
      () => FanqieCrypto.simonBlock([
        BigInt.one << 64,
        BigInt.zero,
      ], List.filled(4, BigInt.zero)),
      throwsA(isA<SourceException>()),
    );
    expect(
      FanqieCrypto.ladon(1700000000, 1967, [1, 2, 3, 4]),
      'AQIDBKM7Y7bWnOIUXmTybD6/MpGbuge4sBwUJsyHVivhtMsH',
    );
  });
}
