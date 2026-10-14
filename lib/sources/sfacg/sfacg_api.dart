// Signature and session protocol adapted from SFacgExporter, AGPL-3.0.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../../domain/models.dart';
import 'sfacg_signature.dart';
import 'sfacg_website.dart';

class SfacgApi {
  SfacgApi({http.Client? client, String? device, String? nonce})
    : client = client ?? http.Client(),
      device = device ?? const Uuid().v4().toUpperCase(),
      nonce = nonce ?? const Uuid().v4().toUpperCase();
  final http.Client client;
  final String device;
  String nonce;
  int clockOffset = 0;
  String? sessionNotice;
  final Map<String, String> cookies = {};
  bool websiteSession = false;
  Future<void> Function()? onSessionChanged;
  bool get hasSession =>
      cookies['.SFCommunity']?.isNotEmpty == true &&
      (websiteSession || cookies['session_APP']?.isNotEmpty == true);
  SfacgWebsite get website => SfacgWebsite(
    client,
    cookies.entries.map((entry) => '${entry.key}=${entry.value}').join('; '),
  );

  void setCookie(String value, {bool website = false}) {
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const SourceException('会话包含无效字符');
    }
    final parsed = <String, String>{};
    for (final part in value.split(';')) {
      final i = part.indexOf('=');
      if (i < 0) continue;
      final key = part.substring(0, i).trim();
      if (key == '.SFCommunity' || key == 'session_APP') {
        parsed[key] = part.substring(i + 1).trim();
      }
    }
    if ((!website && parsed.length != 2) ||
        parsed['.SFCommunity']?.isNotEmpty != true ||
        parsed.values.any(
          (v) => v.isEmpty || v.contains('\n') || v.contains('\r'),
        )) {
      throw SourceException(
        website ? '尚未取得菠萝包官网登录会话' : '需要完整的 .SFCommunity 和 session_APP 会话',
      );
    }
    cookies
      ..clear()
      ..addAll(parsed);
    websiteSession = website;
  }

  Future<void> importCookie(String value, {bool website = false}) async {
    final candidate = SfacgApi(client: client, device: device)
      ..clockOffset = clockOffset
      ..setCookie(value, website: website);
    if (website) {
      await candidate.website.validateSession();
    } else {
      final user = await candidate.get('user');
      final userId = user is Map
          ? int.tryParse(
              '${user['accountId'] ?? user['userId'] ?? user['id'] ?? ''}',
            )
          : null;
      if (userId == null || userId <= 0) {
        throw const SourceException('菠萝包会话未登录或已失效，请重新登录');
      }
    }
    cookies
      ..clear()
      ..addAll(candidate.cookies);
    websiteSession = candidate.websiteSession;
    nonce = candidate.nonce;
    clockOffset = candidate.clockOffset;
    await onSessionChanged?.call();
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) =>
      request(path, query: query);

  Future<dynamic> request(
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    bool head = false,
    bool retry = true,
    String? method,
  }) async {
    if (websiteSession &&
        (body != null ||
            method != null && method != 'GET' && method != 'HEAD')) {
      throw const SourceException('段评发送、回复和点赞需要 App 会话，请使用账号密码登录或导入 App 会话');
    }
    final uri = Uri.https(
      'api.sfacg.com',
      path.startsWith('/') ? path : '/$path',
      query,
    );
    for (var attempt = 0; attempt < 4; attempt++) {
      final timestamp = DateTime.now().millisecondsSinceEpoch + clockOffset;
      final req = http.Request(
        method ??
            (head
                ? 'HEAD'
                : body == null
                ? 'GET'
                : 'POST'),
        uri,
      )..followRedirects = false;
      req.headers.addAll({
        'Authorization': 'Basic YW5kcm9pZHVzZXI6MWEjJDUxLXl0Njk7KkFjdkBxeHE=',
        'Accept': 'application/vnd.sfacg.api+json;version=1',
        'Accept-Charset': 'UTF-8',
        'User-Agent':
            'boluobao/5.2.44(android;35)/UNR/${device.toLowerCase()}/UNR',
        'sfsecurity':
            'nonce=$nonce&timestamp=$timestamp&devicetoken=$device&sign=${sfacgSign(nonce, timestamp, device)}',
        if (hasSession && !websiteSession)
          'Cookie': cookies.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; '),
      });
      if (body != null) {
        req.headers['Content-Type'] = 'application/json; charset=utf-8';
        req.body = jsonEncode(body);
      }
      final response = await (() async => http.Response.fromStream(
        await client.send(req),
      ))().timeout(const Duration(seconds: 25));
      Map<String, dynamic> doc;
      try {
        doc = head || response.statusCode == 204 && response.bodyBytes.isEmpty
            ? {}
            : jsonDecode(utf8.decode(response.bodyBytes))
                  as Map<String, dynamic>;
      } catch (_) {
        throw SourceException('菠萝包返回无法识别的数据（HTTP ${response.statusCode}）');
      }
      final status = (doc['status'] as Map?) ?? {};
      final code = status['httpCode'] as int? ?? response.statusCode;
      if (code >= 200 &&
          code < 300 &&
          response.statusCode >= 200 &&
          response.statusCode < 300) {
        final setCookie = response.headers['set-cookie'];
        if (setCookie != null && !websiteSession) {
          for (final m in RegExp(
            r'(?:^|,\s*)(\.SFCommunity|session_APP)=([^;,]*)',
          ).allMatches(setCookie)) {
            if (m[2]!.isEmpty) {
              cookies.remove(m[1]);
            } else {
              cookies[m[1]!] = m[2]!;
            }
          }
          await onSessionChanged?.call();
        }
        return head ? response.headers : doc['data'];
      }
      if (retry && attempt < 3 && (code == 417 || code == 429 || code >= 500)) {
        nonce = const Uuid().v4().toUpperCase();
        if (code == 417 && response.headers['date'] != null) {
          try {
            clockOffset =
                HttpDate.parse(
                  response.headers['date']!,
                ).millisecondsSinceEpoch -
                DateTime.now().millisecondsSinceEpoch;
          } catch (_) {
            /* Keep the current clock for invalid server dates. */
          }
        }
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
        continue;
      }
      final endpoint = uri.path == '/sessions'
          ? '账号登录'
          : uri.path == '/user'
          ? '登录会话校验'
          : uri.path.startsWith('/Chaps/')
          ? '章节读取'
          : body != null && uri.path.endsWith('/tsukkomis')
          ? '段评发送'
          : req.method == 'POST' && uri.path.endsWith('/favs')
          ? '段评点赞'
          : req.method == 'POST' && uri.path.endsWith('/replys')
          ? '段评回复'
          : '菠萝包请求';
      var message = '${status['msg'] ?? ''}'.trim();
      for (final secret in [
        ...cookies.values,
        if (body != null) ...body.values.whereType<String>(),
      ]) {
        if (secret.isNotEmpty) message = message.replaceAll(secret, '[已隐藏]');
      }
      message = message
          .replaceAll(RegExp(r'1[3-9]\d{9}'), '[手机号已隐藏]')
          .replaceAll(RegExp(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}'), '[邮箱已隐藏]');
      throw SourceException(
        '$endpoint失败（HTTP ${response.statusCode}，状态 $code，错误码 ${status['errorCode'] ?? 0}）${message.isEmpty ? '' : '：$message'}',
        code: code,
      );
    }
    throw const SourceException('菠萝包暂时无法访问');
  }

  Future<void> login(String account, String password) async {
    if (account.trim().isEmpty || password.isEmpty) {
      throw const SourceException('请填写账号和密码');
    }
    // Authenticate independently: an expired Cookie must not be sent to the
    // login endpoint, and failed credentials must not replace a valid session.
    final candidate = SfacgApi(client: client, device: device)
      ..clockOffset = clockOffset;
    await candidate.request(
      'sessions',
      body: {'username': account.trim(), 'password': password, 'shuMeiId': ''},
    );
    if (!candidate.hasSession) {
      throw const SourceException('登录接口没有返回完整 App 会话，可能需要完成平台验证');
    }
    await candidate.get('user');
    cookies
      ..clear()
      ..addAll(candidate.cookies);
    websiteSession = false;
    nonce = candidate.nonce;
    clockOffset = candidate.clockOffset;
    await onSessionChanged?.call();
  }

  void close() => client.close();
}
