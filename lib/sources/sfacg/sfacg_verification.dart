import 'dart:convert';

import '../../domain/models.dart';
import '../source_verification.dart';

class SfacgVerificationChallenge
    extends SourceVerificationChallenge<SfacgVerificationResult> {
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
