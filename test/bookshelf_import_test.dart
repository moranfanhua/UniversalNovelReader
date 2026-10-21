import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/ui/home.dart';
import 'package:unr/sources/bookshelf_source.dart';
import 'package:unr/sources/novel_source.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'helpers/memory_library.dart';
import 'helpers/viewport.dart';

const first = Book(
  id: '1',
  title: '原有作品',
  author: '作者',
  chapters: [Chapter(id: '11', title: '第一章')],
);
const second = Book(
  id: '2',
  title: '新作品',
  author: '作者',
  chapters: [Chapter(id: '22', title: '第一章')],
);
const remote = RemoteBookshelf(id: '10', name: '收藏', bookIds: ['1', '2', '2']);

class FakeShelfSource extends SfacgSource {
  FakeShelfSource()
    : super(
        SfacgApi(client: MockClient((_) async => throw StateError('不应访问网络'))),
      );
  bool fail = false, loggedIn = true;
  final calls = <String>[];
  Completer<Book>? pendingBook;
  @override
  bool get hasSession => loggedIn;
  @override
  Future<List<RemoteBookshelf>> getShelves() async {
    if (!loggedIn) throw const SourceException('请先登录');
    return [remote];
  }

  @override
  Future<Book> getBook(String id) async {
    calls.add(id);
    if (pendingBook != null) return pendingBook!.future;
    if (fail && id == '2') throw const SourceException('作品暂时不可用');
    return id == '1' ? first : second;
  }

  @override
  Future<List<ShelfBookResult>> getShelfBooks(List<String> ids) => Future.wait(
    ids.map((id) async {
      try {
        return ShelfBookResult.success(id, await getBook(id));
      } catch (error) {
        return ShelfBookResult.failure(id, error);
      }
    }),
  );
}

class MemoryShelfLibrary extends TestLibrary with MemoryPersistence {
  MemoryShelfLibrary(
    SfacgSource source, {
    Iterable<NovelSource> sources = const [],
  }) : super(source: source, novelSources: sources);
  // Keep import request counts independent of automatic shelf visit updates.
  @override
  Future<ShelfUpdateResult> refreshShelfBooks({
    String? shelfId,
    required bool Function() isCancelled,
  }) async => const ShelfUpdateResult();
}

void main() {
  test('书架持久化、作品去重并保留既有目录、缓存和进度', () async {
    final root = await Directory.systemTemp.createTemp('unr-shelf-');
    addTearDown(() => root.delete(recursive: true));
    final source = FakeShelfSource();
    addTearDown(source.api.close);
    final library = Library(root, source);
    await library.add(first);
    await library.store(
      first,
      first.chapters.single,
      const ChapterContent([Paragraph('缓存正文')]),
    );
    await library.remember(first, 0, 7);
    final active = library.lastActiveTimes[first.key];
    final shelf = await library.importShelf(
      name: '  我的收藏  ',
      source: source,
      remote: remote,
      imported: [first, second, second],
    );
    expect(shelf.name, '我的收藏');
    expect(shelf.bookKeys, ['sfacg:1', 'sfacg:2']);
    expect(library.books.length, 2);
    final reopened = await Library.open(source, directory: root);
    addTearDown(reopened.dispose);
    addTearDown(library.dispose);
    expect(reopened.shelves.single.bookKeys, shelf.bookKeys);
    expect(reopened.shelves.single.remoteId, '10');
    expect(reopened.progress[first.key], [0, 7]);
    expect(reopened.lastActiveTimes[first.key], active);
    expect(
      (await reopened.cached(
        first,
        first.chapters.single,
      ))!.paragraphs.single.text,
      '缓存正文',
    );
  });

  test('失败保存回滚书架与作品，拒绝空名称和重名', () async {
    final source = FakeShelfSource();
    final library = MemoryShelfLibrary(source);
    addTearDown(source.api.close);
    addTearDown(library.dispose);
    library.books.add(first);
    library.failSave = true;
    await expectLater(
      library.importShelf(
        name: '收藏',
        source: source,
        remote: remote,
        imported: [second],
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(library.books, [first]);
    expect(library.shelves, isEmpty);
    expect(library.lastActiveTimes, isEmpty);
    library.failSave = false;
    await expectLater(
      library.importShelf(
        name: ' ',
        source: source,
        remote: remote,
        imported: [],
      ),
      throwsA(isA<SourceException>()),
    );
    await library.importShelf(
      name: '收藏',
      source: source,
      remote: remote,
      imported: [],
    );
    await expectLater(
      library.importShelf(
        name: ' 收藏 ',
        source: source,
        remote: remote,
        imported: [],
      ),
      throwsA(isA<SourceException>()),
    );
  });

  test('旧书库没有书架字段仍可打开', () async {
    final root = await Directory.systemTemp.createTemp('unr-old-shelf-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/index.json').writeAsString(
      jsonEncode({
        'books': [first.toJson()],
      }),
    );
    final source = FakeShelfSource();
    addTearDown(source.api.close);
    final library = await Library.open(source, directory: root);
    addTearDown(library.dispose);
    expect(library.shelves, isEmpty);
    expect(library.books.single.key, first.key);
  });

  test('菠萝包仅取小说收藏夹并去重作品，未登录不请求', () async {
    var calls = 0;
    final api = SfacgApi(
      client: MockClient((request) async {
        calls++;
        expect(request.url.path, '/user/Pockets');
        expect(request.url.queryParameters['expand'], 'novels');
        return http.Response(
          jsonEncode({
            'status': {'httpCode': 200},
            'data': [
              {
                'pocketId': 10,
                'name': '收藏',
                'typeId': 2,
                'expand': {
                  'novels': [
                    {'novelId': 1},
                    {'novelId': 1},
                    {'novelId': 2},
                  ],
                },
              },
              {'pocketId': 11, 'name': '漫画', 'typeId': 1},
              {
                'pocketId': 12,
                'name': '空书架',
                'typeId': 2,
                'expand': {'novels': []},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(api.close);
    final source = SfacgSource(api);
    await expectLater(source.getShelves(), throwsA(isA<SourceException>()));
    expect(calls, 0);
    api.setCookie('.SFCommunity=fake; session_APP=fake');
    final shelves = await source.getShelves();
    expect(shelves.map((s) => s.name), ['收藏', '空书架']);
    expect(await source.getShelfBookIds(shelves.first), ['1', '2']);
    expect(shelves.last.bookIds, isEmpty);
  });

  test('番茄书架和作品分页，保留长 ID，过滤非小说', () async {
    const one = '7143038691944959011', two = '7143038691944959012';
    final api = FanqieApi(
      client: MockClient((request) async {
        expect(request.headers['cookie'], contains('sessionid=fake'));
        final body = request.body.isEmpty
            ? {}
            : jsonDecode(request.body) as Map;
        final offset = body['offset'] ?? 0;
        final Object data;
        if (request.url.path.contains('folder/list')) {
          data = {
            'folders': [
              {
                'folder_id': offset == 0 ? 10 : 11,
                'folder_name': offset == 0 ? '收藏' : '分组',
              },
            ],
            'has_more': offset == 0,
            'next_offset': 50,
          };
        } else if (request.url.path.contains('folder/detail')) {
          expect(body['folder_id'], 10);
          data = {
            'items': [
              {'item_id': offset == 0 ? one : two, 'book_type': 0},
              {'item_id': one, 'book_type': 0},
              {'item_id': 'audio', 'book_type': 1},
            ],
            'has_more': offset == 0,
            'next_offset': 50,
          };
        } else {
          expect(request.url.path, '/reading/bookapi/bookshelf/info/v/');
          data = {
            'book_list': null,
            'book_shelf_info': [
              {'book_id': one, 'book_type': 0},
              {'book_id': two, 'book_type': 0},
              {'book_id': one, 'book_type': 0},
              {'book_id': 'audio', 'book_type': 1},
            ],
          };
        }
        return http.Response(
          jsonEncode({'code': 0, 'data': data}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    )..setCookie('sessionid=fake');
    api.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});
    addTearDown(api.close);
    final source = FanqieSource(api);
    final shelves = await source.getShelves();
    expect(shelves.map((s) => s.name), ['默认书架', '收藏', '分组']);
    expect(await source.getShelfBookIds(shelves[1]), [one, two]);
    expect(await source.getShelfBookIds(shelves.first), [one, two]);
  });

  test('番茄拒绝不前进的分页和失效会话', () async {
    final api = FanqieApi(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'code': 0,
            'data': {'folders': [], 'has_more': true, 'next_offset': 0},
          }),
          200,
        ),
      ),
    )..setCookie('sessionid=fake');
    api.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});
    addTearDown(api.close);
    final source = FanqieSource(api);
    await expectLater(source.getShelves(), throwsA(isA<SourceException>()));
    api.clearSession();
    await expectLater(source.getShelves(), throwsA(isA<SourceException>()));
  });

  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  void viewport(WidgetTester tester) {
    setTestViewport(
      tester,
      defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1400, 900)
          : const Size(390, 844),
    );
  }

  Future<void> enterImport(
    WidgetTester tester, {
    String platform = '菠萝包轻小说',
    String shelf = '收藏',
  }) async {
    await tester.tap(find.byTooltip('导入'));
    await tester.pumpAndSettle();
    expect(find.text('从本地导入'), findsOneWidget);
    await tester.tap(find.text('从软件导入'));
    await tester.pumpAndSettle();
    expect(find.text('选择平台'), findsOneWidget);
    await tester.tap(find.text(platform));
    await tester.pumpAndSettle();
    await tester.tap(find.text(shelf));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('import-shelf-name')),
      '我的收藏',
    );
  }

  testWidgets('加号分流、平台书架命名导入并切换全部作品', (tester) async {
    viewport(tester);
    final source = FakeShelfSource();
    final library = MemoryShelfLibrary(source)
      ..books.addAll([
        first,
        const Book(id: '3', title: '书架外作品', author: '作者', chapters: []),
      ]);
    addTearDown(source.api.close);
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await enterImport(tester);
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    expect(library.shelves.single.name, '我的收藏');
    expect(library.books.length, 3);
    expect(source.calls, ['2']);
    expect(find.text('已导入书架“我的收藏”，共 2 本作品'), findsOneWidget);
    expect(find.byKey(const ValueKey('bookshelf-selector')), findsOneWidget);
    expect(find.text('书架外作品'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bookshelf-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部作品').last);
    await tester.pumpAndSettle();
    expect(find.text('原有作品'), findsWidgets);
    expect(find.text('新作品'), findsWidgets);
    expect(find.text('书架外作品'), findsWidgets);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('独立首页监听真实保存并立即显示命名书架，重开后仍能切换', (tester) async {
    viewport(tester);
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('unr-shelf-ui-'),
    ))!;
    addTearDown(() => root.delete(recursive: true));
    final source = FakeShelfSource();
    final library = Library(root, source);
    addTearDown(source.api.close);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(home: HomePage(library: library)));
    await tester.runAsync(
      () => library.importShelf(
        name: '持久书架',
        source: source,
        remote: remote,
        imported: [first],
      ),
    );
    await tester.runAsync(
      () => library.refreshShelfBooks(isCancelled: () => false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookshelf-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('持久书架（1）').last);
    await tester.pumpAndSettle();
    expect(find.text('原有作品'), findsWidgets);
    final reopened = await tester.runAsync(
      () => Library.open(source, directory: root),
    );
    addTearDown(reopened!.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(key: const ValueKey('reopened'), library: reopened),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookshelf-selector')));
    await tester.pumpAndSettle();
    expect(find.text('持久书架（1）'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消进行中的导入后不保存书架或作品', (tester) async {
    viewport(tester);
    final source = FakeShelfSource()..pendingBook = Completer<Book>();
    final library = MemoryShelfLibrary(source);
    addTearDown(source.api.close);
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await enterImport(tester);
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pump();
    await tester.tap(find.text('取消导入'));
    source.pendingBook!.complete(first);
    await tester.pumpAndSettle();
    expect(library.shelves, isEmpty);
    expect(library.books, isEmpty);
    expect(find.byTooltip('导入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('失败作品重试只补缺失，取消不写入书库', (tester) async {
    viewport(tester);
    final source = FakeShelfSource()..fail = true;
    final library = MemoryShelfLibrary(source);
    addTearDown(source.api.close);
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await enterImport(tester);
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    expect(library.books, isEmpty);
    expect(library.shelves, isEmpty);
    expect(find.text('仅导入已获取的 1 本'), findsOneWidget);
    source.fail = false;
    await tester.ensureVisible(find.text('重试失败作品'));
    await tester.tap(find.text('重试失败作品'));
    await tester.pumpAndSettle();
    expect(source.calls, ['1', '2', '2']);
    expect(library.shelves.single.bookKeys.length, 2);
    await tester.tap(find.byTooltip('导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从软件导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(library.shelves.length, 1);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('复用最近阅读的目录和进度，不混用其他平台相同 ID', (tester) async {
    viewport(tester);
    final source = FakeShelfSource();
    final library = MemoryShelfLibrary(source)
      ..recentBooks.add(first)
      ..books.add(
        const Book(
          id: '2',
          source: 'fanqie',
          title: '其他平台',
          author: '',
          chapters: [],
        ),
      );
    library.progress[first.key] = [0, 7];
    addTearDown(source.api.close);
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await enterImport(tester);
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    expect(source.calls, ['2']);
    expect(
      library.books.where((book) => book.key == first.key).single,
      same(first),
    );
    expect(library.progress[first.key], [0, 7]);
    expect(library.shelves.single.bookKeys, ['sfacg:1', 'sfacg:2']);
    expect(library.books.any((book) => book.key == 'fanqie:2'), isTrue);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  test('菠萝包复用书架返回的作品信息，不另取详情或目录', () async {
    var requests = 0;
    final api = SfacgApi(
      client: MockClient((request) async {
        requests++;
        expect(request.url.path, '/user/Pockets');
        return http.Response(
          jsonEncode({
            'status': {'httpCode': 200},
            'data': [
              {
                'pocketId': 10,
                'name': '收藏',
                'typeId': 2,
                'expand': {
                  'novels': [
                    {
                      'novelId': 1,
                      'novelName': '作品',
                      'authorName': '作者',
                      'novelCover': 'https://example.com/cover.jpg',
                      'charCount': 12345,
                      'lastUpdateTime': '2026-10-01T12:00:00',
                    },
                  ],
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    )..setCookie('.SFCommunity=fake; session_APP=fake');
    addTearDown(api.close);
    final source = SfacgSource(api);
    final shelves = await source.getShelves();
    final results = await source.getShelfBooks(
      await source.getShelfBookIds(shelves.single),
    );
    final preview = results.single.book!;
    expect(preview.key, 'sfacg:1');
    expect(preview.title, '作品');
    expect(preview.cover, 'https://example.com/cover.jpg');
    expect(preview.wordCount, 12345);
    expect(preview.chapters, isEmpty);
    expect(requests, 1);
  });

  test('菠萝包缺少预览时并行取轻量详情，单本失败保留其余作品', () async {
    final pending = <String, Completer<http.Response>>{};
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.url.path, matches(r'^/novels/[1-4]$'));
        final id = request.url.pathSegments.last;
        expect(pending.containsKey(id), isFalse);
        final response = Completer<http.Response>();
        pending[id] = response;
        return response.future;
      }),
    );
    addTearDown(api.close);
    final request = SfacgSource(api).getShelfBooks(['1', '2', '3', '4']);
    await Future<void>.delayed(Duration.zero);
    expect(pending.keys, unorderedEquals(['1', '2', '3', '4']));
    for (final id in ['4', '3', '2', '1']) {
      pending[id]!.complete(
        http.Response(
          jsonEncode({
            'status': {'httpCode': id == '3' ? 404 : 200},
            'data': {'novelId': int.parse(id), 'novelName': '作品$id'},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
    }
    final result = await request;
    expect(result.map((item) => item.id), ['1', '2', '3', '4']);
    expect(result.where((item) => item.book != null).length, 3);
    expect(result[2].error, isA<SourceException>());
    expect(
      result
          .where((item) => item.book != null)
          .every((item) => item.book!.chapters.isEmpty),
      isTrue,
    );
  });

  testWidgets('番茄大书架按百本批量导入，仅重试缺失并保持原书架顺序', (tester) async {
    viewport(tester);
    final ids = List.generate(105, (i) => '${7143038691944959011 + i}');
    final missing = {ids[1], ids[102]};
    var failMissing = true;
    final batches = <List<String>>[];
    final api = FanqieApi(
      client: MockClient((request) async {
        expect(request.url.host, 'api5-normal-sinfonlineb.fqnovel.com');
        Object data;
        if (request.url.path.endsWith('folder/list/v1/')) {
          data = {'folders': [], 'has_more': false};
        } else if (request.url.path.endsWith('bookshelf/info/v/')) {
          data = {
            'book_shelf_info': [
              for (final id in ids) {'book_id': id, 'book_type': 0},
            ],
          };
        } else {
          expect(request.url.path, '/reading/bookapi/multi-detail/v/');
          final batch = request.url.queryParameters['book_id']!.split(',');
          batches.add(batch);
          data = [
            for (final id in batch.reversed)
              if (!failMissing || !missing.contains(id))
                {'book_id': id, 'book_name': '作品$id', 'author': '作者'},
          ];
        }
        return http.Response(
          jsonEncode({'code': 0, 'data': data}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    )..setCookie('sessionid=fake');
    api.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});
    final sfacg = FakeShelfSource();
    final library = MemoryShelfLibrary(sfacg, sources: [FanqieSource(api)]);
    addTearDown(api.close);
    addTearDown(sfacg.api.close);
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await enterImport(tester, platform: '番茄小说', shelf: '默认书架');
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    expect(batches.map((batch) => batch.length), [100, 5]);
    expect(library.books, isEmpty);
    expect(find.text('仅导入已获取的 103 本'), findsOneWidget);
    failMissing = false;
    await tester.ensureVisible(find.text('重试失败作品'));
    await tester.tap(find.text('重试失败作品'));
    await tester.pumpAndSettle();
    expect(batches.last, [ids[1], ids[102]]);
    expect(batches.length, 3);
    expect(library.shelves.single.bookKeys, ids.map((id) => 'fanqie:$id'));
    expect(library.books.every((book) => book.chapters.isEmpty), isTrue);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('菠萝包取消后不再请求下一批，也不保存已经完成的预览', (tester) async {
    viewport(tester);
    final pending = <Completer<http.Response>>[];
    final api = SfacgApi(
      client: MockClient((request) async {
        if (request.url.path == '/user') {
          return http.Response(
            jsonEncode({
              'status': {'httpCode': 200},
              'data': {'accountId': 42},
            }),
            200,
          );
        }
        if (request.url.path == '/user/Pockets') {
          return http.Response(
            jsonEncode({
              'status': {'httpCode': 200},
              'data': [
                {
                  'pocketId': 10,
                  'name': '收藏',
                  'typeId': 2,
                  'expand': {
                    'novels': [
                      for (var id = 1; id <= 9; id++) {'novelId': id},
                    ],
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        final response = Completer<http.Response>();
        pending.add(response);
        return response.future;
      }),
    )..setCookie('.SFCommunity=fake; session_APP=fake');
    final library = MemoryShelfLibrary(SfacgSource(api));
    addTearDown(api.close);
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await enterImport(tester);
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pump();
    expect(pending.length, 4);
    await tester.tap(find.text('取消导入'));
    for (var i = 0; i < pending.length; i++) {
      pending[i].complete(
        http.Response(
          jsonEncode({
            'status': {'httpCode': 200},
            'data': {'novelId': i + 1, 'novelName': '作品${i + 1}'},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
    }
    await tester.pumpAndSettle();
    expect(pending.length, 4);
    expect(library.books, isEmpty);
    expect(library.shelves, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: platforms);
}
