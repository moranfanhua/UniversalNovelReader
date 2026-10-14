import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/models.dart';

class SfacgWebsite {
  SfacgWebsite(this.client, this.cookie);

  final http.Client client;
  final String cookie;

  Future<String> _get(Uri uri) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll({
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://m.sfacg.com/',
        'Cookie': cookie,
      });
    final response = await (() async => http.Response.fromStream(
      await client.send(request),
    ))().timeout(const Duration(seconds: 25));
    if (response.statusCode >= 300 && response.statusCode < 400 ||
        response.statusCode == 401 ||
        response.statusCode == 403) {
      throw const SourceException('菠萝包官网会话未登录或已失效，请重新登录');
    }
    if (response.statusCode != 200) {
      throw SourceException('菠萝包官网暂时无法访问（HTTP ${response.statusCode}）');
    }
    return utf8.decode(response.bodyBytes);
  }

  Future<void> validateSession() async {
    final body = (await _get(
      Uri.https('passport.sfacg.com', '/Ajax/GetLoginInfo.ashx', {
        'callback': 'unrLoginInfo',
      }),
    )).trim();
    // The official endpoint returns JSONP with unquoted object keys, not JSON.
    // Read only its leading login flag; never evaluate the returned JavaScript.
    final match = RegExp(
      r'''^unrLoginInfo\(\s*\[\s*\{\s*["']?login["']?\s*:\s*(?:"(true|false)"|'(true|false)'|(true|false))\s*[,}][\s\S]*\]\s*\)\s*;?$''',
    ).firstMatch(body);
    if (match == null) {
      throw const SourceException('菠萝包官网返回无法识别的登录状态，请稍后重试');
    }
    if ((match[1] ?? match[2] ?? match[3]) != 'true') {
      throw const SourceException('菠萝包官网会话未登录或已失效，请重新登录');
    }
  }

  Future<String> chapterHtml(String chapterId) {
    if (!RegExp(r'^[1-9]\d*$').hasMatch(chapterId)) {
      throw const SourceException('菠萝包章节编号无效');
    }
    return _get(Uri.https('book.sfacg.com', '/vip/c/$chapterId/'));
  }
}
