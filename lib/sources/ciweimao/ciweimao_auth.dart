import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/models.dart';
import '../session_validation.dart';
import 'ciweimao_api.dart';
import 'ciweimao_crypto.dart';

class CiweimaoAuth {
  CiweimaoAuth(this.api);
  final CiweimaoApi api;
  DateTime? _resendAt, _expiresAt;
  String? _phone;
  _PasswordVerification? _passwordVerification;
  DateTime? _passwordResendAt;
  int _generation = 0;
  int? get passwordCodeLength => _passwordVerification?.codeLength;
  int get passwordResendSeconds {
    final ms = _passwordResendAt?.difference(api.clock()).inMilliseconds ?? 0;
    return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  }

  int get resendSeconds {
    final ms = _resendAt?.difference(api.clock()).inMilliseconds ?? 0;
    return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  }

  void clear() {
    _generation++;
    _phone = null;
    _expiresAt = null;
    _passwordVerification = null;
  }

  void _check(int generation, int sessionGeneration) {
    if (generation != _generation) throw const SourceException('登录操作已取消，请重试');
    api.checkSession(sessionGeneration);
  }

  static String phoneNumber(String input) {
    final value = input.trim().replaceFirst(RegExp(r'^(?:\+86|86-)'), '');
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(value)) {
      throw const SourceException('请输入有效的中国大陆手机号');
    }
    return '86-$value';
  }

  Future<void> sendCode(String input) async {
    final phone = phoneNumber(input);
    if (resendSeconds > 0) throw const SourceException('请稍后再获取验证码');
    _phone = null;
    _expiresAt = null;
    _resendAt = api.clock().add(const Duration(seconds: 60));
    final generation = _generation;
    final session = await api.ensureSession();
    if (!identical(session, api.credentials)) {
      throw const SourceException('刺猬猫账号已切换，请重试');
    }
    final sessionGeneration = api.sessionGeneration;
    _check(generation, sessionGeneration);
    await _sendCode(session, phone, '6');
    _check(generation, sessionGeneration);
    _phone = phone;
    _expiresAt = api.clock().add(const Duration(minutes: 5));
  }

  Future<CiweimaoCredentials> verifyCode(String input, String code) async {
    final phone = phoneNumber(input);
    if (_phone != phone ||
        _expiresAt == null ||
        !api.clock().isBefore(_expiresAt!)) {
      throw const SourceException('请先为当前手机号获取有效验证码');
    }
    if (!RegExp(r'^\d{4,8}$').hasMatch(code.trim())) {
      throw const SourceException('请输入有效的短信验证码');
    }
    return _login('signup/login_v2', {
      'phone_num': phone,
      'ver_code': code.trim(),
      'uuid': api.installation,
      'channel': 'Common_default',
    });
  }

  Future<Map<String, dynamic>> _sendCode(
    CiweimaoCredentials session,
    String account,
    String type,
  ) {
    final timestamp = '${api.clock().millisecondsSinceEpoch}';
    final encrypted = CiweimaoCrypto.encrypt('${session.account}$timestamp');
    return api.request(
      'signup/send_verify_code',
      {
        'phone_num': '',
        'verify_type': type,
        'login_name': account,
        'timestamp': timestamp,
        'hashvalue': md5.convert(utf8.encode(encrypted)).toString(),
      },
      session: session,
      write: true,
    );
  }

  Future<void> sendPasswordCode(String account) async {
    final verification = _passwordVerification;
    if (verification == null || verification.account != account.trim()) {
      throw const SourceException('请先输入账号和密码并点击登录');
    }
    final generation = _generation;
    final session = await api.ensureSession();
    _check(generation, verification.sessionGeneration);
    if (passwordResendSeconds > 0) throw const SourceException('请稍后再获取验证码');
    verification.toCode = null;
    verification.expiresAt = null;
    _passwordResendAt = api.clock().add(const Duration(seconds: 60));
    // APK SwitchAccountActivity.sendCode uses type 5 for password login,
    // and passes the returned to_code alongside the user's verification code.
    final data = await _sendCode(session, verification.account, '5');
    _check(generation, verification.sessionGeneration);
    final toCode = data['to_code'];
    if (toCode is! String || toCode.isEmpty || toCode.length > 1024) {
      throw const SourceException('刺猬猫未返回登录验证凭据，请稍后重新获取验证码');
    }
    verification.toCode = toCode;
    verification.expiresAt = api.clock().add(const Duration(minutes: 5));
  }

  Future<CiweimaoCredentials> passwordLogin(
    String account,
    String password, {
    String code = '',
  }) async {
    final name = account.trim();
    final secret = password.trim();
    if (name.isEmpty || secret.isEmpty) {
      throw const SourceException('请输入刺猬猫账号和密码');
    }
    final generation = _generation;
    final session = await api.ensureSession();
    if (!identical(session, api.credentials)) {
      throw const SourceException('刺猬猫账号已切换，请重试');
    }
    final sessionGeneration = api.sessionGeneration;
    _check(generation, sessionGeneration);
    var verification = _passwordVerification;
    if (verification == null ||
        verification.account != name ||
        verification.sessionGeneration != sessionGeneration) {
      verification = null;
      _passwordVerification = null;
      // APK GetIsuseGeetTask must run before SwitchAccountTask.
      final data = await api.request('signup/use_geetest', {
        'login_name': name,
      }, session: session);
      _check(generation, sessionGeneration);
      switch ('${data['need_use_geetest'] ?? ''}') {
        case '0':
          break;
        case '2':
          final length = int.tryParse('${data['code_len']}');
          if (length == null || length < 4 || length > 8) {
            throw const SourceException('刺猬猫返回的验证码格式已变化，请稍后重试');
          }
          verification = _PasswordVerification(name, length, sessionGeneration);
          _passwordVerification = verification;
        case '1':
          throw const SourceException(
            '需要安全验证，请在刺猬猫官方 App 完成后重新登录或导入 App 会话',
            code: 310002,
          );
        default:
          throw const SourceException('刺猬猫返回的登录验证方式已变化，请稍后重试');
      }
    }
    final extra = <String, String>{};
    if (verification != null) {
      if (verification.toCode == null ||
          verification.expiresAt == null ||
          !api.clock().isBefore(verification.expiresAt!)) {
        throw const SourceException('当前账号需要登录验证码，请获取后再登录', code: 210000);
      }
      if (!RegExp('^\\d{${verification.codeLength}}\$').hasMatch(code.trim())) {
        throw SourceException('请输入 ${verification.codeLength} 位登录验证码');
      }
      extra['ver_code'] = code.trim();
      extra['to_code'] = verification.toCode!;
    }
    return _login('signup/login', {
      'login_name': name,
      'passwd': CiweimaoCrypto.encryptPassword(secret),
      'sign': CiweimaoCrypto.encryptPassword('${name}_$secret'),
      ...extra,
    });
  }

  Future<CiweimaoCredentials> _login(
    String path,
    Map<String, String> params,
  ) async {
    final generation = _generation;
    final session = await api.ensureSession();
    if (!identical(session, api.credentials)) {
      throw const SourceException('刺猬猫账号已切换，请重试');
    }
    final sessionGeneration = api.sessionGeneration;
    _check(generation, sessionGeneration);
    final data = await api.request(path, params, session: session, write: true);
    _check(generation, sessionGeneration);
    final candidate = CiweimaoCredentials.fromApp(data);
    await validate(candidate);
    _check(generation, sessionGeneration);
    return candidate;
  }

  Future<CiweimaoCredentials> importSession(String input) async {
    final CiweimaoCredentials candidate;
    try {
      final doc = jsonDecode(input.trim());
      if (doc is! Map) throw const FormatException();
      final data = doc['data'] is Map ? doc['data'] as Map : doc;
      final value = Map<String, dynamic>.from(data);
      candidate = value['reader_info'] is Map
          ? CiweimaoCredentials.fromApp(value)
          : CiweimaoCredentials.fromJson(value);
      if (candidate.guest) throw const FormatException();
    } catch (_) {
      throw const SourceException(
        '请输入 App 会话 JSON，包含 account、login_token 和 reader_id',
      );
    }
    final generation = _generation, sessionGeneration = api.sessionGeneration;
    await validate(candidate);
    _check(generation, sessionGeneration);
    return candidate;
  }

  Future<void> validate(CiweimaoCredentials candidate) async {
    final data = await api.request('reader/get_my_info', {
      'reader_id': candidate.readerId,
    }, session: candidate);
    final reader = data['reader_info'];
    if (reader is! Map ||
        '${reader['reader_id']}' != candidate.readerId ||
        '${reader['account']}' != candidate.account) {
      throw const SourceException('刺猬猫 App 会话与账号不匹配，原会话已保留');
    }
    const bindings = [
      'is_bind',
      'is_bind_qq',
      'is_bind_weixin',
      'is_bind_huawei',
    ];
    if (bindings.every(reader.containsKey) &&
        bindings.every((k) => '${reader[k]}' == '0')) {
      throw const SourceException('当前是刺猬猫游客会话，请使用已注册账号登录');
    }
  }

  Future<void> checkSession() async {
    final session = api.credentials;
    if (session == null || session.guest) {
      throw const SourceException('请先登录刺猬猫');
    }
    try {
      await validate(session);
    } on SourceException catch (error) {
      if (error.code == 200100 || error.code == 200001) {
        throw const SessionExpiredException('刺猬猫会话已失效，请重新登录');
      }
      rethrow;
    }
  }
}

class _PasswordVerification {
  _PasswordVerification(this.account, this.codeLength, this.sessionGeneration);
  final String account;
  final int codeLength, sessionGeneration;
  String? toCode;
  DateTime? expiresAt;
}
