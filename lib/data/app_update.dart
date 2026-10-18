import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:pub_semver/pub_semver.dart';

enum UpdatePlatform { android, windows }

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.notes,
    required this.downloads,
  });
  final Version version;
  final String notes;
  final Map<UpdatePlatform, Uri> downloads;

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    final tag = json['tag_name'] as String;
    final version = Version.parse(tag.startsWith('v') ? tag.substring(1) : tag);
    if (json['draft'] != false ||
        json['prerelease'] != false ||
        version.isPreRelease) {
      throw const FormatException('不是已发布的正式版本');
    }
    final downloads = <UpdatePlatform, Uri>{};
    for (final asset in json['assets'] as List) {
      if (asset is! Map || asset['state'] != 'uploaded') continue;
      final platform = switch (asset['name']) {
        final String name when name == 'unr-$version-windows-x64.zip' =>
          UpdatePlatform.windows,
        final String name when name == 'unr-$version-android-universal.apk' =>
          UpdatePlatform.android,
        _ => null,
      };
      if (platform == null || asset['browser_download_url'] is! String) {
        continue;
      }
      final uri = Uri.tryParse(asset['browser_download_url'] as String);
      // Only accept this repository's matching release asset, before applying
      // the user's download mirror. Never launch arbitrary response URLs.
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          uri.hasPort ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.pathSegments.join('/') !=
              'moranfanhua/UniversalNovelReader/releases/download/$tag/${asset['name']}' ||
          asset['size'] is! num ||
          (asset['size'] as num) <= 0) {
        continue;
      }
      downloads[platform] = uri;
    }
    return AppRelease(
      version: version,
      notes: (json['body'] as String?)?.trim() ?? '',
      downloads: Map.unmodifiable(downloads),
    );
  }
}

class AppUpdates {
  AppUpdates({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? _directClient;

  static final latestRelease = Uri.https(
    'api.github.com',
    '/repos/moranfanhua/UniversalNovelReader/releases/latest',
  );
  final http.Client Function() _clientFactory;
  http.Client? _client;

  static http.Client _directClient() =>
      IOClient(HttpClient()..findProxy = (_) => 'DIRECT');

  Future<AppRelease?> check(String currentVersion) async {
    final Version current;
    try {
      current = Version.parse(currentVersion.split('+').first);
    } on FormatException {
      throw const AppUpdateException('当前版本号无效，无法检查更新');
    }
    if (_client != null) throw const AppUpdateException('正在检查更新，请稍候');
    final client = _clientFactory();
    _client = client;
    try {
      // Version checks always use the GitHub API directly, independently of
      // the download mirror. /latest excludes drafts and prereleases.
      final response = await client
          .get(
            latestRelease,
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'UniversalNovelReader/$currentVersion',
              'X-GitHub-Api-Version': '2022-11-28',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 404) {
        throw const AppUpdateException('尚无公开的正式版本，请稍后重试');
      }
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const AppUpdateException('GitHub 暂时限制访问，请稍后重试');
      }
      if (response.statusCode != 200) {
        throw AppUpdateException('检查更新失败（HTTP ${response.statusCode}），请重试');
      }
      final release = AppRelease.fromJson(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
      // Build metadata does not change semantic version precedence.
      return release.version > current ? release : null;
    } on AppUpdateException {
      rethrow;
    } on TimeoutException {
      throw const AppUpdateException('检查更新超时，请检查网络后重试');
    } on SocketException {
      throw const AppUpdateException('无法连接 GitHub，请检查网络后重试');
    } on http.ClientException {
      throw const AppUpdateException('无法连接 GitHub，请检查网络后重试');
    } on FormatException {
      throw const AppUpdateException('更新信息格式异常，请稍后重试');
    } on TypeError {
      throw const AppUpdateException('更新信息格式异常，请稍后重试');
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  void close() {
    _client?.close();
    _client = null;
  }
}
