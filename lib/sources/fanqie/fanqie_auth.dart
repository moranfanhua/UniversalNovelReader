import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/models.dart';
import '../../data/app_log.dart';
import '../logged_request.dart';
import 'fanqie_app_api.dart';
import 'fanqie_crypto.dart';

class FanqieAuth {
  FanqieAuth(this.client, this.app);
  final http.Client client;
  final FanqieAppApi app;
  final _cookies = <String, String>{};
  bool _closed = false;
  static const _authCookies = {
    'sessionid',
    'sessionid_ss',
    'sid_tt',
    'sid_guard',
    'uid_tt',
    'uid_tt_ss',
    'sid_ucp_v1',
    'ssid_ucp_v1',
    'passport_csrf_token',
    'passport_csrf_token_default',
  };

  static String mobile(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'[ -]'), '');
    final phone = normalized.startsWith('+86')
        ? normalized.substring(3)
        : normalized;
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(phone)) {
      throw const SourceException('请输入有效的中国大陆手机号');
    }
    return '+86$phone';
  }

  static String _mix(String value) => utf8
      .encode(value)
      .map((byte) => (byte ^ 5).toRadixString(16).padLeft(2, '0'))
      .join();

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, String> fields,
  ) async {
    await app.ensureDevice();
    if (_closed) throw const SourceException('已退出番茄登录');
    _cookies.putIfAbsent(
      'passport_csrf_token',
      () => FanqieCrypto.randomBytes(
        16,
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
    );
    final uri = Uri.https('security.snssdk.com', '/passport/mobile/$path/', {
      ...app.loginParameters,
      'passport-sdk-version': '5051452',
    });
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..bodyFields = {'mix_mode': '1', ...fields};
    request.headers.addAll({
      ...FanqieCrypto.sign(uri, body: request.bodyBytes),
      'User-Agent':
          'com.dragon.read/65132 (Linux; U; Android 10; zh_CN; MI 12)',
      'passport-sdk-version': '5051452',
      'sdk-version': '2',
      'x-tt-passport-csrf-token': _cookies['passport_csrf_token']!,
      'Cookie': _cookies.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; '),
    });
    final http.Response response;
    try {
      response = await sendLoggedRequest(
        client,
        request,
        event: 'http.fanqie.auth',
      );
    } on TimeoutException {
      throw const SourceException('认证请求超时，请稍后重试');
    } on http.ClientException {
      throw const SourceException('无法连接番茄认证服务，请检查网络');
    }
    if (response.statusCode != 200) {
      throw SourceException(
        '番茄认证请求失败（HTTP ${response.statusCode}），请稍后重试或导入 App 会话',
      );
    }
    Map<String, dynamic> document;
    if (_closed) throw const SourceException('已退出番茄登录');
    try {
      document =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (error, stack) {
      AppLog.instance.record(
        LogLevel.error,
        'fanqie.auth_response_invalid',
        error: error,
        stackTrace: stack,
      );
      throw const SourceException('番茄认证返回无法识别的数据，请稍后重试或导入 App 会话');
    }
    final data = document['data'] is Map
        ? Map<String, dynamic>.from(document['data'])
        : <String, dynamic>{};
    if (response.headers.containsKey('bdturing-verify') ||
        document['message'] != 'success') {
      final code =
          int.tryParse(
            '${data['error_code'] ?? document['error_code'] ?? -1}',
          ) ??
          -1;
      AppLog.instance.record(
        LogLevel.warning,
        'fanqie.auth_rejected',
        error: SourceException('', code: code),
      );
      if (code == 7) {
        throw const SourceException(
          '番茄认证限制了本次请求（错误码 7：访问太频繁），请稍后重试或导入 App 会话',
          code: 7,
        );
      }
      throw SourceException(
        '番茄认证未通过（错误码 $code），请检查输入；如需安全验证请在官方 App 完成登录后导入 App 会话',
        code: code,
      );
    }
    for (final part in (response.headers['set-cookie'] ?? '').split(
      RegExp(r',\s*(?=[A-Za-z0-9_-]+=)'),
    )) {
      final pair = part.split(';').first;
      final index = pair.indexOf('=');
      if (index < 1) continue;
      final name = pair.substring(0, index).trim(),
          value = pair.substring(index + 1).trim();
      if (_authCookies.contains(name) &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        if (value.isEmpty) {
          _cookies.remove(name);
        } else {
          _cookies[name] = value;
        }
      }
    }
    return data;
  }

  Future<int> sendCode(String phone) async {
    final normalized = mobile(phone);
    final data = await _request('send_code/v1', {
      'mobile': _mix(normalized),
      'type': _mix('24'),
      'unbind_exist': _mix('0'),
      'auto_read': '0',
    });
    return (int.tryParse('${data['retry_time']}') ?? 60).clamp(30, 300);
  }

  Future<String> verifyCode(String phone, String code) async {
    final normalized = mobile(phone);
    if (!RegExp(r'^\d{4,8}$').hasMatch(code.trim())) {
      throw const SourceException('请输入有效的短信验证码');
    }
    _cookies.removeWhere(
      (key, _) =>
          key != 'passport_csrf_token' && key != 'passport_csrf_token_default',
    );
    await _request('sms_login', {
      'mobile': _mix(normalized),
      'code': _mix(code.trim()),
    });
    if (_cookies['sessionid']?.isNotEmpty != true &&
        _cookies['sessionid_ss']?.isNotEmpty != true) {
      throw const SourceException('番茄登录未返回完整会话，请在官方 App 完成登录后导入 App 会话');
    }
    return _cookies.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  void clear() {
    _cookies.clear();
    _closed = true;
  }
}
