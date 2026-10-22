import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../domain/models.dart';
import '../../domain/server_error_message.dart';
import '../../data/app_log.dart';
import '../logged_request.dart';
import '../novel_source.dart';
import '../session_validation.dart';
import 'qidian_cache.dart';
import 'qidian_crypto.dart';
import 'qidian_fock.dart';
import 'qidian_native.dart';

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
  QidianApi({
    http.Client? client,
    String? device,
    DateTime Function()? clock,
    this.security,
  }) : client = client ?? http.Client(),
       device = device ?? '${const Uuid().v4().replaceAll('-', '')}0000',
       clock = clock ?? DateTime.now {
    if (!RegExp(r'^[a-fA-F0-9]{36}$').hasMatch(this.device)) {
      throw const SourceException('起点本机设备标识无效');
    }
  }
  final http.Client client;
  final QidianRequestSecurity? security;
  bool _closed = false;
  int _sessionRevision = 0;
  final String device;
  final DateTime Function() clock;
  QidianCredentials? _credentials;
  QidianCredentials? get credentials => _credentials;
  set credentials(QidianCredentials? value) {
    if (identical(value, _credentials)) return;
    _credentials = value;
    _sessionRevision++;
    _ownedChapters.clear();
    _readingKeys.clear();
  }

  late final _ownedChapters = QidianCache<Set<String>>(
    lifetime: const Duration(minutes: 1),
    clock: clock,
  );
  late final _readingKeys = QidianCache<QidianReadingKey>(
    lifetime: const Duration(minutes: 10),
    clock: clock,
  );
  DateTime? _pausedUntil;
  static const riskPause = Duration(minutes: 10);
  String? sessionNotice;
  Future<void> Function()? onSessionChanged;
  bool get hasSession => credentials != null;

  void checkRequestAllowed() {
    if (_closed) throw const SourceException('起点请求已取消');
    final until = _pausedUntil;
    if (until != null && clock().isBefore(until)) {
      throw const SourceAccessRestrictedException(
        '起点提示当前网络环境风险较高，本机暂停期尚未结束，请稍后手动重试',
        code: -4403,
      );
    }
  }

  SourceAccessRestrictedException _pauseForRisk() {
    // This is a local cooling-off period, not a claim about server recovery.
    // Changing accounts must not reset a network restriction.
    _pausedUntil = clock().add(riskPause);
    final native = security;
    if (native != null) unawaited(native.pause().catchError((Object _) {}));
    return const SourceAccessRestrictedException(
      '起点提示当前网络环境风险较高，已停止后续请求并在本机暂停十分钟',
      code: -4403,
    );
  }

  SourceException rejectResponse(
    http.Response response,
    int? result, {
    String? path,
    ServerErrorMessage? serverMessage,
  }) {
    final code = result != null && result != 0 ? result : response.statusCode;
    final SourceException error;
    if (code == -4403) {
      error = _pauseForRisk();
    } else {
      final message = code == -2 || response.statusCode == 401
          ? '起点会话已失效，请重新登录'
          : '起点请求失败，请稍后重试（$code）';
      error = SourceException(
        serverMessage?.appendTo(message) ?? message,
        code: code,
      );
    }
    final event = switch (path ?? response.request?.url.path) {
      '/argus/newapi/v1/bookcontent/getcontentbatch' => 'qidian.batch_rejected',
      '/argus/api/v4/bookcontent/getkey' => 'qidian.key_rejected',
      '/argus/api/v2/subscription/getboughtchapterlist' =>
        'qidian.ownership_rejected',
      final path when path != null && path.startsWith('/sdk/') =>
        'qidian.auth_rejected',
      _ => 'qidian.request_rejected',
    };
    AppLog.instance.record(
      LogLevel.warning,
      event,
      error: error,
      httpStatus: response.statusCode,
      serverMessage: serverMessage,
    );
    return error;
  }

  SourceException rejectChapter(int code) {
    final error = code == -4403
        ? _pauseForRisk()
        : SourceException('该起点章节暂无阅读权限，请在官方 App 确认可读状态', code: code);
    AppLog.instance.record(
      LogLevel.warning,
      'qidian.chapter_rejected',
      error: error,
    );
    return error;
  }

  Future<Map<String, String>> _secureHeaders(
    Map<String, String> params,
    Map<String, String> session,
  ) async {
    try {
      return await security!.headers(params, device: device, session: session);
    } on SourceAccessRestrictedException catch (error) {
      if (error.code == -4403) throw _pauseForRisk();
      rethrow;
    }
  }

  /// Auth uses the YW SDK's own signature, but shares this installation's gate.
  Future<void> prepareAuthenticationRequest() async {
    checkRequestAllowed();
    final revision = _sessionRevision;
    if (security != null) await _secureHeaders({}, {});
    checkRequestAllowed();
    if (revision != _sessionRevision) {
      throw const SourceException('起点请求已过期，请重试');
    }
  }

  Future<http.Response> send(
    String path,
    Map<String, String> params, {
    bool post = false,
    bool useSession = true,
  }) async {
    checkRequestAllowed();
    final revision = _sessionRevision;
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
    final session = useSession ? credentials : null;
    final native = security;
    if (native != null) {
      request.headers.addAll(
        await _secureHeaders(params, {
          if (session != null) ...session.toJson().cast<String, String>(),
        }),
      );
    } else {
      // Explicit protocol fixture/injected transport; production sessions always
      // install NativeQidianSecurity in QidianSession.open.
      request.headers.addAll(
        QidianCrypto.headers(
          params,
          device: device,
          timestamp: clock().millisecondsSinceEpoch,
          userId: session?.userId ?? '0',
        ),
      );
      if (session != null) {
        request.headers['Cookie'] =
            'cmfuToken=${session.token}; ywguid=${session.ywGuid}; ywkey=${session.ywKey}; appId=12; areaId=30';
      }
    }
    checkRequestAllowed();
    if (_closed || revision != _sessionRevision) {
      throw const SourceException('起点请求已过期，请重试');
    }
    if (post) request.bodyFields = params;
    final response = await sendLoggedRequest(
      client,
      request,
      event: 'http.qidian',
    );
    // Chapter bodies are binary. Observe JSON business rejections before a
    // caller can swallow one or schedule another batch; never log the payload.
    Object? document;
    if (response.bodyBytes.isNotEmpty &&
        response.bodyBytes.firstWhere((byte) => byte > 32, orElse: () => 0) ==
            123) {
      try {
        document = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        // responsePayload reports malformed JSON to callers that expect JSON.
      }
    }
    if (document is Map) {
      final result = int.tryParse('${document['Result']}');
      if (result != null && result != 0) {
        throw rejectResponse(
          response,
          result,
          path: path,
          serverMessage: _serverErrorMessage(response, document),
        );
      }
    }
    return response;
  }

  Object? responsePayload(http.Response response) {
    try {
      final doc = jsonDecode(utf8.decode(response.bodyBytes));
      if (doc is! Map) throw const FormatException();
      final code = int.tryParse('${doc['Result']}');
      if (response.statusCode != 200 || code != 0) {
        throw rejectResponse(
          response,
          code,
          serverMessage: _serverErrorMessage(response, doc),
        );
      }
      return doc['Data'];
    } on SourceException {
      rethrow;
    } catch (_) {
      throw SourceException('起点返回无法识别的数据（HTTP ${response.statusCode}）');
    }
  }

  ServerErrorMessage? _serverErrorMessage(http.Response response, Map doc) {
    final request = response.request;
    return ServerErrorMessage.parse(
      doc['Message'] ?? doc['Msg'],
      responseData: doc,
      secrets: [
        credentials?.toJson(),
        device,
        request?.headers,
        request?.url.queryParameters,
        if (request is http.Request &&
            request.headers['content-type']?.startsWith(
                  'application/x-www-form-urlencoded',
                ) ==
                true)
          request.bodyFields,
      ],
    );
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
    bool useSession = true,
  }) async => responseData(
    await send(path, params, post: post, useSession: useSession),
  );

  Future<Set<String>> ownedChapters(String bid, {bool refresh = false}) {
    final session = credentials;
    return _ownedChapters.get(bid, () async {
      final payload = responsePayload(
        await send('/argus/api/v2/subscription/getboughtchapterlist', {
          'bookId': bid,
        }, post: true),
      );
      if (!identical(session, credentials)) {
        throw const SourceException('起点账号已切换，请重新获取章节权限');
      }
      if (payload is! List ||
          payload.any(
            (value) => !RegExp(r'^[1-9]\d{0,11}$').hasMatch('$value'),
          )) {
        throw const SourceException('起点已购章节列表格式已变化');
      }
      return Set<String>.unmodifiable(payload.map((value) => '$value'));
    }, refresh: refresh);
  }

  void invalidateOwnership(String bid) => _ownedChapters.invalidate(bid);

  Future<QidianReadingKey> readingKey(String bid) {
    final session = credentials;
    return _readingKeys.get(bid, () async {
      final data = await request('/argus/api/v4/bookcontent/getkey', {
        'bookId': bid,
        'ui': '0',
      });
      if (!identical(session, credentials)) {
        throw const SourceException('起点账号已切换，请重新获取阅读密钥');
      }
      return QidianReadingKey.fromJson(data);
    });
  }

  void invalidateReadingKey(String bid) => _readingKeys.invalidate(bid);

  Future<Uint8List> downloadArchive(String address, String digest) =>
      AppLog.instance.capture('qidian.download_failed', () async {
        checkRequestAllowed();
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
    final data = await request(
      '/argus/api/v2/user/login',
      {
        'appId': '12',
        'areaId': '30',
        'ywguid': guid,
        'ywkey': key,
        'loginfrom': '1',
        'fromSource': QidianCrypto.source,
        'isFirstRegister': 'false',
      },
      post: true,
      useSession: false,
    );
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
    await accountPage();
  }

  Future<Map<String, dynamic>> accountPage() async {
    final session = credentials;
    if (session == null) throw const SourceException('请先登录起点读书');
    try {
      // APK kb.m.l0 -> UserAccountItemBean.UserBasicInfo.UserId. Reading the
      // account page checks the current cmfuToken without exchanging a new one.
      final response = await send('/argus/api/v3/user/getaccountpage', {});
      if (response.statusCode == 401) {
        throw const SessionExpiredException('起点会话已失效，请重新登录');
      }
      final data = responseData(response);
      final user = data['UserBasicInfo'];
      if (data.containsKey('UserBasicInfo') && user == null ||
          user is Map && '${user['UserId']}' == '0') {
        throw const SessionExpiredException('起点会话已失效，请重新登录');
      }
      if (user is! Map || '${user['UserId']}' != session.userId) {
        throw const SourceException('起点账号检测返回的数据与当前账号不匹配');
      }
      return data;
    } on SourceException catch (error) {
      if (error.code == -2 || error.code == 401) {
        throw const SessionExpiredException('起点会话已失效，请重新登录');
      }
      rethrow;
    }
  }

  void close() {
    _closed = true;
    security?.close();
    client.close();
  }
}
