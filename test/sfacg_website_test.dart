import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

void main() {
  test('拒绝导入网页会话，不请求网页且保留原 App 会话', () async {
    final api = SfacgApi(client: MockClient((_) async => fail('不应请求网页')))
      ..setCookie('.SFCommunity=original; session_APP=original-app');
    addTearDown(api.close);
    await expectLater(
      api.importCookie('.SFCommunity=website'),
      throwsA(isA<SourceException>()),
    );
    expect(api.cookies['.SFCommunity'], 'original');
    expect(api.hasSession, isTrue);
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
