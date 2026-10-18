import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../domain/models.dart';
import '../../data/app_log.dart';
import '../logged_request.dart';
import '../session_validation.dart';
import 'qidian_crypto.dart';

class QidianCredentials {
  QidianCredentials({
    required this.userId,
    required this.ywGuid,
    required this.ywKey,
    required this.token,
  }) {
    if (![userId, ywGuid].every((s) => RegExp(r'^[1-9]\d*$').hasMatch(s)) ||
        [
          ywKey,
          token,
        ].any((s) => s.isEmpty || RegExp(r'[\s;,\x00-\x1f\x7f]').hasMatch(s))) {
      throw const SourceException('起点 App 会话数据无效');
    }
  }
  final String userId, ywGuid, ywKey, token;
  Map<String, dynamic> toJson() => {
    'userId': userId,
    'ywGuid': ywGuid,
    'ywKey': ywKey,
    'token': token,
  };
  factory QidianCredentials.fromJson(Map<String, dynamic> data) =>
      QidianCredentials(
        userId: '${data['userId'] ?? ''}',
        ywGuid: '${data['ywGuid'] ?? ''}',
        ywKey: '${data['ywKey'] ?? ''}',
        token: '${data['token'] ?? ''}',
      );
}

class QidianApi {
  QidianApi({http.Client? client, String? device, DateTime Function()? clock})
    : client = client ?? http.Client(),
      device = device ?? '${const Uuid().v4().replaceAll('-', '')}0000',
      clock = clock ?? DateTime.now {
    if (!RegExp(r'^[a-fA-F0-9]{36}$').hasMatch(this.device)) {
      throw const SourceException('起点本机设备标识无效');
    }
  }
  final http.Client client;
  final String device;
  final DateTime Function() clock;
  QidianCredentials? credentials;
  String? sessionNotice;
  Future<void> Function()? onSessionChanged;
  bool get hasSession => credentials != null;

  Future<http.Response> send(
    String path,
    Map<String, String> params, {
    bool post = false,
  }) async {
    // Callers use only fixed paths from the official App, never arbitrary URLs.
    final uri = Uri.https('druidv6.if.qidian.com', path).replace(
      // Empty catalog values must retain '=' to match the official App.
      query: post
          ? null
          : params.entries
                .map(
                  (e) =>
                      '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
                )
                .join('&'),
    );
    final request = http.Request(post ? 'POST' : 'GET', uri)
      ..followRedirects = false;
    request.headers.addAll(
      QidianCrypto.headers(
        params,
        device: device,
        timestamp: clock().millisecondsSinceEpoch,
        userId: credentials?.userId ?? '0',
      ),
    );
    final session = credentials;
    if (session != null) {
      request.headers['Cookie'] =
          'cmfuToken=${session.token}; ywguid=${session.ywGuid}; ywkey=${session.ywKey}; appId=12; areaId=30';
    }
    if (post) request.bodyFields = params;
    return sendLoggedRequest(client, request, event: 'http.qidian');
  }

  Object? responsePayload(http.Response response) {
    try {
      final doc = jsonDecode(utf8.decode(response.bodyBytes));
      if (doc is! Map) throw const FormatException();
      final code = int.tryParse('${doc['Result']}');
      if (response.statusCode != 200 || code != 0) {
        throw SourceException(
          code == -2 || response.statusCode == 401
              ? '起点会话已失效，请重新登录'
              : '起点请求失败，请稍后重试（${code ?? response.statusCode}）',
          code: code ?? response.statusCode,
        );
      }
      return doc['Data'];
    } on SourceException {
      rethrow;
    } catch (_) {
      throw SourceException('起点返回无法识别的数据（HTTP ${response.statusCode}）');
    }
  }

  Map<String, dynamic> responseData(http.Response response) {
    final payload = responsePayload(response);
    if (payload is! Map) throw const SourceException('起点返回的数据格式已变化');
    return Map<String, dynamic>.from(payload);
  }

  Future<Map<String, dynamic>> request(
    String path,
    Map<String, String> params, {
    bool post = false,
  }) async => responseData(await send(path, params, post: post));

  Future<Uint8List> downloadArchive(String address, String digest) =>
      AppLog.instance.capture('qidian.download_failed', () async {
        final uri = Uri.tryParse(address);
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment ||
            uri.hasPort && uri.port != 443 ||
            ![
              '.myqcloud.com',
              '.qidian.com',
              '.yuewen.com',
            ].any(uri.host.endsWith) ||
            !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(digest)) {
          throw const SourceException('起点批量下载地址或校验信息无效');
        }
        // COS is a separate origin: never forward account cookies or QDSign.
        final request = http.Request('GET', uri)..followRedirects = false;
        try {
          final response = await client
              .send(request)
              .timeout(const Duration(seconds: 25));
          const maxBytes = 32 * 1024 * 1024;
          if (response.statusCode != 200 ||
              (response.contentLength ?? 0) > maxBytes) {
            unawaited(response.stream.listen(null).cancel());
            throw SourceException('起点批量正文下载失败（HTTP ${response.statusCode}）');
          }
          final buffer = BytesBuilder(copy: false);
          await for (final chunk in response.stream.timeout(
            const Duration(seconds: 25),
          )) {
            buffer.add(chunk);
            if (buffer.length > maxBytes) {
              throw const SourceException('起点批量正文超过大小限制');
            }
          }
          final bytes = buffer.takeBytes();
          if (md5.convert(bytes).toString() != digest.toLowerCase()) {
            throw const SourceException('起点批量正文校验失败，请重试');
          }
          return bytes;
        } on TimeoutException {
          throw const SourceException('起点批量正文下载超时，请重试');
        } on http.ClientException {
          throw const SourceException('起点批量正文网络连接失败，请重试');
        }
      });

  /// The App exchanges YW SDK credentials for a reader account and cmfuToken.
  Future<QidianCredentials> validateLogin(String guid, String key) async {
    final data = await request('/argus/api/v2/user/login', {
      'appId': '12',
      'areaId': '30',
      'ywguid': guid,
      'ywkey': key,
      'loginfrom': '1',
      'fromSource': QidianCrypto.source,
      'isFirstRegister': 'false',
    }, post: true);
    final ticket = data['LoginResult'];
    if (ticket is! Map) throw const SourceException('起点未返回完整登录信息');
    return QidianCredentials(
      userId: '${data['UserId']}',
      ywGuid: guid,
      ywKey: key,
      token: '${ticket['CmfuToken'] ?? ''}',
    );
  }

  Future<void> saveSession(QidianCredentials session) async {
    credentials = session;
    await onSessionChanged?.call();
  }

  Future<void> checkSession() async {
    final session = credentials;
    if (session == null) throw const SourceException('请先登录起点读书');
    final probe = QidianApi(client: client, device: device, clock: clock)
      ..credentials = session;
    try {
      // APK kb.m.l0 -> UserAccountItemBean.UserBasicInfo.UserId. Reading the
      // account page checks the current cmfuToken without exchanging a new one.
      final response = await probe.send(
        '/argus/api/v3/user/getaccountpage',
        {},
      );
      if (response.statusCode == 401) {
        throw const SessionExpiredException('起点会话已失效，请重新登录');
      }
      final data = probe.responseData(response);
      final user = data['UserBasicInfo'];
      if (data.containsKey('UserBasicInfo') && user == null ||
          user is Map && '${user['UserId']}' == '0') {
        throw const SessionExpiredException('起点会话已失效，请重新登录');
      }
      if (user is! Map || '${user['UserId']}' != session.userId) {
        throw const SourceException('起点账号检测返回的数据与当前账号不匹配');
      }
    } on SourceException catch (error) {
      if (error.code == -2 || error.code == 401) {
        throw const SessionExpiredException('起点会话已失效，请重新登录');
      }
      rethrow;
    }
  }

  void close() => client.close();
}
