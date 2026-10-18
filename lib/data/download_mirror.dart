class DownloadMirror {
  const DownloadMirror._(this.enabled, this.baseUrl);

  static const defaultBaseUrl = 'https://gh-proxy.org/';
  static const defaults = DownloadMirror._(true, defaultBaseUrl);

  factory DownloadMirror({
    bool enabled = true,
    String baseUrl = defaultBaseUrl,
  }) {
    final value = baseUrl.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        value.contains(RegExp(r'\s'))) {
      throw const FormatException('请输入有效的 HTTPS 镜像地址，不含账号、查询参数或片段');
    }
    final normalized = uri.toString();
    return DownloadMirror._(
      enabled,
      normalized.endsWith('/') ? normalized : '$normalized/',
    );
  }

  factory DownloadMirror.fromJson(Object? value) {
    if (value is! Map) return defaults;
    final enabled = value['enabled'] != false;
    try {
      return DownloadMirror(
        enabled: enabled,
        baseUrl: value['baseUrl'] is String
            ? value['baseUrl'] as String
            : defaultBaseUrl,
      );
    } on FormatException {
      return DownloadMirror(enabled: enabled);
    }
  }

  final bool enabled;
  final String baseUrl;

  Map<String, Object> toJson() => {'enabled': enabled, 'baseUrl': baseUrl};

  Uri resolve(Uri original) {
    if (!enabled ||
        original.scheme != 'https' ||
        original.userInfo.isNotEmpty ||
        !const {
          'github.com',
          'raw.githubusercontent.com',
        }.contains(original.host)) {
      return original;
    }
    // GH-Proxy expects the complete source URL after the mirror prefix.
    return Uri.parse('$baseUrl$original');
  }
}
