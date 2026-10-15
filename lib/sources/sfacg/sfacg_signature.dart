// Protocol ported from moranfanhua/SFacgExporter (AGPL-3.0).
import 'dart:convert';
import 'package:crypto/crypto.dart';

String sfacgSign(String nonce, int timestamp, String device) {
  if (nonce.length != 36 || device.length != 36) {
    throw ArgumentError('请求标识必须为 UUID');
  }
  final repeated = nonce * 4;
  const sizes = [13, 16, 36, 36];
  final reordered = List.generate(4, (i) {
    final start = repeated.codeUnitAt(i + 1) % 36;
    return repeated.substring(start, start + sizes[i]);
  }).join();
  final source =
      '$timestamp'
      r'lPQDb9AKO7$LjkPG'
      '$device$nonce';
  if (source.length != 101) throw ArgumentError('请求时间戳无效');
  final averaged = String.fromCharCodes(
    List.generate(
      101,
      (i) => (source.codeUnitAt(i) + reordered.codeUnitAt(i)) >> 1,
    ),
  );
  final shuffled =
      averaged.substring(65) +
      averaged.substring(0, 13) +
      averaged.substring(29, 65) +
      averaged.substring(13, 29);
  final bytes = shuffled.codeUnits.map((n) {
    if (n < 48) return n + 19 > 57 && n + 19 < 65 ? 57 : n + 19;
    if ((n > 57 && n < 65) || (n > 90 && n < 97)) return n + 19;
    return n;
  }).toList();
  return md5
      .convert(utf8.encode(String.fromCharCodes(bytes)))
      .toString()
      .toUpperCase();
}
