import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../data/app_log.dart';
import '../../domain/models.dart';
import 'ciweimao_api.dart';

class CiweimaoContent {
  static bool validCdnHost(String host) =>
      RegExp(r'^[a-z0-9-]+\.kuangxiangit\.com$').hasMatch(host);

  static Future<String> fetch(CiweimaoApi api, String address) async {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        !validCdnHost(uri.host) ||
        uri.hasFragment ||
        uri.hasPort && uri.port != 443 && uri.port != 80) {
      throw const SourceException('刺猬猫正文 CDN 地址无效');
    }
    // The App downloads this resource without account headers. HTTPS is also
    // supported by its CDN, including URLs returned with the old HTTP scheme.
    final request = http.Request(
      'GET',
      uri.replace(scheme: 'https', port: uri.hasPort ? 443 : null),
    )..followRedirects = false;
    try {
      final bytes = await AppLog.instance.capture(
        'ciweimao.cdn_failed',
        () async {
          final response = await api.client
              .send(request)
              .timeout(const Duration(seconds: 25));
          if (response.statusCode != 200 ||
              (response.contentLength ?? 0) > 8 * 1024 * 1024) {
            unawaited(response.stream.listen(null).cancel());
            throw SourceException(
              '刺猬猫正文下载失败（HTTP ${response.statusCode}）',
              code: response.statusCode,
            );
          }
          final buffer = BytesBuilder(copy: false);
          await for (final chunk in response.stream.timeout(
            const Duration(seconds: 25),
          )) {
            buffer.add(chunk);
            if (buffer.length > 8 * 1024 * 1024) {
              throw const SourceException('刺猬猫正文超过大小限制');
            }
          }
          return buffer.takeBytes();
        },
      );
      if (bytes.length < 2 ||
          !(bytes[0] == 0x78 || bytes[0] == 0x1f && bytes[1] == 0x8b)) {
        throw const SourceException('刺猬猫正文压缩格式已变化');
      }
      final decoder = ZLibDecoder(gzip: bytes[0] == 0x1f);
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in decoder.bind(Stream.value(bytes))) {
        buffer.add(chunk);
        if (buffer.length > 16 * 1024 * 1024) {
          throw const SourceException('刺猬猫正文超过大小限制');
        }
      }
      return utf8.decode(buffer.takeBytes());
    } on SourceException {
      rethrow;
    } on TimeoutException {
      throw const SourceException('刺猬猫正文下载超时，请重试');
    } on http.ClientException {
      throw const SourceException('刺猬猫正文下载失败，请重试');
    } catch (_) {
      throw const SourceException('刺猬猫正文解压失败，请重试');
    }
  }
}
