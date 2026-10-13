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

  test('嵌套插图与前后文字保持阅读顺序和原始段落编号', () {
    final c = SfacgSource.parsePublicChapter(
      '<div id="ChapterBody"><p>前文<span><img src="/image.jpg"></span>后文</p><p></p><p>第三段</p></div>',
    );
    expect(c.paragraphs.map((p) => p.image ?? p.text), [
      '前文',
      'https://book.sfacg.com/image.jpg',
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
  test('免费正文保留空段和图片的原始 row', () {
    final content = SfacgSource.parsePublicChapter(
      '<div id="ChapterBody"><p>甲 &amp; 😀</p><p> </p><p><img src="https://rss.sfacg.com/图.jpg"></p><p>目标段落</p></div>',
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
  test('图片 URL 不经过汉字字符替换', () {
    final source = SfacgSource(SfacgApi(), cipher: {'宦': '啊'});
    expect(
      source.decode('宦[img=700,875]https://rss.sfacg.com/宦.jpg[/img]宦'),
      '啊[img=700,875]https://rss.sfacg.com/宦.jpg[/img]啊',
    );
    source.api.close();
  });
}
