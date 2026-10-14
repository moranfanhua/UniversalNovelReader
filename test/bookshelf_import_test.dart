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
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

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
}

class MemoryShelfLibrary extends Library {
  MemoryShelfLibrary(FakeShelfSource source)
    : super(Directory.systemTemp, source);
  bool failSave = false;
  @override
  Future<void> save() async {
    if (failSave) throw const FileSystemException('保存失败');
    notifyListeners();
  }
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
    tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
        ? const Size(1400, 900)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> enterImport(WidgetTester tester) async {
    await tester.tap(find.byTooltip('导入'));
    await tester.pumpAndSettle();
    expect(find.text('从本地导入'), findsOneWidget);
    await tester.tap(find.text('从软件导入'));
    await tester.pumpAndSettle();
    expect(find.text('选择平台'), findsOneWidget);
    await tester.tap(find.text('菠萝包轻小说'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
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
}
