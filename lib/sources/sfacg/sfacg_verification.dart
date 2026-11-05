import 'dart:convert';

import '../../domain/models.dart';
import '../source_verification.dart';

class SfacgVerificationChallenge
    extends SourceWebVerificationChallenge<SfacgVerificationResult> {
  SfacgVerificationChallenge({required this.aid, required this.expiresAt}) {
    if (aid.isEmpty ||
        aid.length > 16384 ||
        aid.contains(RegExp(r'[\x00-\x20\x7f]'))) {
      throw const SourceException('菠萝包安全验证配置无效，请稍后重试');
    }
  }

  final String aid;
  @override
  final DateTime expiresAt;
  @override
  String get title => '菠萝包安全验证';
  @override
  String get instruction => '请完成下方验证，提交成功后可返回原页面重试。';
  @override
  String get profileId => 'sfacg';
  @override
  SourceVerificationDocument createDocument(String nonce) =>
      _SfacgVerificationDocument(nonce, aid);
  @override
  SfacgVerificationResult? parseResult(Object? value) =>
      SfacgVerificationResult.fromCallback(value);
}

/// CancelAccountExceptionSmsActivity in the QEMU-unpacked official APK sends
/// a Tencent ticket before SMS, then submits smsAuthCode with type=check.
class SfacgSmsVerificationChallenge extends SourceSmsVerificationChallenge {
  SfacgSmsVerificationChallenge({
    required this.maskedDestination,
    required this.expiresAt,
    required this._loadCaptcha,
    required this._send,
    required this._submit,
    required void Function() checkActive,
    DateTime? resendAt,
    this._onSend,
  }) : _checkSession = checkActive,
       _resendAt = resendAt,
       _sent = resendAt != null;

  final Future<SfacgVerificationChallenge> Function() _loadCaptcha;
  final Future<void> Function(SfacgVerificationResult) _send;
  final Future<void> Function(String) _submit;
  final void Function() _checkSession;
  final void Function(DateTime)? _onSend;
  @override
  final String maskedDestination;
  @override
  final DateTime expiresAt;
  DateTime? _resendAt;
  bool _busy = false, _closed = false, _completed = false;
  bool _sent;

  @override
  String get title => '菠萝包短信安全验证';
  @override
  String get instruction => '请验证账号绑定的手机号，获取短信前需先完成人机验证。';
  @override
  DateTime? get resendAt => _resendAt;
  @override
  bool get canSubmit => _sent && !_completed;
  bool get completed => _completed;

  void _checkActive() {
    _checkSession();
    if (_closed || !expiresAt.isAfter(DateTime.now())) {
      throw const SourceException('菠萝包短信验证已过期，请重新发起验证');
    }
  }

  void close() => _closed = true;

  @override
  Future<bool> sendCode(SourceVerificationSolver solve) async {
    _checkActive();
    if (_busy || _completed) {
      throw const SourceException('请等待当前短信验证完成');
    }
    if (_resendAt?.isAfter(DateTime.now()) == true) {
      throw const SourceException('请等待倒计时结束后重新获取验证码');
    }
    _busy = true;
    try {
      final captcha = await _loadCaptcha();
      _checkActive();
      final result = await solve(captcha);
      _checkActive();
      if (result == null) return false;
      if (!captcha.expiresAt.isAfter(DateTime.now())) {
        throw const SourceException('菠萝包人机验证已过期，请重新获取验证码');
      }
      // A timeout can still mean the SMS was sent. Keep the cooldown and allow
      // entering an already received code, without automatically sending again.
      _resendAt = DateTime.now().add(const Duration(seconds: 60));
      _sent = true;
      _onSend?.call(_resendAt!);
      await _send(result);
      _checkActive();
      return true;
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> submitCode(String code) async {
    _checkActive();
    if (_busy || _completed) {
      throw const SourceException('请等待当前短信验证完成');
    }
    if (!_sent) throw const SourceException('请先获取短信验证码');
    code = code.trim();
    if (code.isEmpty || code.length > 32 || !RegExp(r'^\d+$').hasMatch(code)) {
      throw const SourceException('请输入有效的短信验证码');
    }
    _busy = true;
    try {
      await _submit(code);
      _checkActive();
      _completed = true;
    } finally {
      _busy = false;
    }
  }

  @override
  bool? parseResult(Object? value) {
    if (value == null) return null;
    _checkActive();
    if (value == true && _completed) return true;
    throw const SourceException('菠萝包尚未确认短信验证结果，请重新验证');
  }
}

class SfacgVerificationResult {
  SfacgVerificationResult({required this.ticket, required this.randstr}) {
    if ([ticket, randstr].any(
      (value) =>
          value.isEmpty ||
          value.length > 16384 ||
          value.contains(RegExp(r'[\s\x00-\x1f\x7f]')),
    )) {
      throw const SourceException('菠萝包安全验证未返回有效结果，请重新验证');
    }
  }

  final String ticket, randstr;

  static SfacgVerificationResult? fromCallback(Object? value) {
    if (value is Map && value['ret'] == 2) return null;
    if (value is! Map ||
        value['ret'] != 0 ||
        value['ticket'] is! String ||
        value['randstr'] is! String) {
      throw const SourceException('菠萝包安全验证未通过，请重新验证');
    }
    return SfacgVerificationResult(
      ticket: value['ticket'],
      randstr: value['randstr'],
    );
  }
}

/// Matches assets/captcha.html and ws.d in the official Android APK. The
/// encrypted aid comes from /user/captcha/aid; no App cookies enter the WebView.
class _SfacgVerificationDocument implements SourceVerificationDocument {
  _SfacgVerificationDocument(this.nonce, this.aid) {
    if (!RegExp(r'^[a-zA-Z0-9-]{1,64}$').hasMatch(nonce)) {
      throw ArgumentError('Invalid verification document nonce');
    }
  }

  @override
  final String nonce;
  final String aid;
  @override
  String get handlerName => 'sfacgVerification';
  @override
  Uri get uri => Uri.https('turing.captcha.qcloud.com', '/unr-sfacg/$nonce');
  @override
  String get html =>
      '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>菠萝包安全验证</title>
<style>html,body{margin:0;background:#fff;height:100%}#captcha{display:flex;justify-content:center}</style>
</head><body><div id="captcha"></div><script>
(() => {
  const nonce = ${jsonEncode(nonce)};
  const aid = ${jsonEncode(aid).replaceAll('<', r'\u003c')};
  let started = false;
  function send(kind, value) {
    window.flutter_inappwebview.callHandler('sfacgVerification', nonce, kind, value);
  }
  function start() {
    if (started || !window.flutter_inappwebview ||
        !window.flutter_inappwebview.callHandler) return;
    started = true;
    const script = document.createElement('script');
    script.src = 'https://turing.captcha.qcloud.com/TJCaptcha.js';
    script.onerror = () => send('error', null);
    script.onload = () => {
      try {
        const captcha = new TencentCaptcha(document.getElementById('captcha'),
          '190225369', result => send('result', result), {
            type: 'embed', loading: true, needFeedBack: false, aidEncrypted: aid,
            ready: () => send('ready', null)
          });
        captcha.show();
      } catch (_) { send('error', null); }
    };
    document.head.appendChild(script);
  }
  window.addEventListener('flutterInAppWebViewPlatformReady', start);
  start();
})();
</script></body></html>''';
}
