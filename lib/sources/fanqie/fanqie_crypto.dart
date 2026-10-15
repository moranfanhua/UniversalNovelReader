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
        PKCS7Padding,
        SM3Digest;
import '../../domain/models.dart';

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
  static final _mask = (BigInt.one << 64) - BigInt.one;
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

  static BigInt _read(List<int> data, int offset) {
    var result = BigInt.zero;
    for (var i = 7; i >= 0; i--) {
      result = (result << 8) | BigInt.from(data[offset + i]);
    }
    return result;
  }

  static List<int> _write(BigInt word) => [
    for (var i = 0; i < 8; i++) ((word >> (i * 8)) & BigInt.from(255)).toInt(),
  ];
  static BigInt _rol(BigInt word, int n) =>
      ((word << n) | (word >> (64 - n))) & _mask;
  static BigInt _ror(BigInt word, int n) =>
      ((word >> n) | (word << (64 - n))) & _mask;
  static List<BigInt> simonBlock(
    List<BigInt> block,
    List<BigInt> initialKey, {
    bool decrypt = false,
  }) {
    final keys = initialKey.toList();
    final z = BigInt.parse('3dc94c3a046d678b', radix: 16);
    for (var i = 4; i < 72; i++) {
      var t = _ror(keys[i - 1], 3) ^ keys[i - 3];
      t ^= _ror(t, 1);
      keys.add(
        ((keys[i - 4] ^ _mask) ^
                t ^
                ((z >> ((i - 4) % 62)) & BigInt.one) ^
                BigInt.from(3)) &
            _mask,
      );
    }
    var a = block[0], b = block[1];
    for (var i = 0; i < 72; i++) {
      if (decrypt) {
        final previous = a;
        a = (b ^ (_rol(a, 1) & _rol(a, 8)) ^ _rol(a, 2) ^ keys[71 - i]) & _mask;
        b = previous;
      } else {
        final previous = b;
        b = (a ^ (_rol(b, 1) & _rol(b, 8)) ^ _rol(b, 2) ^ keys[i]) & _mask;
        a = previous;
      }
    }
    return [a, b];
  }

  static String ladon(int timestamp, int aid, List<int> random) {
    final seed = utf8.encode(
      md5.convert([...random, ...utf8.encode('$aid')]).toString(),
    );
    final table = [for (var i = 0; i < 4; i++) _read(seed, i * 8)];
    var a = table[0], b = table[1];
    final queue = table.sublist(2);
    for (var i = 0; i < 34; i++) {
      final next = ((_ror(b, 8) + a) & _mask) ^ BigInt.from(i);
      queue.add(next);
      a = (next ^ _rol(a, 3)) & _mask;
      table.add(a);
      b = queue.removeAt(0);
    }
    // Expansion writes over words 1..34, retaining only seed word 0.
    final rounds = [table[0], ...table.sublist(4)];
    final raw = utf8.encode('$timestamp-1611921764-$aid');
    final padding = 16 - raw.length % 16;
    final input = [...raw, ...List.filled(padding, padding)];
    final out = <int>[...random];
    for (var offset = 0; offset < input.length; offset += 16) {
      var x = _read(input, offset), y = _read(input, offset + 8);
      for (var i = 0; i < 34; i++) {
        y = rounds[i] ^ ((x + _ror(y, 8)) & _mask);
        x = (y ^ _rol(x, 3)) & _mask;
      }
      out.addAll([..._write(x), ..._write(y)]);
    }
    return base64Encode(out);
  }

  static List<int> _sm3(List<int> value) =>
      SM3Digest().process(Uint8List.fromList(value)).sublist(0, 6);
  static String argus(
    String query,
    int timestamp,
    int nonce, {
    List<int>? body,
  }) {
    final params = Uri.splitQueryString(query);
    final aid = params['aid'] ?? '1967';
    final bean = _Proto()
      ..number(1, 1077940818)
      ..number(2, 2)
      ..number(3, nonce)
      ..string(4, aid)
      ..string(5, params['device_id'] ?? '')
      ..string(6, '1611921764')
      ..string(7, params['version_name'] ?? '')
      ..string(8, 'v04.04.05-ov-android')
      ..number(9, 134744640)
      ..bytes(10, List.filled(8, 0))
      ..number(11, 0)
      ..number(12, timestamp << 1)
      ..bytes(
        13,
        _sm3(
          body == null || body.isEmpty
              ? List.filled(16, 0)
              : md5.convert(body).bytes,
        ),
      )
      ..bytes(14, _sm3(query.isEmpty ? List.filled(16, 0) : utf8.encode(query)))
      ..bytes(
        15,
        (_Proto()
              ..number(1, 1)
              ..number(2, 1)
              ..number(3, 1)
              ..number(7, 0xc792eccc))
            .data,
      )
      ..string(16, '')
      ..string(20, 'none')
      ..number(21, 738)
      ..bytes(
        23,
        (_Proto()
              ..string(1, 'NX551J')
              ..number(2, 8196)
              ..number(4, 0x80e0d800))
            .data,
      )
      ..number(25, 2);
    final padding = 16 - bean.data.length % 16;
    final input = [...bean.data, ...List.filled(padding, padding)];
    final key = hex(
      'fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304',
    );
    final words = [for (var i = 0; i < 4; i++) _read(key, i * 8)];
    final encrypted = <int>[];
    for (var i = 0; i < input.length; i += 16) {
      final out = simonBlock([_read(input, i), _read(input, i + 8)], words);
      encrypted.addAll([..._write(out[0]), ..._write(out[1])]);
    }
    const magic = [0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff];
    final frame = [
      ...magic,
      ...encrypted,
      0xea,
      0xfb,
      0x2c,
      0xfe,
      0x85,
      0x68,
      0x51,
      0x91,
      0x54,
    ];
    for (var i = 8; i < frame.length; i++) {
      frame[i] ^= magic[i % 8];
    }
    final payload = [...frame.reversed, 97, 111];
    return base64Encode([
      0xf2,
      0x81,
      ...aes(
        payload,
        hex('d31e3718288a1027baab59f146a09a9c'),
        hex('ea180a0336ed352fcd24e4d50018ae54'),
      ),
    ]);
  }

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
}

class _Proto {
  final data = <int>[];
  void _varint(int value) {
    var word = value & 0xffffffff;
    while (word >= 128) {
      data.add((word & 127) | 128);
      word >>= 7;
    }
    data.add(word & 127);
  }

  void number(int field, int value) {
    _varint(field << 3);
    _varint(value);
  }

  void bytes(int field, List<int> value) {
    _varint((field << 3) | 2);
    _varint(value.length);
    data.addAll(value);
  }

  void string(int field, String value) => bytes(field, utf8.encode(value));
}
