import 'dart:convert';

import 'qidian_captcha.dart';

/// Served locally by the WebView interceptor. No phone or login keys enter it.
class QidianCaptchaDocument {
  QidianCaptchaDocument(this.nonce) {
    if (!RegExp(r'^[a-zA-Z0-9-]{1,64}$').hasMatch(nonce)) {
      throw ArgumentError('Invalid captcha document nonce');
    }
  }

  final String nonce;
  Uri get uri => Uri.https('turing.captcha.qcloud.com', '/unr-captcha/$nonce');

  String get html =>
      '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>起点安全验证</title>
<style>html,body{margin:0;background:#fff;height:100%;font-family:sans-serif}</style>
</head><body><script>
(() => {
  const nonce = ${jsonEncode(nonce)};
  let started = false;
  function send(kind, value) {
    window.flutter_inappwebview.callHandler('qidianCaptcha', nonce, kind, value);
  }
  function start() {
    if (started || !window.flutter_inappwebview ||
        !window.flutter_inappwebview.callHandler) return;
    started = true;
    const script = document.createElement('script');
    // Same SDK entry point used by the official Android APK.
    script.src = 'https://turing.captcha.qcloud.com/TCaptcha.js';
    script.onerror = () => send('error', null);
    script.onload = () => {
      try {
        const captcha = new TencentCaptcha(
          '${QidianCaptchaChallenge.appId}',
          result => send('result', result),
          {ready: () => send('ready', null)}
        );
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
