import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/novel_search.dart';
import 'package:unr/sources/novel_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/home.dart';
import 'package:unr/ui/settings.dart';

Book book(
  String id,
  String title, {
  String source = 'sfacg',
  String author = '作者',
  int? favorites,
}) => Book(
  id: id,
  title: title,
  source: source,
  author: author,
  favoriteCount: favorites,
  chapters: const [],
);

class SearchSource implements SearchableNovelSource {
  SearchSource(this.id, this.response);
  @override
  final String id;
  @override
  String get name => id == 'fanqie' ? '番茄小说' : '测试书源';
  final Future<List<Book>> Function(String) response;
  final opened = <String>[];
  @override
  Future<List<Book>> search(String keyword, {int page = 0}) =>
      response(keyword);
  @override
  Future<Book> getBook(String input) async {
    opened.add(input);
    throw const SourceException('已调用正确书源');
  }

  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async =>
      const ChapterContent([]);
}

class SearchSfacg extends SfacgSource {
  SearchSfacg(super.api, this.response);
  final Future<List<Book>> Function(String) response;
  final opened = <String>[];
  @override
  Future<List<Book>> search(String keyword, {int page = 0}) =>
      response(keyword);

  @override
  Future<Book> getBook(String input) async {
    opened.add(input);
    throw const SourceException('已调用菠萝包书源');
  }
}

class PlatformSearchSource extends SearchSource
    implements PlatformRankedSearchSource {
  PlatformSearchSource(super.id, super.response);
  @override
  String get searchNotice => '同一作品可能有多个书名，搜索结果可能显示其他书名。';
}

class SearchMemoryLibrary extends Library {
  SearchMemoryLibrary(super.root, super.source, {super.novelSources});
  bool failSave = false;
  @override
  Future<void> save() async {
    if (failSave) throw const FileSystemException('保存失败');
    notifyListeners();
  }
}

void main() {
  test('搜索平台默认全部开启，兼容旧书库并持久化选择，新平台默认开启', () async {
    final root = await Directory.systemTemp.createTemp('unr-search-settings-');
    addTearDown(() => root.delete(recursive: true));
    final api = SfacgApi();
    addTearDown(api.close);
    final sfacg = SearchSfacg(api, (_) async => []);
    final fanqie = SearchSource('fanqie', (_) async => []);
    Future<Library> open({bool extra = false}) async {
      final library = await Library.open(
        sfacg,
        directory: root,
        novelSources: [fanqie, if (extra) SearchSource('new', (_) async => [])],
      );
      addTearDown(library.dispose);
      return library;
    }

    expect((await open()).enabledSearchSources.map((s) => s.id), [
      'fanqie',
      'sfacg',
    ]);
    await File('${root.path}/index.json').writeAsString(
      jsonEncode({
        'books': [book('1', '故事').toJson()],
        'progress': {
          'sfacg:1': [2, 3],
        },
      }),
    );
    final legacy = await open();
    expect(legacy.enabledSearchSources.map((s) => s.id), ['fanqie', 'sfacg']);
    await legacy.setSearchSourceEnabled('sfacg', false);
    final restored = await open(extra: true);
    expect(restored.enabledSearchSources.map((s) => s.id), ['fanqie', 'new']);
    expect(restored.searchSources.map((s) => s.id), ['fanqie', 'sfacg', 'new']);
    expect(restored.books.single.title, '故事');
    expect(restored.progress['sfacg:1'], [2, 3]);
    await restored.setSearchSourceEnabled('fanqie', false);
    await restored.setSearchSourceEnabled('new', false);
    expect((await open(extra: true)).enabledSearchSources, isEmpty);
    await restored.setSearchSourceEnabled('sfacg', true);
    expect((await open()).enabledSearchSources.map((s) => s.id), ['sfacg']);
  });

  testWidgets('搜索设置显示平台开关，保存失败回滚并显示错误', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = SfacgApi();
    addTearDown(api.close);
    final library = SearchMemoryLibrary(
      Directory.systemTemp,
      SearchSfacg(api, (_) async => []),
      novelSources: [SearchSource('fanqie', (_) async => [])],
    );
    addTearDown(library.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: SoftwareSettingsPage(
          library: library,
          gbk: false,
          onEncodingChanged: (_) {},
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('settings-search-entry')));
    await tester.pumpAndSettle();
    final sfacg = find.byKey(const ValueKey('search-source-sfacg'));
    final fanqie = find.byKey(const ValueKey('search-source-fanqie'));
    expect(
      tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .map((tile) => tile.key),
      [
        const ValueKey('search-source-fanqie'),
        const ValueKey('search-source-sfacg'),
      ],
    );
    expect(tester.widget<SwitchListTile>(sfacg).value, isTrue);
    expect(tester.widget<SwitchListTile>(fanqie).value, isTrue);
    await tester.tap(sfacg);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(sfacg).value, isFalse);
    library.failSave = true;
    await tester.tap(fanqie);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(fanqie).value, isTrue);
    expect(find.textContaining('搜索设置保存失败'), findsOneWidget);
    library.failSave = false;
    await tester.tap(fanqie);
    await tester.pumpAndSettle();
    expect(find.textContaining('未选择搜索平台'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('仅请求选中平台，全部关闭给出提示且仍支持作品链接', (tester) async {
    final calls = <String>[];
    final api = SfacgApi();
    addTearDown(api.close);
    final fanqie = SearchSource('fanqie', (_) async {
      calls.add('fanqie');
      return [book('1', '故事', source: 'fanqie')];
    });
    final library = SearchMemoryLibrary(
      Directory.systemTemp,
      SearchSfacg(api, (_) async {
        calls.add('sfacg');
        throw const SourceException('失败');
      }),
      novelSources: [fanqie],
    );
    addTearDown(library.dispose);
    await library.setSearchSourceEnabled('sfacg', false);
    await tester.pumpWidget(MaterialApp(home: HomePage(library: library)));
    await tester.tap(find.text('书源'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '故事');
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pumpAndSettle();
    expect(calls, ['fanqie']);
    expect(find.byKey(const ValueKey('search-fanqie:1')), findsOneWidget);
    await library.setSearchSourceEnabled('fanqie', false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-fanqie:1')), findsNothing);
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pumpAndSettle();
    expect(calls, ['fanqie']);
    expect(find.textContaining('未选择搜索平台'), findsOneWidget);
    expect(find.text('没有搜索到作品'), findsNothing);
    await tester.enterText(
      find.byType(TextField),
      'https://fanqienovel.com/page/123',
    );
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pumpAndSettle();
    expect(fanqie.opened, ['https://fanqienovel.com/page/123']);
    await library.setSearchSourceEnabled('sfacg', true);
    await tester.enterText(find.byType(TextField), '故事');
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pumpAndSettle();
    expect(calls, ['fanqie', 'sfacg']);
    expect(find.text('搜索未完成，请重试'), findsOneWidget);
    expect(find.textContaining('已显示其他平台的结果'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('数字书名按关键词搜索，菠萝包链接与番茄长 ID 仍直接打开', (tester) async {
    final calls = <String>[];
    final api = SfacgApi();
    addTearDown(api.close);
    final sfacg = SearchSfacg(api, (keyword) async {
      calls.add('sfacg:$keyword');
      return [book('1', keyword)];
    });
    final fanqie = SearchSource('fanqie', (keyword) async {
      calls.add('fanqie:$keyword');
      return [book('2', keyword, source: 'fanqie')];
    });
    final library = SearchMemoryLibrary(
      Directory.systemTemp,
      sfacg,
      novelSources: [fanqie],
    );
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(home: HomePage(library: library)));
    await tester.tap(find.text('书源'));
    await tester.pumpAndSettle();

    for (final keyword in ['0', '1984', '776753', '1234567890']) {
      calls.clear();
      await tester.enterText(find.byType(TextField), ' $keyword ');
      await tester.tap(find.byTooltip('搜索或添加作品'));
      await tester.pumpAndSettle();
      expect(calls, ['fanqie:$keyword', 'sfacg:$keyword']);
      expect(sfacg.opened, isEmpty);
      expect(fanqie.opened, isEmpty);
      expect(find.byKey(const ValueKey('search-sfacg:1')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-fanqie:2')), findsOneWidget);
    }

    calls.clear();
    const link = 'https://book.sfacg.com/Novel/776753/';
    await tester.enterText(find.byType(TextField), link);
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pumpAndSettle();
    expect(sfacg.opened, [link]);
    const fanqieId = '7123456789012345678';
    await tester.enterText(find.byType(TextField), fanqieId);
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pumpAndSettle();
    expect(fanqie.opened, [fanqieId]);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('请求期间更改搜索平台，过期结果不再显示', (tester) async {
    final pending = Completer<List<Book>>();
    final api = SfacgApi();
    addTearDown(api.close);
    final library = SearchMemoryLibrary(
      Directory.systemTemp,
      SearchSfacg(api, (_) => pending.future),
    );
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(home: HomePage(library: library)));
    await tester.tap(find.text('书源'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '故事');
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pump();
    await library.setSearchSourceEnabled('sfacg', false);
    pending.complete([book('1', '故事')]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-sfacg:1')), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('相关性高于收藏，同相关性按平台收藏降序，未知收藏排在零之后', () async {
    final result = await searchNovels([
      SearchSource(
        'sfacg',
        (_) async => [
          book('1', '故事', favorites: 10),
          book('2', '故事新篇', favorites: 1000000),
          book('3', '另一部书', author: '故事', favorites: 2000000),
          book('4', '完全无关', favorites: 9000000),
          book('5', '故事'),
          book('6', '故事', favorites: 0),
        ],
      ),
      SearchSource(
        'fanqie',
        (_) async => [book('1', '故事', source: 'fanqie', favorites: 20)],
      ),
    ], ' 故事 ');
    expect(result.books.map((book) => book.key), [
      'fanqie:1',
      'sfacg:1',
      'sfacg:6',
      'sfacg:5',
      'sfacg:2',
      'sfacg:3',
      'sfacg:4',
    ]);
    expect(result.failedSources, isEmpty);
  });

  test('统一大小写标点与空白，分词匹配优先于模糊匹配', () async {
    final result = await searchNovels([
      SearchSource(
        'sfacg',
        (_) async => [
          book('1', '魔法的冒险', favorites: 10000),
          book('2', '魔法日记', author: '少女', favorites: 100),
          book('3', '《魔法少女》', favorites: 1),
        ],
      ),
    ], ' 魔法 少女 ');
    expect(result.books.map((book) => book.id), ['3', '2', '1']);
    final english = await searchNovels([
      SearchSource(
        'sfacg',
        (_) async => [
          book('1', 'The Story 附录', favorites: 100),
          book('2', 'THE-STORY', favorites: 1),
        ],
      ),
    ], 'the story');
    expect(english.books.map((book) => book.id), ['2', '1']);
  });

  test('同时请求所有平台，完成顺序不改变排序，同源去重且保留跨源作品', () async {
    final first = Completer<List<Book>>(), second = Completer<List<Book>>();
    final queries = <String>[];
    final pending = searchNovels([
      SearchSource('sfacg', (query) {
        queries.add(query);
        return first.future;
      }),
      SearchSource('fanqie', (query) {
        queries.add(query);
        return second.future;
      }),
    ], ' 故事 ');
    expect(queries, ['故事', '故事']);
    second.complete([book('1', '故事', source: 'fanqie', favorites: 10)]);
    first.complete([
      book('1', '故事', favorites: 10),
      book('1', '故事', favorites: 10),
    ]);
    expect((await pending).books.map((book) => book.key), [
      'sfacg:1',
      'fanqie:1',
    ]);
  });

  test('平台排序保留命中顺序和同源去重，跨源结果不丢失且不随响应时序变化', () async {
    final first = Completer<List<Book>>(), second = Completer<List<Book>>();
    final platform = PlatformSearchSource('fanqie', (_) => second.future);
    final pending = searchNovels([
      SearchSource('sfacg', (_) => first.future),
      platform,
    ], '旧书名');
    second.complete([
      book('1', '其他显示书名', source: 'fanqie', favorites: 1),
      book('1', '重复结果', source: 'fanqie', favorites: 9999999),
      book('2', '旧书名', source: 'fanqie', favorites: 100),
    ]);
    first.complete([
      book('1', '旧书名', favorites: 50),
      book('2', '旧书名续篇', favorites: 1000000),
    ]);
    final result = await pending;
    expect(result.books.map((book) => book.key), [
      'fanqie:1',
      'sfacg:1',
      'sfacg:2',
      'fanqie:2',
    ]);
    expect(result.books.first.title, '其他显示书名');
    expect(result.books.first.favoriteCount, 1);
    expect(result.notices, [platform.searchNotice]);
    expect(result.failedSources, isEmpty);
  });

  test('空结果和失败平台不留下搜索提示，也不影响成功平台', () async {
    final result = await searchNovels([
      PlatformSearchSource('empty', (_) async => []),
      PlatformSearchSource(
        'failed',
        (_) async => throw const SourceException('失败'),
      ),
      SearchSource('sfacg', (_) async => [book('1', '故事')]),
    ], '故事');
    expect(result.books.single.key, 'sfacg:1');
    expect(result.failedSources, ['测试书源']);
    expect(result.notices, isEmpty);
  });

  test('失败平台单独报告，成功平台和空结果不受影响，空关键词不请求', () async {
    var requests = 0;
    final sources = [
      SearchSource('sfacg', (_) async {
        requests++;
        throw const SourceException('失效');
      }),
      SearchSource('fanqie', (_) async {
        requests++;
        return [book('1', '故事', source: 'fanqie')];
      }),
    ];
    final result = await searchNovels(sources, '故事');
    expect(result.books.single.source, 'fanqie');
    expect(result.failedSources, ['测试书源']);
    expect((await searchNovels(sources, ' ')).books, isEmpty);
    expect(requests, 2);
    expect((await searchNovels([], '故事')).books, isEmpty);
  });

  test('收藏计数兼容旧缓存，未知值不伪装成零', () {
    final saved = book('1', '故事', favorites: 100).toJson();
    expect(Book.fromJson(saved).favoriteCount, 100);
    saved.remove('favoriteCount');
    expect(Book.fromJson(saved).favoriteCount, isNull);
    for (final value in [null, '', '未知', '-1', 1.5]) {
      expect(Book.parseFavoriteCount(value), isNull);
    }
    expect(Book.parseFavoriteCount('0'), 0);
  });

  testWidgets('搜索直接合并所有平台，显示收藏与来源，点击按作品来源打开', (tester) async {
    final root = Directory.systemTemp.createTempSync('unr-search-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final api = SfacgApi();
    addTearDown(api.close);
    final source = SearchSource(
      'fanqie',
      (_) async => [book('1', '故事', source: 'fanqie', favorites: 200)],
    );
    final library = Library(
      root,
      SearchSfacg(api, (_) async => [book('1', '故事', favorites: 100)]),
      novelSources: [source],
    );
    await tester.pumpWidget(MaterialApp(home: HomePage(library: library)));
    await tester.tap(find.text('书源'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.enterText(find.byType(TextField), '故事');
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pumpAndSettle();
    final rows = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .where((row) => row.key.toString().contains('search-'))
        .toList();
    expect(rows.map((row) => row.key), [
      const ValueKey('search-fanqie:1'),
      const ValueKey('search-sfacg:1'),
    ]);
    expect(find.textContaining('200 人收藏'), findsOneWidget);
    expect(find.textContaining('番茄小说'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-fanqie:1')));
    await tester.pumpAndSettle();
    expect(source.opened, ['1']);
    expect(find.text('已调用正确书源'), findsOneWidget);
  });

  for (final width in [320.0, 1200.0]) {
    testWidgets('多书名提示兼容宽度 $width 和大字号，重搜及切换平台清理提示', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('unr-search-notice-');
      addTearDown(() => root.deleteSync(recursive: true));
      final api = SfacgApi();
      addTearDown(api.close);
      var response = 0;
      final source = PlatformSearchSource('fanqie', (_) async {
        if (response == 1) return [];
        if (response == 2) throw const SourceException('失败');
        return [book('1', '明日方舟：我才是博士最重要的人', source: 'fanqie')];
      });
      final library = SearchMemoryLibrary(
        root,
        SearchSfacg(api, (_) async => []),
        novelSources: [source],
      );
      addTearDown(library.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: HomePage(library: library),
        ),
      );
      await tester.tap(find.text('书源'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '方舟：这里万籁俱寂，别丢下我');
      Future<void> search() async {
        await tester.tap(find.byTooltip('搜索或添加作品'));
        await tester.pumpAndSettle();
      }

      await search();
      expect(find.text(source.searchNotice), findsOneWidget);
      expect(find.text('明日方舟：我才是博士最重要的人'), findsOneWidget);
      expect(tester.takeException(), isNull);

      response = 1;
      await tester.enterText(find.byType(TextField), '另一个搜索词');
      await search();
      expect(find.text(source.searchNotice), findsNothing);
      expect(find.text('没有搜索到作品'), findsOneWidget);

      response = 2;
      await search();
      expect(find.text(source.searchNotice), findsNothing);
      expect(find.textContaining('搜索失败，请重试'), findsOneWidget);

      response = 0;
      await search();
      expect(find.text(source.searchNotice), findsOneWidget);
      await library.setSearchSourceEnabled('fanqie', false);
      await tester.pumpAndSettle();
      expect(find.text(source.searchNotice), findsNothing);
      expect(find.byKey(const ValueKey('search-fanqie:1')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('平台失败保留其他结果，全部失败显示重试而非无结果', (tester) async {
    final root = Directory.systemTemp.createTempSync('unr-search-errors-');
    addTearDown(() => root.deleteSync(recursive: true));
    final api = SfacgApi();
    addTearDown(api.close);
    var failAll = false;
    final library = Library(
      root,
      SearchSfacg(api, (_) async => throw const SourceException('失败')),
      novelSources: [
        SearchSource('fanqie', (_) async {
          if (failAll) throw const SourceException('失败');
          return [book('1', '故事', source: 'fanqie')];
        }),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: HomePage(library: library)));
    await tester.tap(find.text('书源'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '故事');
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已显示其他平台的结果'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-fanqie:1')), findsOneWidget);
    expect(find.textContaining('收藏数未知'), findsOneWidget);
    failAll = true;
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pumpAndSettle();
    expect(find.text('搜索未完成，请重试'), findsOneWidget);
    expect(find.text('没有搜索到作品'), findsNothing);
    expect(find.byKey(const ValueKey('search-fanqie:1')), findsNothing);
  });
}
