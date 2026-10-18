// Signature and session protocol adapted from SFacgExporter, AGPL-3.0.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../domain/models.dart';
import '../../data/app_log.dart';
import '../logged_request.dart';
import '../session_validation.dart';
import 'sfacg_signature.dart';

class SfacgApi {
  // The API checks the App protocol profile on chapter reads. A random UUID
  // paired with the UNR User-Agent can pass /user but is rejected with 507.
  static const compatibilityDevice = '910D166A-736E-3231-8B21-8D12DFD75F16';
  static const protocolProfile = 'android-5.2.16-v1';
  SfacgApi({
    http.Client? client,
    String? device,
    String? nonce,
    this.appUserAgent,
  }) : client = client ?? http.Client(),
       device = device ?? compatibilityDevice,
       nonce = nonce ?? const Uuid().v4().toUpperCase();
  final http.Client client;
  final String device;
  final String? appUserAgent;
  String nonce;
  int clockOffset = 0;
  String? sessionNotice;
  final Map<String, String> cookies = {};
  bool websiteSession = false;
  Future<void> Function()? onSessionChanged;
  bool get hasSession =>
      !websiteSession &&
      cookies['.SFCommunity']?.isNotEmpty == true &&
      cookies['session_APP']?.isNotEmpty == true;

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

  Future<void> importCookie(String value) async {
    final candidate =
        SfacgApi(client: client, device: device, appUserAgent: appUserAgent)
          ..clockOffset = clockOffset
          ..setCookie(value);
    await candidate.validateSession();
    cookies
      ..clear()
      ..addAll(candidate.cookies);
    websiteSession = candidate.websiteSession;
    nonce = candidate.nonce;
    clockOffset = candidate.clockOffset;
    await onSessionChanged?.call();
  }

  Future<void> validateSession() async {
    if (!hasSession) throw const SourceException('请使用账号密码登录或导入完整 App 会话');
    // APK AccountApi.getUserWithFields returns Account.accountId.
    final user = await get('user');
    final id = user is Map ? int.tryParse('${user['accountId']}') : null;
    if (id == 0 || !hasSession) {
      throw const SessionExpiredException('菠萝包会话未登录或已失效，请重新登录');
    }
    if (id == null || id < 0) {
      throw const SourceException('菠萝包账号检测返回的数据格式已变化');
    }
  }

  Future<void> checkSession() async {
    if (!hasSession) throw const SourceException('请先登录菠萝包');
    // Isolate response Cookies: a probe must never overwrite a newer login or
    // remove saved credentials when the server expires its session Cookies.
    final probe =
        SfacgApi(client: client, device: device, appUserAgent: appUserAgent)
          ..clockOffset = clockOffset
          ..cookies.addAll(cookies);
    try {
      await probe.validateSession();
    } on SourceException catch (error) {
      if (error.code == 401 && error.errorCode != 507) {
        throw const SessionExpiredException('菠萝包会话已失效，请重新登录');
      }
      rethrow;
    }
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
            appUserAgent ??
            'boluobao/5.2.16(android;35)/OPPO/${device.toLowerCase()}/OPPO',
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
      final response = await sendLoggedRequest(
        client,
        req,
        event: 'http.sfacg',
      );
      Map<String, dynamic> doc;
      try {
        doc = head || response.statusCode == 204 && response.bodyBytes.isEmpty
            ? {}
            : jsonDecode(utf8.decode(response.bodyBytes))
                  as Map<String, dynamic>;
      } catch (error, stack) {
        AppLog.instance.record(
          LogLevel.error,
          'sfacg.response_invalid',
          error: error,
          stackTrace: stack,
        );
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
      AppLog.instance.record(
        LogLevel.warning,
        'sfacg.request_rejected',
        error: SourceException(
          '',
          code: code,
          errorCode: int.tryParse('${status['errorCode']}'),
        ),
        httpStatus: response.statusCode,
      );
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
      final errorCode = int.tryParse('${status['errorCode']}');
      if (uri.path.startsWith('/Chaps/') && code == 401 && errorCode == 507) {
        throw const SourceException(
          '菠萝包正文接口拒绝当前 App 请求配置（错误码 507），请检查 App 版本和设备标识；登录成功不代表正文接口可用',
          code: 401,
          errorCode: 507,
        );
      }
      throw SourceException(
        '$endpoint失败（HTTP ${response.statusCode}，状态 $code，错误码 ${status['errorCode'] ?? 0}）${message.isEmpty ? '' : '：$message'}',
        code: code,
        errorCode: errorCode,
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
    final candidate = SfacgApi(
      client: client,
      device: device,
      appUserAgent: appUserAgent,
    )..clockOffset = clockOffset;
    await candidate.request(
      'sessions',
      body: {'username': account.trim(), 'password': password, 'shuMeiId': ''},
      retry: false,
    );
    if (!candidate.hasSession) {
      throw const SourceException('登录接口没有返回完整 App 会话，可能需要完成平台验证');
    }
    await candidate.validateSession();
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
