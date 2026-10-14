import 'dart:async';
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
  @override
  Future<List<Book>> search(String keyword, {int page = 0}) =>
      response(keyword);
}

void main() {
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
