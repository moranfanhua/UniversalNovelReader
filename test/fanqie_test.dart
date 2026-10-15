import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:crypto/crypto.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/formats/ebook.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';
import 'package:unr/sources/fanqie/fanqie_session.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/account.dart';
import 'package:unr/ui/home.dart';
import 'package:unr/ui/fanqie_account.dart';
import 'package:unr/ui/import_shelf.dart';
import 'package:unr/ui/account_login_method.dart';

const bookId = '7143038691944959011';
const chapterId = '7173216089122439711';
const nextId = '7173217408294453791';

String page(Map<String, dynamic> state, {String font = 'dc027189e0ba4cd'}) =>
    '<script>window.__INITIAL_STATE__=${jsonEncode(state)};}</script><style>$font</style>';

http.Response jsonResponse(Object data) => http.Response(
  jsonEncode({'code': 0, 'data': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> directory() => {
  'allItemIds': [chapterId, nextId],
  'chapterListWithVolume': [
    [
      {
        'itemId': chapterId,
        'title': '第一章',
        'volume_name': '第一卷',
        'needPay': 0,
        'wordNumber': '2500',
      },
    ],
    [
      {
        'itemId': nextId,
        'title': '第二章',
        'volume_name': '第二卷',
        'isChapterLock': true,
      },
    ],
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cipher = Map<String, String>.from(
    jsonDecode(File('assets/fanqie_cipher.json').readAsStringSync()),
  );
  const chapter = Chapter(id: chapterId, title: '第一章');
  const book = Book(
    id: bookId,
    title: '作品',
    author: '作者',
    source: 'fanqie',
    chapters: [chapter],
  );

  test('作品 ID、官网链接与分享文本保持完整长整数，拒绝错误域名和章节 ID 链接', () {
    for (final value in [
      bookId,
      'https://fanqienovel.com/page/$bookId',
      '分享作品 https://reading.snssdk.com/reader/series?book_id=$bookId。',
    ]) {
      expect(FanqieSource.bookId(value), bookId);
    }
    for (final value in [
      '0',
      '123',
      'https://evil.com/page/$bookId',
      'https://fanqienovel.com.evil.com/page/$bookId',
      'https://fanqienovel.com/reader/$chapterId',
      'https://user@fanqienovel.com/page/$bookId',
    ]) {
      expect(() => FanqieSource.bookId(value), throwsA(isA<SourceException>()));
    }
  });

  test('目录保留分卷和受限章节，拒绝重复、缺失及顺序不匹配的目录', () {
    final chapters = FanqieSource.parseDirectory(directory());
    expect(chapters.map((c) => c.volume), ['第一卷', '第二卷']);
    expect(chapters.last.vip, isTrue);
    expect(chapters.first.url, 'https://fanqienovel.com/reader/$chapterId');
    final incomplete = directory()..['allItemIds'] = [chapterId];
    expect(
      () => FanqieSource.parseDirectory(incomplete),
      throwsA(isA<SourceException>()),
    );
    final duplicate = directory()
      ..['chapterListWithVolume'] = [
        [
          {'itemId': chapterId},
          {'itemId': chapterId},
        ],
      ];
    expect(
      () => FanqieSource.parseDirectory(duplicate),
      throwsA(isA<SourceException>()),
    );
    final reordered = directory()..['allItemIds'] = [nextId, chapterId];
    expect(
      () => FanqieSource.parseDirectory(reordered),
      throwsA(isA<SourceException>()),
    );
  });

  test('解析页面状态中的嵌套对象、引号和分号，不执行页面脚本', () {
    final state = {
      'page': {
        'bookName': '引用 "};" 与 \\ 路径',
        'list': [
          {'id': 1},
        ],
      },
    };
    expect(FanqieSource.initialState(page(state)), state);
    expect(
      () => FanqieSource.initialState('<script>alert(1)</script>'),
      throwsA(isA<SourceException>()),
    );
  });

  test('真实字体字符表解码正文，处理空段、换行和插图位置且不改写图片路径', () {
    final api = FanqieApi();
    addTearDown(api.close);
    final source = FanqieSource(api, cipher: cipher);
    final content = source.parseContent(
      '<p>\ue4de\ue449老旧的灯。</p><p></p><p>下一行<br>另起一行</p>'
      '<p><img src="{{image_domain}}{"web_uri":"novel-static/30a4ebc186fd03217fed9c6538360117"}"></p><p>末段😊</p>',
    );
    expect(content.paragraphs.map((p) => p.text), [
      '一个老旧的灯。',
      '下一行',
      '另起一行',
      '',
      '末段😊',
    ]);
    expect(
      content.paragraphs[3].image,
      'https://p3-novel.byteimg.com/novel-static/30a4ebc186fd03217fed9c6538360117~tplv-noop.image',
    );
    expect(
      () => source.parseContent('<p>\ue000</p>'),
      throwsA(isA<SourceException>()),
    );
    expect(
      () => source.parseContent('<p><img src="javascript:alert(1)"></p>'),
      throwsA(isA<SourceException>()),
    );
    expect(
      () => source.parseContent('<p></p>'),
      throwsA(isA<SourceException>()),
    );
  });

  test('搜索使用官方移动端参数，获取详情与完整目录并携带正确书源', () async {
    final api = FanqieApi(
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/api/novel/channel/homepage/search/search/v1/':
            expect(request.url.queryParameters, containsPair('q', '测试书'));
            expect(request.url.queryParameters, containsPair('offset', '20'));
            return jsonResponse({
              'ret_data': [
                {
                  'book_id': bookId,
                  'title': '<b>测试</b>书',
                  'author': '作者',
                  'abstract': '简介',
                },
              ],
            });
          case '/page/$bookId':
            return http.Response(
              page({
                'page': {
                  'bookId': bookId,
                  'bookName': '测试书',
                  'author': '作者',
                  'abstract': '简介',
                  'lastPublishTime': '1670144602',
                  'wordNumber': '3201288',
                },
              }),
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          case '/api/reader/directory/detail':
            return jsonResponse(directory());
          case '/reading/bookapi/multi-detail/v/':
            expect(request.url.queryParameters['book_id'], bookId);
            return http.Response(
              jsonEncode({
                'code': 0,
                'data': [
                  {
                    'book_id': bookId,
                    'shelf_cnt_history': '42000000',
                    'all_bookshelf_count': '230000',
                    'add_bookshelf_count': '0',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          default:
            fail('意外请求 ${request.url}');
        }
      }),
    );
    addTearDown(api.close);
    api.app.restore({'deviceId': '123456789', 'installId': '234567890'});
    final source = FanqieSource(api, cipher: cipher);
    final results = await source.search(' 测试书 ', page: 2);
    expect(results.single.source, 'fanqie');
    expect(results.single.description, '简介');
    expect(results.single.favoriteCount, 42000000);
    final full = await source.getBook(results.single.id);
    expect(full.key, 'fanqie:$bookId');
    expect(full.chapters.length, 2);
    expect(full.wordCount, 3201288);
    expect(full.chapters.first.wordCount, 2500);
    final restored = Book.fromJson(full.toJson());
    expect(restored.wordCount, full.wordCount);
    expect(restored.chapters.first.wordCount, 2500);
    expect(full.updatedAt?.isUtc, isTrue);
  });

  test('收藏数使用累计值，忽略近期计数与无效值，详情失败仍返回搜索结果', () async {
    var failDetails = false;
    final api = FanqieApi(
      client: MockClient((request) async {
        if (request.url.path.contains('/search/')) {
          return jsonResponse({
            'ret_data': [
              {'book_id': bookId, 'title': '测试书'},
            ],
          });
        }
        expect(request.url.path, '/reading/bookapi/multi-detail/v/');
        if (failDetails) return http.Response('', 503);
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': [
              {
                'book_id': bookId,
                'shelf_cnt_history': '-1',
                'all_bookshelf_count': '100',
                'add_bookshelf_count': '0',
              },
              {'book_id': '6982529841564224526', 'shelf_cnt_history': '999'},
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    api.app.restore({'deviceId': '123456789', 'installId': '234567890'});
    expect(await api.app.bookFavoriteCounts([bookId]), isEmpty);
    failDetails = true;
    final books = await FanqieSource(api).search('测试书');
    expect(books.single.title, '测试书');
    expect(books.single.favoriteCount, isNull);
  });

  test('短链接处理空正文跳转，拒绝跳转至外部域名并隔离会话', () async {
    var calls = 0;
    final api = FanqieApi(
      client: MockClient((request) async {
        calls++;
        expect(request.headers.containsKey('cookie'), isFalse);
        return http.Response(
          '',
          302,
          headers: {'location': 'https://evil.com/steal'},
        );
      }),
    )..setCookie('sessionid=test-session');
    addTearDown(api.close);
    expect(
      await api.fetch(
        Uri.parse('https://reading.snssdk.com/h5/test'),
        redirect: false,
      ),
      isA<http.Response>(),
    );
    await expectLater(
      api.fetch(Uri.parse('https://reading.snssdk.com/h5/test')),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 2);
  });

  test('验证码、空响应、业务错误均明确报错且不泄露会话', () async {
    for (final response in [
      http.Response('', 200, headers: {'bdturing-verify': '{}'}),
      http.Response('', 200),
      http.Response('{"code":-1,"message":"test-session","data":{}}', 200),
    ]) {
      final api = FanqieApi(client: MockClient((_) async => response))
        ..setCookie('sessionid=test-session');
      try {
        await expectLater(
          api.get('/api/test'),
          throwsA(
            isA<SourceException>().having(
              (e) => e.message,
              '隐藏凭据',
              isNot(contains('test-session')),
            ),
          ),
        );
      } finally {
        api.close();
      }
    }
  });

  test('错误作品、受限、试读及损坏正文不写入缓存，完整 App 正文可离线导出', () async {
    final root = await Directory.systemTemp.createTemp('unr-fanqie-');
    addTearDown(() => root.delete(recursive: true));
    var data = <String, dynamic>{
      'novel_data': {
        'book_id': bookId,
        'item_id': chapterId,
        'version': 'version-1',
      },
      'crypt_status': 1,
      'compress_status': 0,
      'paragraphs_num': 1,
      'content': '<p idx="0">一个段落</p>',
    };
    var requests = 0;
    final api = FanqieApi(
      client: MockClient((_) async {
        requests++;
        return jsonResponse(data);
      }),
    );
    addTearDown(api.close);
    api.app.restore({
      'deviceId': '123456789',
      'installId': '987654321',
      'key': base64Encode(List.filled(16, 7)),
      'keyOwner': sha256.convert([]).toString(),
    });
    final sf = SfacgApi(
      client: MockClient((_) async {
        fail('番茄正文不应使用菠萝包接口');
      }),
    );
    addTearDown(sf.close);
    final source = FanqieSource(api, cipher: cipher);
    final library = Library(root, SfacgSource(sf), novelSources: [source]);
    final valid = Map<String, dynamic>.from(data);
    for (final overrides in [
      {
        'novel_data': {
          'book_id': nextId,
          'item_id': chapterId,
          'version': 'version-1',
        },
      },
      {
        'novel_data': {
          'book_id': bookId,
          'item_id': nextId,
          'version': 'version-1',
        },
      },
      {'block_data': {}},
      {'is_preview': true},
      {'code_i32': 403},
      {'paragraphs_num': 5},
      {'content': ''},
    ]) {
      data = {...valid, ...overrides};
      await expectLater(
        library.read(book, chapter),
        throwsA(isA<SourceException>()),
      );
      expect(await library.cached(book, chapter), isNull);
    }
    data = valid;
    data = {...valid, 'content': '<p>缺少段落索引</p>'};
    await expectLater(
      library.read(book, chapter),
      throwsA(isA<SourceException>()),
    );
    data = valid;
    expect((await library.read(book, chapter)).paragraphs.single.text, '一个段落');
    await library.add(book);
    final count = requests;
    final reopened = await Library.open(SfacgSource(sf), directory: root);
    expect(reopened.books.single.source, 'fanqie');
    expect((await reopened.read(book, chapter)).paragraphs.single.text, '一个段落');
    expect(requests, count);
    final contents = await reopened.cachedContents(book);
    expect(utf8.decode(Ebook.exportTxt(book, contents)), contains('一个段落'));
    final epub = await Ebook.exportEpub(
      book,
      contents,
      (_) async => throw StateError('无插图'),
    );
    expect(
      Ebook.importEpub(epub).contents.values.single.paragraphs.single.text,
      '一个段落',
    );
    expect(library.commentsFor(book), same(source));
  });

  test('番茄会话独立恢复，损坏会话不覆盖原值，退出清除安全存储', () async {
    const key = 'unr.fanqie.session.v1';
    FlutterSecureStorage.setMockInitialValues({key: 'broken'});
    final api = await FanqieSession.open();
    addTearDown(api.close);
    expect(api.hasSession, isFalse);
    expect(api.sessionNotice, contains('无法恢复'));
    expect(await const FlutterSecureStorage().read(key: key), 'broken');
    api.setCookie('sessionid=synthetic-session');
    await api.onSessionChanged!();
    final restored = await FanqieSession.open();
    addTearDown(restored.close);
    expect(restored.cookie, api.cookie);
    await FanqieSession.logout(restored);
    expect(restored.hasSession, isFalse);
    expect(await const FlutterSecureStorage().read(key: key), isNull);
  });

  testWidgets('无效番茄会话不覆盖已保存账号', (tester) async {
    final api = FanqieApi(
      client: MockClient((request) async {
        expect(request.url.path, '/passport/account/info/v2/');
        return http.Response(
          jsonEncode({'message': 'success', 'data': {}}),
          200,
        );
      }),
    )..setCookie('sessionid=original');
    api.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: FanqieAccountPage(api: api, method: AccountLoginMethod.manual),
      ),
    );
    await tester.enterText(find.byType(TextField), 'sessionid=candidate');
    await tester.tap(find.text('验证并保存会话'));
    await tester.pumpAndSettle();
    expect(api.cookie, 'sessionid=original');
    expect(find.text('番茄会话未登录或已失效'), findsOneWidget);
  });

  test('会话导入拒绝控制字符和缺少会话标识，失败不替换原会话', () {
    final api = FanqieApi()..setCookie('sessionid=original');
    addTearDown(api.close);
    for (final cookie in [
      'sessionid=bad\r\nInjected=1',
      'foo=bar',
      'sessionid=',
      'bad name=x;sessionid=1',
    ]) {
      expect(() => api.setCookie(cookie), throwsA(isA<SourceException>()));
      expect(api.cookie, 'sessionid=original');
    }
  });

  testWidgets('跨平台搜索和账号设置显示番茄入口', (tester) async {
    final root = Directory.systemTemp.createTempSync('unr-fanqie-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final api = FanqieApi();
    addTearDown(api.close);
    final sf = SfacgApi();
    addTearDown(sf.close);
    final library = Library(
      root,
      SfacgSource(sf),
      novelSources: [FanqieSource(api)],
    );
    await tester.pumpWidget(MaterialApp(home: HomePage(library: library)));
    await tester.tap(find.text('书源'));
    await tester.pumpAndSettle();
    expect(find.text('搜索'), findsOneWidget);
    expect(find.textContaining('同时搜索菠萝包轻小说、番茄小说'), findsNothing);
    expect(find.byKey(const ValueKey('novel-source-selector')), findsNothing);
    await tester.pumpWidget(
      MaterialApp(home: AccountSettingsPage(library: library)),
    );
    expect(
      tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title! as Text).data),
      ['番茄小说', '菠萝包轻小说'],
    );
    await tester.tap(find.text('番茄小说'));
    await tester.pumpAndSettle();
    expect(find.text('番茄小说账号'), findsOneWidget);
    expect(find.text('选择登录方式'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(home: ImportShelfPage(library: library)),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title! as Text).data),
      ['番茄小说', '菠萝包轻小说'],
    );
  });
}
