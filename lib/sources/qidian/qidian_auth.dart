import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models.dart';
import '../logged_request.dart';
import 'qidian_api.dart';
import 'qidian_captcha.dart';
import 'qidian_crypto.dart';

/// Official YWLogin SDK PhoneCodeActivity: sendphonecode → phonecodelogin.
class QidianAuth {
  QidianAuth(this.api, {this.solveCaptcha});
  final QidianApi api;
  final QidianCaptchaSolver? solveCaptcha;
  String? _phone, _phoneKey;
  DateTime? _expires, _resendAt;
  bool _busy = false;
  int _generation = 0;

  static String mobile(String input) {
    final phone = input.trim().replaceFirst(RegExp(r'^\+86'), '');
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(phone)) {
      throw const SourceException('请输入有效的中国大陆手机号');
    }
    return phone;
  }

  int get resendSeconds {
    final remaining = _resendAt?.difference(api.clock()).inMilliseconds ?? 0;
    return remaining <= 0 ? 0 : (remaining / 1000).ceil();
  }

  Map<String, String> _common() => {
    'appid': '12',
    'areaid': '30',
    'source': QidianCrypto.source,
    'ticket': '0',
    'auto': '1',
    'autotime': '30',
    'version': QidianCrypto.versionCode,
    'sdkversion': '401',
    'devicetype': 'Xiaomi_${QidianCrypto.deviceModel}',
    'osversion':
        'Android15_${QidianCrypto.version}_${QidianCrypto.versionCode}',
    'signature': QidianCrypto.sdkSignature(
      api.device,
      api.clock().millisecondsSinceEpoch,
    ),
    'returnurl': 'http://www.qidian.com',
    'format': 'json',
    'referer': 'http://android.qidian.com',
    'devicename': QidianCrypto.deviceModel,
  };

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, String> fields,
  ) async {
    final request =
        http.Request('POST', Uri.https('ptlogin.yuewen.com', '/sdk/$path'))
          ..followRedirects = false
          ..headers['Referer'] = 'http://android.qidian.com'
          ..bodyFields = {..._common(), ...fields};
    final response = await sendLoggedRequest(
      api.client,
      request,
      event: 'http.qidian.auth',
    );
    Map<String, dynamic> doc;
    try {
      doc = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const SourceException('起点登录服务返回无法识别的数据');
    }
    final code = int.tryParse('${doc['code']}');
    if (response.statusCode != 200 || code != 0) {
      throw SourceException(
        '起点登录请求失败，请检查登录信息或稍后重试（${code ?? response.statusCode}）',
        code: code ?? response.statusCode,
      );
    }
    final data = doc['data'];
    if (data is! Map) throw const SourceException('起点登录服务未返回完整数据');
    return Map<String, dynamic>.from(data);
  }

  int _nextAction(Map<String, dynamic> data) {
    final action = int.tryParse('${data['nextAction'] ?? 0}');
    if (action == null) throw const SourceException('起点返回无法识别的验证步骤');
    return action;
  }

  void _requireComplete(Map<String, dynamic> data) {
    final action = _nextAction(data);
    if (action != 0) {
      throw SourceException('起点要求的安全验证暂不支持（验证步骤 $action）');
    }
  }

  void _checkActive(int generation) {
    if (_generation != generation) {
      throw const SourceException('已取消本次起点登录');
    }
  }

  String _sessionKey(Map<String, dynamic> data) {
    final key = data['sessionKey'];
    if (key is! String ||
        key.isEmpty ||
        key.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const SourceException('起点未返回验证码会话，请稍后重试');
    }
    return key;
  }

  Future<void> sendCode(String input) async {
    final phone = mobile(input);
    if (_busy || resendSeconds > 0) throw const SourceException('请稍后再获取验证码');
    _busy = true;
    final generation = ++_generation;
    _phone = null;
    _phoneKey = null;
    _expires = null;
    // A timeout may still have sent the SMS. Do not automatically resend it.
    _resendAt = api.clock().add(const Duration(seconds: 60));
    try {
      final fields = {'phone': phone, 'type': '1', 'needRegister': '1'};
      var data = await _request('sendphonecode', fields);
      _checkActive(generation);
      if (_nextAction(data) == 11) {
        final sessionKey = _sessionKey(data);
        final solver = solveCaptcha;
        if (solver == null) {
          throw const SourceException('起点要求安全验证，请在登录页完成验证后获取短信');
        }
        final deadline = api.clock().add(const Duration(minutes: 5));
        final result = await solver(
          QidianCaptchaChallenge(expiresAt: deadline),
        );
        _checkActive(generation);
        if (result == null) {
          _resendAt = null;
          throw const SourceException('已取消安全验证，尚未发送短信');
        }
        if (!deadline.isAfter(api.clock())) {
          _resendAt = null;
          throw const SourceException('起点安全验证已过期，请重新获取验证码');
        }
        // Continue the explicitly rejected request once, as YWLogin does.
        // A repeated challenge or uncertain send result is never auto-retried.
        _resendAt = api.clock().add(const Duration(seconds: 60));
        data = await _request('sendphonecode', {
          ...fields,
          'sessionKey': sessionKey,
          'sig': result.ticket,
          'code': result.randstr,
        });
        _checkActive(generation);
        if (_nextAction(data) == 11) {
          throw const SourceException('起点仍要求安全验证，尚未确认短信发送，请稍后重新获取');
        }
      }
      _requireComplete(data);
      final key = _sessionKey(data);
      _phone = phone;
      _phoneKey = key;
      _expires = api.clock().add(const Duration(minutes: 5));
    } finally {
      _busy = false;
    }
  }

  Future<QidianCredentials> verifyCode(String input, String code) async {
    final phone = mobile(input);
    if (!RegExp(r'^\d{4,8}$').hasMatch(code.trim())) {
      throw const SourceException('请输入短信验证码');
    }
    if (_busy) throw const SourceException('登录请求进行中，请稍候');
    if (_phone != phone ||
        _phoneKey == null ||
        _expires?.isAfter(api.clock()) != true) {
      throw const SourceException('请先为当前手机号获取验证码');
    }
    _busy = true;
    final generation = _generation;
    try {
      final data = await _request('phonecodelogin', {
        'phone': phone,
        'phonekey': _phoneKey!,
        'phonecode': code.trim(),
      });
      _checkActive(generation);
      _requireComplete(data);
      final guid = '${data['ywGuid'] ?? ''}', key = '${data['ywKey'] ?? ''}';
      if (!RegExp(r'^[1-9]\d*$').hasMatch(guid) || key.isEmpty) {
        throw const SourceException('起点未返回有效的 App 登录会话');
      }
      // No previous session is replaced until both SDK and reader validate.
      final candidate = QidianApi(
        client: api.client,
        device: api.device,
        clock: api.clock,
      );
      final credentials = await candidate.validateLogin(guid, key);
      _checkActive(generation);
      return credentials;
    } finally {
      _busy = false;
    }
  }

  Future<QidianCredentials> loginPassword(
    String account,
    String password,
  ) async {
    if (account.trim().isEmpty) throw const SourceException('请输入起点账号');
    final encrypted = QidianCrypto.encryptPassword(password);
    if (_busy) throw const SourceException('登录请求进行中，请稍候');
    _busy = true;
    final generation = ++_generation;
    try {
      final data = await _request('staticlogin', {
        'username': account.trim(),
        'password': encrypted,
      });
      _checkActive(generation);
      if (_nextAction(data) != 0) {
        throw const SourceException('起点要求额外安全验证，请在官方 App 完成后导入会话，或使用手机号验证码登录');
      }
      return await _validateCredentials(data, generation);
    } finally {
      _busy = false;
    }
  }

  Future<QidianCredentials> importSession(String input) async {
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(input);
      if (decoded is! Map) throw const FormatException();
      final nested = decoded['credentials'] ?? decoded['data'] ?? decoded;
      if (nested is! Map) throw const FormatException();
      data = Map<String, dynamic>.from(nested);
    } catch (_) {
      throw const SourceException('请输入有效的起点 App 会话 JSON');
    }
    if (_busy) throw const SourceException('登录请求进行中，请稍候');
    _busy = true;
    final generation = ++_generation;
    try {
      return await _validateCredentials(data, generation);
    } finally {
      _busy = false;
    }
  }

  Future<QidianCredentials> _validateCredentials(
    Map<String, dynamic> data,
    int generation,
  ) async {
    final guid = '${data['ywGuid'] ?? ''}', key = '${data['ywKey'] ?? ''}';
    if (!RegExp(r'^[1-9]\d*$').hasMatch(guid) ||
        key.isEmpty ||
        RegExp(r'[\s;,\x00-\x1f\x7f]').hasMatch(key)) {
      throw const SourceException('起点 App 会话需要有效的 ywGuid 和 ywKey');
    }
    final candidate = QidianApi(
      client: api.client,
      device: api.device,
      clock: api.clock,
    );
    final credentials = await candidate.validateLogin(guid, key);
    _checkActive(generation);
    return credentials;
  }

  void clear() {
    _generation++;
    _phone = null;
    _phoneKey = null;
    _expires = null;
  }
}
