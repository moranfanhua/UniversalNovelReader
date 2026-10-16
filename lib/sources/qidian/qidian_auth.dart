import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models.dart';
import '../logged_request.dart';
import 'qidian_api.dart';
import 'qidian_crypto.dart';

/// Official YWLogin SDK PhoneCodeActivity: sendphonecode → phonecodelogin.
class QidianAuth {
  QidianAuth(this.api);
  final QidianApi api;
  String? _phone, _phoneKey;
  DateTime? _expires, _resendAt;
  bool _busy = false;

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
        '起点登录请求失败，请检查验证码或稍后重试（${code ?? response.statusCode}）',
        code: code ?? response.statusCode,
      );
    }
    final data = doc['data'];
    if (data is! Map) throw const SourceException('起点登录服务未返回完整数据');
    if (int.tryParse('${data['nextAction'] ?? 0}') != 0) {
      throw const SourceException('起点要求额外安全验证，请先在官方 App 完成验证后重试');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<void> sendCode(String input) async {
    final phone = mobile(input);
    if (_busy || resendSeconds > 0) throw const SourceException('请稍后再获取验证码');
    _busy = true;
    _phone = null;
    _phoneKey = null;
    // A timeout may still have sent the SMS. Do not automatically resend it.
    _resendAt = api.clock().add(const Duration(seconds: 60));
    try {
      final data = await _request('sendphonecode', {
        'phone': phone,
        'type': '1',
        'needRegister': '1',
      });
      final key = '${data['sessionKey'] ?? ''}';
      if (key.isEmpty || key.contains(RegExp(r'[\x00-\x1f]'))) {
        throw const SourceException('起点未返回验证码会话，请稍后重试');
      }
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
    try {
      final data = await _request('phonecodelogin', {
        'phone': phone,
        'phonekey': _phoneKey!,
        'phonecode': code.trim(),
      });
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
      return await candidate.validateLogin(guid, key);
    } finally {
      _busy = false;
    }
  }

  void clear() {
    _phone = null;
    _phoneKey = null;
    _expires = null;
  }
}
