import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

void main() {
  test('官网会话独立校验并读取已有权限正文，不调用 App 认证或购买接口', () async {
    final paths = <String>[];
    final api = SfacgApi(
      client: MockClient((request) async {
        paths.add(request.url.path);
        expect(request.method, 'GET');
        expect(request.headers['Cookie'], '.SFCommunity=website');
        expect(request.headers.containsKey('Authorization'), isFalse);
        if (request.url.host == 'passport.sfacg.com') {
          expect(request.url.queryParameters['callback'], 'unrLoginInfo');
          return http.Response('unrLoginInfo([{login:"true",name:"reader"}])', 200);
        }
        expect(request.url.host, 'book.sfacg.com');
        return http.Response(
          '<div id="ChapterBody"><p>已有阅读权限的正文</p></div>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }),
    );
    addTearDown(api.close);
    await api.importCookie('.SFCommunity=website', website: true);
    final source = SfacgSource(api);
    final chapter = await source.readChapter(
      const Book(id: '1', title: '', author: '', chapters: []),
      const Chapter(id: '123', title: '', vip: true),
    );
    expect(chapter.paragraphs.single.text, '已有阅读权限的正文');
    expect(paths, ['/Ajax/GetLoginInfo.ashx', '/vip/c/123/']);
    expect(source.commentCapabilities.post, isFalse);
    expect(source.commentCapabilities.replies, isTrue);
    expect(source.commentCapabilities.likes, isFalse);
  });

  test('官网拒绝未登录、异常和重定向状态，失败保留原 App 会话', () async {
    var body = '', status = 200;
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        return http.Response(
          body,
          status,
          headers: {'location': 'https://evil.test/'},
        );
      }),
    )..setCookie('.SFCommunity=original; session_APP=original-app');
    addTearDown(api.close);
    for (final response in [
      ('unrLoginInfo([{login:"false"}])', 200),
      ('unrLoginInfo([{login:"false",name:"login:true"}])', 200),
      ('<html>login:"true"</html>', 200),
      ('otherCallback([{login:"true"}])', 200),
      ('unrLoginInfo([{login:"true"}])', 302),
      ('unrLoginInfo([{login:"true"}])', 500),
    ]) {
      (body, status) = response;
      await expectLater(
        api.importCookie('.SFCommunity=website', website: true),
        throwsA(isA<SourceException>()),
      );
      expect(api.cookies['.SFCommunity'], 'original');
      expect(api.websiteSession, isFalse);
    }
  });

  test('官网付费预览不作为正文缓存，不能触发自动订阅', () async {
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.url.path, '/vip/c/123/');
        expect(request.method, 'GET');
        return http.Response(
          '<div id="ChapterBody">试读预览</div><div class="pay-section">订阅</div>',
          200,
            headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }),
    )..setCookie('.SFCommunity=website', website: true);
    addTearDown(api.close);
    await expectLater(
      SfacgSource(api).readChapter(
        const Book(id: '1', title: '', author: '', chapters: []),
        const Chapter(id: '123', title: '', vip: true),
      ),
      throwsA(isA<SourceException>()),
    );
  });

  test('官网 Cookie 不发送到 App API，App 匿名响应不会覆盖官网会话', () async {
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.url.host, 'api.sfacg.com');
        expect(request.headers.containsKey('Cookie'), isFalse);
        return http.Response(
          jsonEncode({
            'status': {'httpCode': 200},
            'data': [],
          }),
          200,
          headers: {'set-cookie': '.SFCommunity=anonymous; Path=/'},
        );
      }),
    )..setCookie('.SFCommunity=website', website: true);
    addTearDown(api.close);
    await api.get('search/novels/result/new');
    expect(api.cookies['.SFCommunity'], 'website');
    await expectLater(
      api.request('chaps/0/123/tsukkomis', body: {'content': '草稿'}),
      throwsA(isA<SourceException>()),
    );
  });
}
