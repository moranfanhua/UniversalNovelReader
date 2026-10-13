import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/models.dart';

class FanqieApi {
  FanqieApi({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  String _cookie = '';
  String get cookie => _cookie;
  bool get hasSession => _cookie.isNotEmpty;
  String? sessionNotice;
  Future<void> Function()? onSessionChanged;

  void setCookie(String value) {
    final parts = value.trim().split(';');
    final cookies = <String, String>{};
    for (final part in parts) {
      final pair = part.trim();
      if (pair.isEmpty) continue;
      final index = pair.indexOf('=');
      if (index < 1 || RegExp(r'[\r\n\x00-\x1f]').hasMatch(pair)) {
        throw const SourceException('番茄会话格式无效');
      }
      final name = pair.substring(0, index);
      if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name)) {
        throw const SourceException('番茄会话格式无效');
      }
      cookies[name] = pair.substring(index + 1).trim();
    }
    if (cookies['sessionid']?.isNotEmpty != true &&
        cookies['sessionid_ss']?.isNotEmpty != true) {
      throw const SourceException('需要包含 sessionid 或 sessionid_ss 的番茄官网会话');
    }
    _cookie = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void clearSession() => _cookie = '';

  Future<http.Response> fetch(Uri uri, {bool redirect = true}) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          !{
            'fanqienovel.com',
            'www.fanqienovel.com',
            'reading.snssdk.com',
          }.contains(uri.host) ||
          uri.hasPort && uri.port != 443) {
        throw const SourceException('番茄请求地址无效');
      }
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers.addAll({
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://fanqienovel.com/',
        if (hasSession &&
            uri.scheme == 'https' &&
            uri.host == 'fanqienovel.com')
          'Cookie': _cookie,
      });
      final response = await (() async => http.Response.fromStream(
        await client.send(request),
      ))().timeout(const Duration(seconds: 25));
      if (response.headers.containsKey('bdturing-verify')) {
        throw const SourceException('番茄需要安全验证，请在官网完成验证后重新导入官网会话', code: 403);
      }
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw SourceException(
          '番茄请求失败（HTTP ${response.statusCode}）',
          code: response.statusCode,
        );
      }
      if (response.statusCode >= 300) {
        if (!redirect) return response;
        final location = response.headers['location'];
        if (location == null) throw const SourceException('番茄跳转地址缺失');
        uri = uri.resolve(location);
        continue;
      }
      if (response.bodyBytes.isEmpty) {
        throw const SourceException('番茄返回空响应，请完成官网验证后重试');
      }
      return response;
    }
    throw const SourceException('番茄跳转次数过多');
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await fetch(Uri.https('fanqienovel.com', path, query));
    Map<String, dynamic> doc;
    try {
      doc = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const SourceException('番茄返回无法识别的数据，请稍后重试');
    }
    if (doc['code'] != 0) {
      final code = int.tryParse('${doc['code']}') ?? -1;
      throw SourceException('番茄接口请求失败（状态 $code），请检查登录或官网验证', code: code);
    }
    if (doc['data'] is! Map) throw const SourceException('番茄未返回有效数据');
    return Map<String, dynamic>.from(doc['data']);
  }

  Future<void> validateSession() async {
    if (!hasSession) throw const SourceException('请先导入番茄官网会话');
    final data = await get('/api/reader/user/info');
    final id = '${data['user_id'] ?? data['userId'] ?? data['id'] ?? ''}';
    if (!RegExp(r'^[1-9]\d*$').hasMatch(id)) {
      throw const SourceException('番茄会话未登录或已失效');
    }
  }

  void close() => client.close();
}
