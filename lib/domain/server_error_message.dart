import 'dart:convert';

/// An explicit App API error description, never an entire response or exception.
/// Callers supply request/session values so even unlabelled echoes are removed.
class ServerErrorMessage {
  const ServerErrorMessage._(this.text);

  final String text;

  static ServerErrorMessage? parse(
    Object? value, {
    Iterable<Object?> secrets = const [],
    Object? responseData,
  }) {
    if (value is! String || value.length > 2048) return null;
    var text = value.trim();
    if (text.isEmpty || RegExp(r'^[\[\{<]').hasMatch(text)) return null;

    // Decode escaped echoes before redaction; never truncate a secret first.
    for (var i = 0; i < 2; i++) {
      final decoded = text.replaceAllMapped(RegExp(r'(?:%[0-9a-fA-F]{2})+'), (
        match,
      ) {
        try {
          return Uri.decodeComponent(match[0]!);
        } on ArgumentError {
          return match[0]!;
        } on FormatException {
          return match[0]!;
        }
      });
      if (decoded == text) break;
      text = decoded;
    }
    if (RegExp(r'^\s*[\[\{<]').hasMatch(text)) return null;
    final hidden = <String>{
      for (final secret in [
        ...secrets.expand(_values),
        ..._responseSecrets(responseData),
      ].where((s) => s.isNotEmpty)) ...[
        secret,
        base64Encode(utf8.encode(secret)),
        jsonEncode(secret).substring(1, jsonEncode(secret).length - 1),
      ],
    }.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in hidden) {
      text = text.replaceAll(secret, '[已隐藏]');
    }
    text = text
        .replaceAll(
          RegExp(
            r'''(?:cookie|authorization|bearer|password|passwd|pwd|token|session\w*|sid\w*|uid\w*|user_?id|account|username|phone|mobile|email|ticket|randstr|captcha\w*|sign\w*|device\w*|install\w*|iid|ywkey|ywguid|cmfutoken|key|code|content|账号|账户|用户名|昵称|密码|手机号|验证码|验证票据|阅读密钥|正文)["']?\s*[:=：]\s*[^;,，；\r\n]*''',
            caseSensitive: false,
          ),
          '[敏感字段已隐藏]',
        )
        .replaceAll(
          RegExp(
            r'''(?:https?://|file://|www\.)[^\s<>"'，；]+''',
            caseSensitive: false,
          ),
          '[地址已隐藏]',
        )
        .replaceAll(RegExp(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}'), '[邮箱已隐藏]')
        .replaceAll(RegExp(r'\d{4,}'), '[数字已隐藏]')
        .replaceAll(RegExp(r'(?:%[0-9a-fA-F]{2})+'), '[编码已隐藏]')
        .replaceAll(RegExp(r'(?:\\u[0-9a-fA-F]{4})+'), '[编码已隐藏]')
        .replaceAll(RegExp(r'[A-Za-z0-9_+/=\-]{24,}'), '[标识已隐藏]')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return null;
    // Bound display size without splitting surrogate pairs.
    final runes = text.runes.toList();
    if (runes.length > 160) text = '${String.fromCharCodes(runes.take(159))}…';
    return ServerErrorMessage._(text);
  }

  String appendTo(String message) => '$message；服务端：$text';

  static final _privateField = RegExp(
    r'^(?:account|username|userid|readerid|name|nickname|phone|mobile|email|password|passwd|pwd|cookie|authorization|content|body|text)$|token|session|secret|key|ticket|captcha|randstr|device|install|^uid',
    caseSensitive: false,
  );

  static Iterable<String> _responseSecrets(Object? value) sync* {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = '${entry.key}'.replaceAll('_', '');
        if (_privateField.hasMatch(key)) {
          yield* _values(entry.value);
        } else {
          yield* _responseSecrets(entry.value);
        }
      }
    } else if (value is Iterable) {
      for (final item in value) {
        yield* _responseSecrets(item);
      }
    }
  }

  static Iterable<String> _values(Object? value) sync* {
    if (value is String || value is num) {
      yield '$value';
    } else if (value is Map) {
      for (final item in value.values) {
        yield* _values(item);
      }
    } else if (value is Iterable) {
      for (final item in value) {
        yield* _values(item);
      }
    }
  }
}
