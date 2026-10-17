import '../../domain/models.dart';

/// YWLogin's nextAction=11 uses the Tencent captcha configured in the App.
class QidianCaptchaChallenge {
  const QidianCaptchaChallenge({required this.expiresAt});

  static const appId = '1600000770';
  final DateTime expiresAt;
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
