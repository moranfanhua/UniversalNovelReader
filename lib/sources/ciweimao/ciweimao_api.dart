import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../data/app_log.dart';
import '../../domain/models.dart';
import '../../domain/server_error_message.dart';
import '../logged_request.dart';
import 'ciweimao_crypto.dart';

class CiweimaoCredentials {
  CiweimaoCredentials({
    required this.account,
    required this.token,
    required this.readerId,
    this.name = '',
    this.guest = false,
  }) {
    if (account.trim().isEmpty ||
        account.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(account) ||
        !RegExp(r'^[A-Za-z0-9_-]{16,256}$').hasMatch(token) ||
        !RegExp(r'^[1-9]\d{0,15}$').hasMatch(readerId)) {
      throw const SourceException('刺猬猫 App 会话数据无效');
    }
  }
  final String account, token, readerId, name;
  final bool guest;
  String get host => '12345'.contains(readerId[readerId.length - 1])
      ? 'app1.happybooker.cn'
      : 'app1.hbooker.com';

  Map<String, dynamic> toJson() => {
    'account': account,
    'login_token': token,
    'reader_id': readerId,
    'name': name,
    'guest': guest,
  };
  factory CiweimaoCredentials.fromJson(Map<String, dynamic> data) =>
      CiweimaoCredentials(
        account: '${data['account'] ?? ''}',
        token: '${data['login_token'] ?? ''}',
        readerId: '${data['reader_id'] ?? ''}',
        name: '${data['name'] ?? ''}',
        guest: data['guest'] == true,
      );
  factory CiweimaoCredentials.fromApp(
    Map<String, dynamic> data, {
    bool guest = false,
  }) {
    final reader = data['reader_info'];
    if (reader is! Map) throw const SourceException('刺猬猫未返回完整账号信息');
    return CiweimaoCredentials(
      account: '${reader['account'] ?? ''}',
      token: '${data['login_token'] ?? ''}',
      readerId: '${reader['reader_id'] ?? ''}',
      name: '${reader['reader_name'] ?? ''}',
      guest: guest,
    );
  }
}

class CiweimaoApi {
  CiweimaoApi({
    http.Client? client,
    String? installation,
    DateTime Function()? clock,
  }) : client = client ?? http.Client(),
       installation = installation ?? const Uuid().v4(),
       clock = clock ?? DateTime.now {
    if (!RegExp(r'^[a-fA-F0-9-]{32,36}$').hasMatch(this.installation)) {
      throw const SourceException('刺猬猫本机设备标识无效');
    }
  }
  final http.Client client;
  final String installation;
  final DateTime Function() clock;
  CiweimaoCredentials? _credentials;
  CiweimaoCredentials? get credentials => _credentials;
  bool get hasSession => _credentials != null && !_credentials!.guest;
  int _generation = 0;
  int get sessionGeneration => _generation;
  Future<CiweimaoCredentials>? _opening;
  CiweimaoApi? _publicApi;
  String? sessionNotice;
  Future<void> Function()? onSessionChanged;

  void restoreSession(CiweimaoCredentials? value) {
    _generation++;
    _credentials = value;
  }

  Future<void> saveSession(CiweimaoCredentials? value) async {
    restoreSession(value);
    await onSessionChanged?.call();
  }

  void checkSession(int generation) {
    if (generation != _generation) {
      throw const SourceException('刺猬猫账号已切换，请重试');
    }
  }

  Future<CiweimaoCredentials> ensureSession() {
    if (_credentials != null) return Future.value(_credentials);
    return _opening ??= _openGuest().whenComplete(() => _opening = null);
  }

  /// Catalog reads use an isolated guest context. Never replace or persist over
  /// the reader's login, even when guest registration or renewal fails.
  Future<Map<String, dynamic>> requestPublic(
    String path,
    Map<String, String> params,
  ) {
    if (!{
      'book/get_info_by_id',
      'chapter/get_updated_chapter_by_division_new',
    }.contains(path)) {
      throw const SourceException('此接口不能使用公开目录请求');
    }
    final public = _publicApi ??= CiweimaoApi(
      client: client,
      installation: installation,
      clock: clock,
    );
    if (public._credentials == null &&
        public._generation == 0 &&
        _credentials?.guest == true) {
      public.restoreSession(_credentials);
    }
    return public.request(path, params);
  }

  Future<CiweimaoCredentials> _openGuest() async {
    final generation = _generation;
    final data = await _send('signup/auto_reg_v2', {
      'uuid': installation,
      'gender': '1',
      'channel': 'Common_default',
      'oauth_type': '',
      'oauth_open_id': '',
      'oauth_union_id': '',
    });
    checkSession(generation);
    final session = CiweimaoCredentials.fromApp(data, guest: true);
    await saveSession(session);
    return session;
  }

  Future<Map<String, dynamic>> request(
    String path,
    Map<String, String> params, {
    CiweimaoCredentials? session,
    bool write = false,
    Iterable<String> secrets = const [],
  }) async {
    final current = session ?? await ensureSession();
    if (session == null && !identical(current, _credentials)) {
      throw const SourceException('刺猬猫账号已切换，请重试');
    }
    final generation = _generation;
    try {
      final result = await _send(
        path,
        params,
        session: current,
        write: write,
        secrets: secrets,
      );
      checkSession(generation);
      return result;
    } on SourceException catch (error) {
      if (error.code == 200100 &&
          current.guest &&
          identical(current, _credentials)) {
        // Keep the saved data until a new guest session succeeds. Do not retry
        // this operation; the next explicit retry can renew the same device.
        _credentials = null;
        throw const SourceException('刺猬猫游客会话已过期，请重试以重新连接', code: 200100);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _send(
    String path,
    Map<String, String> params, {
    CiweimaoCredentials? session,
    bool write = false,
    Iterable<String> secrets = const [],
  }) async {
    if (!RegExp(r'^[a-z][a-z0-9_]*/[a-z][a-z0-9_]*$').hasMatch(path) ||
        params.keys.any((key) => !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(key)) ||
        params.keys.any(
          {
            'account',
            'login_token',
            'app_version',
            'device_token',
            'rand_str',
            'p',
          }.contains,
        )) {
      throw const SourceException('刺猬猫请求参数无效');
    }
    final request =
        http.Request(
            'POST',
            Uri.https(session?.host ?? 'app1.hbooker.com', '/$path'),
          )
          ..followRedirects = false
          ..headers.addAll({
            'User-Agent':
                'Android  com.kuangxiangciweimao.novel.c  ${CiweimaoCrypto.version}, Android, UNR, 33, 13',
            'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
            'charsets': 'utf-8',
          })
          ..body = CiweimaoCrypto.form({
            ...params,
            'app_version': CiweimaoCrypto.version,
            'device_token': 'ciweimao_',
            if (session != null) 'account': session.account,
            if (session != null) 'login_token': session.token,
          }, nonce: CiweimaoCrypto.nonce(clock()));
    try {
      final response = await sendLoggedRequest(
        client,
        request,
        event: 'http.ciweimao',
      );
      if (response.statusCode != 200) {
        throw SourceException(
          '刺猬猫请求失败（HTTP ${response.statusCode}）',
          code: response.statusCode,
        );
      }
      final Map<String, dynamic> doc;
      try {
        final decoded = jsonDecode(
          CiweimaoCrypto.decrypt(utf8.decode(response.bodyBytes)),
        );
        if (decoded is! Map<String, dynamic>) throw const FormatException();
        doc = decoded;
      } catch (error, stack) {
        AppLog.instance.record(
          LogLevel.error,
          path.startsWith('signup/')
              ? 'ciweimao.auth_response_invalid'
              : 'ciweimao.response_invalid',
          error: error,
          stackTrace: stack,
          httpStatus: response.statusCode,
        );
        throw const SourceException('刺猬猫返回无法识别的数据，请重试');
      }
      final code = int.tryParse('${doc['code']}');
      if (code != 100000) {
        final serverMessage = ServerErrorMessage.parse(
          doc['tip'] ?? doc['message'] ?? doc['msg'],
          responseData: doc,
          secrets: [
            secrets,
            params,
            session?.toJson(),
            credentials?.toJson(),
            installation,
          ],
        );
        AppLog.instance.record(
          LogLevel.warning,
          path.startsWith('signup/')
              ? 'ciweimao.auth_rejected'
              : 'ciweimao.request_rejected',
          error: SourceException('', code: code ?? -1),
          httpStatus: response.statusCode,
          serverMessage: serverMessage,
        );
        final message = switch (code) {
          200100 || 200001 => '刺猬猫会话已失效，请重新登录',
          210000 => '请输入登录验证码；账号密码登录请先获取验证码后重试',
          310002 => '需要安全验证，请在刺猬猫官方 App 完成后重新登录或导入 App 会话',
          320002 => '刺猬猫请求校验失败，请重试或重新登录',
          _ => '刺猬猫请求失败（${code ?? -1}），请检查账号或稍后重试',
        };
        throw SourceException(
          serverMessage?.appendTo(message) ?? message,
          code: code ?? -1,
        );
      }
      final data = doc['data'];
      if (write && (data == null || data is List && data.isEmpty)) return {};
      if (data is! Map) throw const SourceException('刺猬猫返回的数据格式已变化');
      return Map<String, dynamic>.from(data);
    } on TimeoutException {
      throw SourceException(write ? '操作结果未确认，请先刷新检查，再决定是否重试' : '刺猬猫请求超时，请重试');
    } on http.ClientException {
      throw SourceException(write ? '操作结果未确认，请先刷新检查，再决定是否重试' : '刺猬猫网络连接失败，请重试');
    } on SourceException catch (e) {
      if (write &&
          (e.code >= 500 && e.code < 600 || e.message.contains('无法识别'))) {
        throw const SourceException('操作结果未确认，请先刷新检查，再决定是否重试');
      }
      rethrow;
    }
  }

  void close() => client.close();
}
