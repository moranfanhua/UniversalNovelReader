import 'dart:convert';
import 'package:http/http.dart' as http;

Map<String, dynamic> releaseJson({String version = '0.4.0'}) => {
  'tag_name': 'v$version',
  'draft': false,
  'prerelease': false,
  'body': '更新说明：修复阅读问题',
  'assets': [
    for (final suffix in [
      'windows-x64.zip',
      'android-universal.apk',
      'android-arm64-v8a.apk',
      'android-armeabi-v7a.apk',
      'android-x86_64.apk',
    ])
      {
        'name': 'unr-$version-$suffix',
        'state': 'uploaded',
        'size': 1024,
        'browser_download_url':
            'https://github.com/moranfanhua/UniversalNovelReader/releases/download/v$version/unr-$version-$suffix',
      },
  ],
};

http.Response jsonResponse(Map<String, dynamic> json) =>
    http.Response.bytes(utf8.encode(jsonEncode(json)), 200);
