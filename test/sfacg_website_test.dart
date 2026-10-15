import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

void main() {
  test('官网会话独立校验，VIP 正文提示改用 App 会话且不请求网页', () async {
    final paths = <String>[];
    final api = SfacgApi(
      client: MockClient((request) async {
        paths.add(request.url.path);
        expect(request.method, 'GET');
        expect(request.headers['Cookie'], '.SFCommunity=website');
        expect(request.headers.containsKey('Authorization'), isFalse);
        if (request.url.host == 'passport.sfacg.com') {
          expect(request.url.queryParameters['callback'], 'unrLoginInfo');
          return http.Response(
            'unrLoginInfo([{login:"true",name:"reader"}])',
            200,
          );
        }
        fail('官网会话校验不应发起正文请求');
      }),
    );
    addTearDown(api.close);
    await api.importCookie('.SFCommunity=website', website: true);
    final source = SfacgSource(api);
    await expectLater(
      source.readChapter(
        const Book(id: '1', title: '', author: '', chapters: []),
        const Chapter(id: '123', title: '', vip: true),
      ),
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          '提示',
          contains('App 会话'),
        ),
      ),
    );
    expect(paths, ['/Ajax/GetLoginInfo.ashx']);
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

  test('官网会话读取 VIP 时保留会话，不请求预览或自动订阅', () async {
    final api = SfacgApi(
      client: MockClient((request) async {
        fail('官网会话不应发起 VIP 正文请求');
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
    expect(api.websiteSession, isTrue);
    expect(api.cookies['.SFCommunity'], 'website');
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
