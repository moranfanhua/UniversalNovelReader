import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_signature.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

http.Response ok(dynamic data) => http.Response(
  jsonEncode({
    'status': {'httpCode': 200},
    'data': data,
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('作品与目录字数保留在本地书库，旧书无字数仍可恢复', () async {
    final api = SfacgApi(
      client: MockClient((request) async {
        return request.url.path.endsWith('/dirs')
            ? ok({
                'volumeList': [
                  {
                    'volumeId': 1,
                    'chapterList': [
                      {'chapId': 10, 'title': '第一章', 'charCount': '2500'},
                    ],
                  },
                ],
              })
            : ok({'novelName': '字数测试', 'charCount': 100000});
      }),
    );
    addTearDown(api.close);
    final book = await SfacgSource(api).getBook('123');
    final restored = Book.fromJson(book.toJson());
    expect(restored.wordCount, 100000);
    expect(restored.chapters.single.wordCount, 2500);
    final legacy = book.toJson()..remove('wordCount');
    expect(Book.fromJson(legacy).wordCount, isNull);
  });
  test('搜索保留平台收藏数，兼容字符串和缺失计数', () async {
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.url.queryParameters['q'], '测试');
        return ok({
          'novels': [
            {'novelId': 1, 'novelName': '测试', 'markCount': 10390},
            {'novelId': 2, 'novelName': '测试二', 'markCount': '200'},
            {'novelId': 3, 'novelName': '测试三'},
          ],
        });
      }),
    );
    addTearDown(api.close);
    final books = await SfacgSource(api).search(' 测试 ');
    expect(books.map((book) => book.favoriteCount), [10390, 200, null]);
  });
  test('头像读取用户展开字段，兼容评论展开字段', () {
    final parsed = SfacgSource.parseComment({
      'tsukkomiId': 1,
      'content': '[em:sfgirl:004]',
      'postUser': {
        'nickName': '甲',
        'expand': {'avatar': 'https://rss.sfacg.com/a.jpg'},
      },
    });
    expect(parsed.avatar, 'https://rss.sfacg.com/a.jpg');
    expect(parsed.text, '[em:sfgirl:004]');
    expect(
      SfacgSource.parseComment({
        'replyId': 2,
        'replyUser': {'nickName': '乙'},
        'expand': {'avatar': 'https://rss.sfacg.com/b.jpg'},
      }, reply: true).avatar,
      'https://rss.sfacg.com/b.jpg',
    );
  });
  test('计数使用 HEAD 响应头，缓存并合并同段请求', () async {
    var calls = 0;
    final api = SfacgApi(
      client: MockClient((request) async {
        calls++;
        expect(request.method, 'HEAD');
        expect(request.url.queryParameters['row'], '3');
        return http.Response('', 200, headers: {'x-total-count': '27'});
      }),
    );
    final source = SfacgSource(api);
    const chapter = Chapter(id: '1', title: '章');
    expect(
      await Future.wait([
        source.commentCount(chapter, 3),
        source.commentCount(chapter, 3),
      ]),
      [27, 27],
    );
    expect(await source.commentCount(chapter, 3), 27);
    expect(calls, 1);
    await source.commentCount(chapter, 3, refresh: true);
    expect(calls, 2);
    api.close();
  });
  test('计数失败不缓存为零，允许重试', () async {
    var calls = 0;
    final api = SfacgApi(
      client: MockClient(
        (_) async => http.Response(
          '',
          200,
          headers: ++calls == 1 ? {} : {'x-total-count': '0'},
        ),
      ),
    );
    final source = SfacgSource(api);
    const chapter = Chapter(id: '1', title: '章');
    await expectLater(
      source.commentCount(chapter, 1),
      throwsA(isA<SourceException>()),
    );
    expect(await source.commentCount(chapter, 1), 0);
    api.close();
  });
  test('回复跨页去重后按旧到新排序，同时间按 ID 排序', () async {
    final pages = <String>[];
    final api = SfacgApi(
      client: MockClient((request) async {
        final page = request.url.queryParameters['page']!;
        pages.add(page);
        return ok(
          page == '0'
              ? [
                  for (var id = 25; id >= 6; id--)
                    {
                      'replyId': id,
                      'content': '回复$id',
                      'replyDate': '2026-10-12T12:00:00',
                      'replyUser': {'nickName': '读者$id'},
                    },
                ]
              : [
                  for (final id in [6, 5, 4, 3, 2, 1])
                    {
                      'replyId': id,
                      'content': '回复$id',
                      'replyDate': '2026-10-12T12:00:00',
                      'replyUser': {'nickName': '读者$id'},
                    },
                ],
        );
      }),
    );
    final result = await SfacgSource(api).allReplies('1');
    expect(pages, ['0', '1']);
    expect(result.map((r) => r.id), List.generate(25, (i) => '${i + 1}'));
    api.close();
  });
  test('登录时不发送旧 Cookie，校验后才保存新会话', () async {
    var saved = 0;
    final api = SfacgApi(
      client: MockClient((req) async {
        if (req.url.path == '/sessions') {
          expect(req.headers.containsKey('Cookie'), isFalse);
          expect(jsonDecode(req.body)['username'], 'synthetic-account');
          return http.Response(
            jsonEncode({
              'status': {'httpCode': 200},
              'data': {},
            }),
            200,
            headers: {
              'set-cookie':
                  '.SFCommunity=new-community; Path=/user; Expires=Wed, 21 Oct 2037 07:28:00 GMT, session_APP=new-session; Path=/sessions',
            },
          );
        }
        expect(req.url.path, '/user');
        expect(
          req.headers['Cookie'],
          '.SFCommunity=new-community; session_APP=new-session',
        );
        expect(saved, 0);
        return ok({'accountId': 1});
      }),
    )..setCookie('.SFCommunity=old-community; session_APP=old-session');
    api.onSessionChanged = () async {
      saved++;
    };
    await api.login(' synthetic-account ', 'synthetic-password');
    expect(api.cookies['session_APP'], 'new-session');
    expect(saved, 1);
    api.close();
  });

  test('登录拒绝匿名校验，失败不覆盖已有会话', () async {
    final api = SfacgApi(
      client: MockClient((request) async {
        if (request.url.path == '/sessions') {
          expect(jsonDecode(request.body), {
            'username': 'reader',
            'password': 'test-password',
            'shuMeiId': '',
          });
          return http.Response(
            jsonEncode({
              'status': {'httpCode': 200},
              'data': {},
            }),
            200,
            headers: {
              'set-cookie':
                  '.SFCommunity=new; Path=/, session_APP=new-app; Path=/',
            },
          );
        }
        return ok({'accountId': 0, 'userId': 42});
      }),
    )..setCookie('.SFCommunity=old; session_APP=old-app');
    addTearDown(api.close);
    api.onSessionChanged = () async => fail('未校验的会话不得保存');
    await expectLater(
      api.login('reader', 'test-password'),
      throwsA(isA<SourceException>()),
    );
    expect(api.cookies['session_APP'], 'old-app');
  });

  test('登录服务错误不自动重发密码请求', () async {
    var attempts = 0;
    final api = SfacgApi(
      client: MockClient((request) async {
        attempts++;
        return http.Response(
          jsonEncode({
            'status': {'httpCode': 503},
          }),
          503,
        );
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.login('reader', 'test-password'),
      throwsA(isA<SourceException>()),
    );
    expect(attempts, 1);
  });

  test('登录 401 保留错误阶段与错误码，同时隐藏账号密码', () async {
    final api = SfacgApi(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': {
              'httpCode': 401,
              'errorCode': 407,
              'msg':
                  'synthetic-account synthetic-password 13800138000 user@example.test 登录失败',
            },
            'data': null,
          }),
          401,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    try {
      await api.login('synthetic-account', 'synthetic-password');
      fail('应拒绝登录');
    } on SourceException catch (e) {
      expect(e.message, contains('账号登录失败'));
      expect(e.message, contains('错误码 407'));
      for (final secret in [
        'synthetic-account',
        'synthetic-password',
        '13800138000',
        'user@example.test',
      ]) {
        expect(e.message, isNot(contains(secret)));
      }
    }
    api.close();
  });

  test('会话校验失败不会覆盖原来的有效会话', () async {
    var saved = 0;
    final api = SfacgApi(
      client: MockClient((req) async {
        if (req.url.path == '/sessions') {
          return http.Response(
            jsonEncode({
              'status': {'httpCode': 200},
              'data': {},
            }),
            200,
            headers: {
              'set-cookie':
                  '.SFCommunity=candidate; Path=/, session_APP=candidate-session; Path=/',
            },
          );
        }
        return http.Response(
          jsonEncode({
            'status': {'httpCode': 401, 'errorCode': 400, 'msg': '会话无效'},
            'data': null,
          }),
          401,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    )..setCookie('.SFCommunity=original; session_APP=original-session');
    api.onSessionChanged = () async {
      saved++;
    };
    await expectLater(
      api.login('synthetic-account', 'synthetic-password'),
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          '阶段',
          contains('登录会话校验失败'),
        ),
      ),
    );
    expect(api.cookies['session_APP'], 'original-session');
    expect(saved, 0);
    api.close();
  });

  test('App 行内插图与前后文字保持阅读顺序和原始段落编号', () {
    final c = SfacgSource.parseAppContent(
      '前文[img=https://rss.sfacg.com/image.jpg]后文\n\n第三段',
    );
    expect(c.paragraphs.map((p) => p.image ?? p.text), [
      '前文',
      'https://rss.sfacg.com/image.jpg',
      '后文',
      '第三段',
    ]);
    expect(c.paragraphs.map((p) => p.remoteIndex), [1, 1, 1, 3]);
  });

  test('App 多行插图不会变成标签文字或改变后续段评位置', () {
    final c = SfacgSource.parseAppContent(
      '前文\r\n[img=700,875]\r\nhttps://rss.sfacg.com/image.jpg\r\n[/img]\r\n后文\r\n混合[img=https://rss.sfacg.com/other.jpg]结尾',
    );
    expect(c.paragraphs.map((p) => p.image ?? p.text), [
      '前文',
      'https://rss.sfacg.com/image.jpg',
      '后文',
      '混合',
      'https://rss.sfacg.com/other.jpg',
      '结尾',
    ]);
    expect(c.paragraphs.map((p) => p.remoteIndex), [1, 2, 5, 6, 6, 6]);
  });
  test('签名与 SFacgExporter 协议向量一致', () {
    expect(
      sfacgSign(
        '8BB4D95F-7BE3-40D4-BC98-E4DF0B5D4568',
        1791777000123,
        '910D166A-736E-3231-8B21-8D12DFD75F16',
      ),
      'C60655DD55198E0A9F176799E3C8206A',
    );
  });
  test('作品链接不接受伪装域名', () {
    expect(
      SfacgSource.bookId('https://book.sfacg.com/Novel/776753/'),
      '776753',
    );
    expect(SfacgSource.bookId('https://m.sfacg.com/b/776753/'), '776753');
    expect(
      () => SfacgSource.bookId('https://book.sfacg.com.evil.test/Novel/1/'),
      throwsA(isA<SourceException>()),
    );
  });
  test('App 正文保留空段和图片的原始 row', () {
    final content = SfacgSource.parseAppContent(
      '甲 & 😀\n \n[img=https://rss.sfacg.com/图.jpg]\n目标段落',
    );
    expect(content.paragraphs.map((p) => p.remoteIndex), [1, 3, 4]);
    expect(content.paragraphs.first.text, '甲 & 😀');
    expect(content.paragraphs[1].image, contains('rss.sfacg.com'));
  });
  test('段评第一页为 0，row 从 1 开始；正确读取主评论及回复', () async {
    final api = SfacgApi(
      client: MockClient((req) async {
        expect(req.url.path, '/chaps/0/123/tsukkomis');
        expect(req.url.queryParameters['page'], '0');
        expect(req.url.queryParameters['row'], '23');
        expect(req.url.queryParameters['sort'], 'hot');
        expect(req.followRedirects, false);
        return ok([
          {
            'tsukkomiId': 10,
            'row': 23,
            'content': '测试段评',
            'favNum': 2,
            'replyNum': 2,
            'postUser': {'nickName': '读者甲'},
            'expand': {
              'chapterContent': '目标段落',
              'replys': [
                {
                  'replyId': 11,
                  'content': '测试回复',
                  'replyUser': {'nickName': '读者乙'},
                },
              ],
            },
          },
        ]);
      }),
    );
    final result = await SfacgSource(
      api,
    ).comments(const Chapter(id: '123', title: '章节'), 23);
    expect(result.single.author, '读者甲');
    expect(result.single.likes, 2);
    expect(result.single.replyCount, 2);
    expect(result.single.replies.single.author, '读者乙');
    expect(result.single.paragraphText, '目标段落');
    api.close();
  });
  test('分页和最新排序发送正确参数', () async {
    final api = SfacgApi(
      client: MockClient((req) async {
        expect(req.url.queryParameters['page'], '1');
        expect(req.url.queryParameters['sort'], 'date');
        return ok([]);
      }),
    );
    expect(
      await SfacgSource(api).comments(
        const Chapter(id: '123', title: ''),
        1,
        page: 1,
        sort: CommentSort.latest,
      ),
      isEmpty,
    );
    api.close();
  });
  test('回复分页同样从 0 开始', () async {
    final api = SfacgApi(
      client: MockClient((req) async {
        expect(req.url.path, '/tsukkomis/0/10/replys');
        expect(req.url.queryParameters['page'], '0');
        return ok([
          {
            'replyId': 11,
            'content': '回复',
            'replyUser': {'nickName': '乙'},
          },
        ]);
      }),
    );
    expect((await SfacgSource(api).replies('10')).single.id, '11');
    api.close();
  });
  test('已登录正文请求关闭自动购买', () async {
    final cipher = <String, String>{
      for (var i = 0; i < 3751; i++) '$i': '$i',
      '宦': '啊',
    }..remove('0');
    final api = SfacgApi(
      client: MockClient((req) async {
        expect(req.url.host, 'api.sfacg.com');
        expect(req.url.queryParameters['autoOrder'], 'false');
        expect(req.headers['Cookie'], contains('session_APP=synthetic'));
        return ok({
          'content': '宦😀',
          'expand': {'content': '\n末段'},
        });
      }),
    )..setCookie('.SFCommunity=synthetic; session_APP=synthetic');
    final result = await SfacgSource(api, cipher: cipher).readChapter(
      const Book(id: '1', title: '', author: '', chapters: []),
      const Chapter(id: '123', title: '', vip: true),
    );
    expect(result.paragraphs.first.text, '啊😀');
    api.close();
  });
  test('已登录免费章节走 App 接口，false 加密标记仍还原字符且保留段落编号', () async {
    final cipher = <String, String>{
      for (var i = 0; i < 3751; i++) '$i': '$i',
      '宦': '啊',
    }..remove('0');
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.url.host, 'api.sfacg.com');
        expect(request.url.path, '/Chaps/8016101');
        expect(request.url.queryParameters['autoOrder'], 'false');
        expect(
          request.url.queryParameters['expand'],
          'content,needFireMoney,originNeedFireMoney,tsukkomi,chatlines,isbranch,isContentEncrypted,authorTalk',
        );
        expect(request.headers['User-Agent'], contains('boluobao/5.2.16'));
        expect(
          request.headers['sfsecurity'],
          contains('devicetoken=${SfacgApi.compatibilityDevice}'),
        );
        return ok({
          'expand': {'content': '宦\n\n第二段', 'isContentEncrypted': false},
        });
      }),
    )..setCookie('.SFCommunity=synthetic; session_APP=synthetic');
    addTearDown(api.close);
    final content = await SfacgSource(api, cipher: cipher).readChapter(
      const Book(id: '669015', title: '', author: '', chapters: []),
      const Chapter(
        id: '8016101',
        title: '',
        url: 'https://book.sfacg.com/unavailable/',
      ),
    );
    expect(content.paragraphs.map((p) => p.text), ['啊', '第二段']);
    expect(content.paragraphs.map((p) => p.remoteIndex), [1, 3]);
  });
  for (final website in [false, true]) {
    test('${website ? '仅官网会话' : '未登录'}免费章节使用匿名 App 接口，不回退网页', () async {
      var requests = 0;
      final api = SfacgApi(
        client: MockClient((request) async {
          requests++;
          expect(request.url.host, 'api.sfacg.com');
          expect(request.url.path, '/Chaps/123');
          expect(request.url.queryParameters['autoOrder'], 'false');
          expect(request.headers.containsKey('Cookie'), isFalse);
          return ok({'content': '免费正文'});
        }),
      );
      addTearDown(api.close);
      if (website) api.setCookie('.SFCommunity=website', website: true);
      final source = SfacgSource(
        api,
        cipher: {for (var i = 0; i < 3751; i++) '$i': '$i'},
      );
      final content = await source.readChapter(
        const Book(id: '1', title: '', author: '', chapters: []),
        const Chapter(
          id: '123',
          title: '',
          url: 'https://book.sfacg.com/unavailable/',
        ),
      );
      expect(content.paragraphs.single.text, '免费正文');
      expect(requests, 1);
      if (website) expect(api.cookies['.SFCommunity'], 'website');
    });
  }
  test('导入 App 会话校验沿用已保存的请求配置', () async {
    const device = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
    const agent = 'boluobao/5.2.84(android;36)/OPPO/device/OPPO';
    final api = SfacgApi(
      device: device,
      appUserAgent: agent,
      client: MockClient((request) async {
        expect(request.url.path, '/user');
        expect(request.headers['User-Agent'], agent);
        expect(request.headers['sfsecurity'], contains('devicetoken=$device'));
        return ok({'accountId': 1});
      }),
    );
    addTearDown(api.close);
    await api.importCookie('.SFCommunity=synthetic; session_APP=synthetic');
    expect(api.hasSession, isTrue);
    expect(api.appUserAgent, agent);
  });
  test('VIP 展开正文和免费正文使用同一签名接口，保留会话且不购买', () async {
    var requests = 0;
    final cipher = <String, String>{
      for (var i = 0; i < 3751; i++) '$i': '$i',
      '宦': '啊',
    }..remove('0');
    final api = SfacgApi(
      client: MockClient((request) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.url.path, '/Chaps/7940328');
        expect(request.url.queryParameters['autoOrder'], 'false');
        expect(
          request.headers['Cookie'],
          '.SFCommunity=synthetic; session_APP=synthetic',
        );
        return ok({
          'chapOrder': true,
          'isVip': true,
          'expand': {
            'content': '宦\n[img=https://rss.sfacg.com/宦.jpg]\n末段',
            'isContentEncrypted': false,
          },
        });
      }),
    )..setCookie('.SFCommunity=synthetic; session_APP=synthetic');
    addTearDown(api.close);
    final content = await SfacgSource(api, cipher: cipher).readChapter(
      const Book(id: '657818', title: '', author: '', chapters: []),
      const Chapter(id: '7940328', title: '', vip: true),
    );
    expect(content.paragraphs.map((p) => p.image ?? p.text), [
      '啊',
      'https://rss.sfacg.com/宦.jpg',
      '末段',
    ]);
    expect(api.hasSession, isTrue);
    expect(requests, 1);
  });
  test('正文 507 表示请求配置被拒绝，提示不误导为需要购买或反复登录', () async {
    final api = SfacgApi(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': {'httpCode': 401, 'errorCode': 507, 'msg': '没有访问接口的权限'},
            'data': null,
          }),
          401,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    )..setCookie('.SFCommunity=synthetic; session_APP=synthetic');
    addTearDown(api.close);
    await expectLater(
      api.get('Chaps/7940328'),
      throwsA(
        isA<SourceException>()
            .having((e) => e.code, 'HTTP status', 401)
            .having((e) => e.errorCode, 'API error', 507)
            .having((e) => e.message, '提示', contains('App 请求配置')),
      ),
    );
    expect(api.hasSession, isTrue);
  });
  test('未订阅 VIP 的 403 保留阅读权限提示且不自动购买', () async {
    var requests = 0;
    final api = SfacgApi(
      client: MockClient((request) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.url.host, 'api.sfacg.com');
        expect(request.url.path, '/Chaps/2');
        expect(request.url.queryParameters['autoOrder'], 'false');
        return http.Response(
          jsonEncode({
            'status': {'httpCode': 403, 'errorCode': 402, 'msg': '尚未订阅本章'},
            'data': null,
          }),
          403,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    )..setCookie('.SFCommunity=synthetic; session_APP=synthetic');
    addTearDown(api.close);
    await expectLater(
      SfacgSource(api).readChapter(
        const Book(id: '1', title: '', author: '', chapters: []),
        const Chapter(id: '2', title: '', vip: true),
      ),
      throwsA(
        isA<SourceException>()
            .having((e) => e.code, 'HTTP status', 403)
            .having((e) => e.errorCode, 'API error', 402)
            .having((e) => e.message, '提示', contains('尚未订阅本章')),
      ),
    );
    expect(requests, 1);
    expect(api.hasSession, isTrue);
  });
  test('图片 URL 不经过汉字字符替换', () {
    final source = SfacgSource(SfacgApi(), cipher: {'宦': '啊'});
    expect(
      source.decode('宦[img=700,875]https://rss.sfacg.com/宦.jpg[/img]宦'),
      '啊[img=700,875]https://rss.sfacg.com/宦.jpg[/img]啊',
    );
    source.api.close();
  });
}
