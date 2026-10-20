@DefaultAsset('package:unr/sources/fanqie/fanqie_signature.dart')
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../domain/models.dart';

final class _Bytes extends Struct {
  external Pointer<Uint8> data;
  @Size()
  external int length;
}

final class _ArgusInput extends Struct {
  external _Bytes query;
  external _Bytes body;
  external _Bytes aid;
  external _Bytes device;
  external _Bytes version;
  @Int64()
  external int timestamp;
  @Uint32()
  external int nonce;
}

@Native<Pointer<Utf8> Function(Int64, Int64, Pointer<Uint8>)>(
  symbol: 'unr_fanqie_ladon',
)
external Pointer<Utf8> _ladon(int timestamp, int aid, Pointer<Uint8> random);

@Native<Pointer<Utf8> Function(Pointer<_ArgusInput>)>(
  symbol: 'unr_fanqie_argus',
)
external Pointer<Utf8> _argus(Pointer<_ArgusInput> input);

@Native<Void Function(Pointer<Void>)>(symbol: 'unr_fanqie_signature_free')
external void _free(Pointer<Void> result);

@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Int32, Pointer<Uint8>)>(
  symbol: 'unr_fanqie_simon',
)
external int _simon(
  Pointer<Uint8> block,
  Pointer<Uint8> key,
  int decrypt,
  Pointer<Uint8> output,
);

/// The App's signature algorithms run in the bundled C++ code asset.
/// URI parsing and secure randomness stay in Dart; no session state is native.
class FanqieSignature {
  static Pointer<Uint8> _copy(Arena arena, List<int> bytes) {
    if (bytes.isEmpty) return nullptr;
    final pointer = arena<Uint8>(bytes.length);
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    return pointer;
  }

  static void _set(Arena arena, _Bytes target, List<int> bytes) {
    target
      ..data = _copy(arena, bytes)
      ..length = bytes.length;
  }

  static String _result(Pointer<Utf8> pointer) {
    if (pointer == nullptr) {
      throw const SourceException('番茄请求签名生成失败，请重试');
    }
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer.cast());
    }
  }

  static String ladon(int timestamp, int aid, List<int> random) {
    if (random.length != 4 || random.any((byte) => byte < 0 || byte > 255)) {
      throw const SourceException('番茄签名随机数格式无效');
    }
    return using(
      (arena) => _result(_ladon(timestamp, aid, _copy(arena, random))),
    );
  }

  static String argus(
    String query,
    int timestamp,
    int nonce, {
    List<int>? body,
  }) {
    final params = Uri.splitQueryString(query);
    return using((arena) {
      final input = arena<_ArgusInput>();
      _set(arena, input.ref.query, utf8.encode(query));
      _set(arena, input.ref.body, body ?? const []);
      _set(arena, input.ref.aid, utf8.encode(params['aid'] ?? '1967'));
      _set(arena, input.ref.device, utf8.encode(params['device_id'] ?? ''));
      _set(arena, input.ref.version, utf8.encode(params['version_name'] ?? ''));
      input.ref
        ..timestamp = timestamp
        ..nonce = nonce.toUnsigned(32);
      return _result(_argus(input));
    });
  }

  // Retain the block API for protocol vector and inverse-operation checks.
  static List<BigInt> simonBlock(
    List<BigInt> block,
    List<BigInt> initialKey, {
    bool decrypt = false,
  }) {
    if (block.length != 2 ||
        initialKey.length != 4 ||
        [
          ...block,
          ...initialKey,
        ].any((word) => word.isNegative || word.bitLength > 64)) {
      throw const SourceException('番茄签名分组格式无效');
    }
    List<int> bytes(List<BigInt> words) => [
      for (final word in words)
        for (var i = 0; i < 8; i++)
          ((word >> (i * 8)) & BigInt.from(255)).toInt(),
    ];
    return using((arena) {
      final output = arena<Uint8>(16);
      final status = _simon(
        _copy(arena, bytes(block)),
        _copy(arena, bytes(initialKey)),
        decrypt ? 1 : 0,
        output,
      );
      if (status != 0) {
        throw const SourceException('番茄签名分组运算失败');
      }
      final result = output.asTypedList(16);
      BigInt word(int offset) {
        var value = BigInt.zero;
        for (var i = 7; i >= 0; i--) {
          value = (value << 8) | BigInt.from(result[offset + i]);
        }
        return value;
      }

      return [word(0), word(8)];
    });
  }
}
