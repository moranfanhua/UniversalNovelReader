import '../../domain/models.dart';
import '../source_verification.dart';
import 'qidian_captcha_document.dart';

/// YWLogin's nextAction=11 uses the Tencent captcha configured in the App.
class QidianCaptchaChallenge
    extends SourceWebVerificationChallenge<QidianCaptchaResult> {
  const QidianCaptchaChallenge({required this.expiresAt});

  static const appId = '1600000770';
  @override
  final DateTime expiresAt;
  @override
  String get title => '起点安全验证';
  @override
  String get instruction => '请完成下方验证，通过后将继续获取短信验证码。';
  @override
  String get profileId => 'qidian';
  @override
  String get returnLabel => '返回登录';
  @override
  QidianCaptchaDocument createDocument(String nonce) =>
      QidianCaptchaDocument(nonce);
  @override
  QidianCaptchaResult? parseResult(Object? value) =>
      QidianCaptchaResult.fromCallback(value);
}

class QidianCaptchaResult {
  QidianCaptchaResult({required this.ticket, required this.randstr}) {
    if (!_valid(ticket) || !_valid(randstr)) {
      throw const SourceException('起点安全验证未返回有效结果，请重新验证');
    }
  }

  final String ticket;
  final String randstr;

  static bool _valid(String value) =>
      value.isNotEmpty &&
      value.length <= 16384 &&
      !value.contains(RegExp(r'[\s\x00-\x1f\x7f]'));

  static QidianCaptchaResult? fromCallback(Object? value) {
    if (value is! Map) {
      throw const SourceException('起点安全验证返回异常，请重新验证');
    }
    if (value['ret'] == 2) return null;
    if (value['ret'] != 0 ||
        value['ticket'] is! String ||
        value['randstr'] is! String) {
      throw const SourceException('起点安全验证未通过，请重新验证');
    }
    return QidianCaptchaResult(
      ticket: value['ticket'] as String,
      randstr: value['randstr'] as String,
    );
  }
}

typedef QidianCaptchaSolver =
    Future<QidianCaptchaResult?> Function(QidianCaptchaChallenge challenge);
