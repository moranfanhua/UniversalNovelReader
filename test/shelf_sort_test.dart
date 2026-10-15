import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/reading_taps.dart';

Book sample(
  String id,
  String title, {
  DateTime? updatedAt,
  String source = 'sfacg',
}) => Book(
  id: id,
  title: title,
  author: '测试作者',
  source: source,
  updatedAt: updatedAt,
  chapters: const [Chapter(id: '1', title: '第一章')],
);

class ShelfMemoryLibrary extends Library {
  ShelfMemoryLibrary(DateTime Function() clock)
    : super(Directory.systemTemp, SfacgSource(SfacgApi()), clock: clock);
  @override
  Future<void> save() async {
    notifyListeners();
  }

  @override
  Future<Map<String, ChapterContent>> cachedContents(Book book) async => {};
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      const ChapterContent([Paragraph('测试正文')]);
}

void main() {
  test('中文书名以完整无声调拼音参与字典序，混合英文忽略大小写且同音稳定', () async {
    final library = ShelfMemoryLibrary(DateTime.now);
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    library.books.addAll([
      sample('z', 'Zulu'),
      sample('guo', '国王'),
      sample('gui', '诡秘'),
      sample('guima', 'GuiMa'),
      sample('latin-gui', 'guIMI'),
      sample('a', '  ALPHA '),
    ]);
    await library.setShelfSort(ShelfSort.name);
    expect(library.sortedBooks.map((book) => book.id), [
      'a',
      'guima',
      'gui',
      'latin-gui',
      'guo',
      'z',
    ]);
    // A refreshed title must use a new key, without changing the stored title.
    await library.add(sample('gui', '阿尔法'));
    expect(library.sortedBooks.map((book) => book.id), [
      'gui',
      'a',
      'guima',
      'latin-gui',
      'guo',
      'z',
    ]);
    expect(library.books.firstWhere((book) => book.id == 'gui').title, '阿尔法');
  });
  test('多音字按词组转换，中文英文混排保留数字标点和特殊字符', () async {
    final library = ShelfMemoryLibrary(DateTime.now);
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    library.books.addAll([
      sample('chongqing', '重庆'),
      sample('chengdu', '成都'),
      sample('chp', 'CHP'),
      sample('second', '诡秘2'),
      sample('tenth', '诡秘10'),
      sample('punctuation', '诡秘!'),
      sample('unknown', '诡秘\uE000'),
      sample('emoji', '诡秘📚'),
    ]);
    await library.setShelfSort(ShelfSort.name);
    expect(library.sortedBooks.map((book) => book.id), [
      'chengdu',
      'chongqing',
      'chp',
      'punctuation',
      'tenth',
      'second',
      'emoji',
      'unknown',
    ]);
  });
  test('缺失的更新时间不冒充当前时间，同名作品保持稳定顺序', () async {
    final library = ShelfMemoryLibrary(() => DateTime.utc(2026, 10, 13));
    final known = sample('known', '同名', updatedAt: DateTime.utc(2026, 10, 12));
    final unknown = sample('unknown', '同名');
    await library.add(known);
    await library.add(unknown);
    await library.setShelfSort(ShelfSort.updated);
    expect(library.sortedBooks.map((book) => book.id), ['known', 'unknown']);
    expect(library.books.map((book) => book.id), ['unknown', 'known']);
    await library.setShelfSort(ShelfSort.name);
    expect(library.sortedBooks.map((book) => book.id), ['unknown', 'known']);
    library.dispose();
    library.source.api.close();
  });
  test('三种排序有不同顺序，打开和阅读更新活跃时间而不改变更新时间', () async {
    final root = await Directory.systemTemp.createTemp('unr-shelf-sort-');
    final api = SfacgApi();
    var time = DateTime.utc(2026, 10, 13, 12);
    final library = Library(root, SfacgSource(api), clock: () => time);
    final a = sample('a', 'alpha', updatedAt: DateTime.utc(2026, 10, 11));
    final b = sample('b', 'Beta', updatedAt: DateTime.utc(2026, 10, 13));
    final c = sample('c', 'Gamma', updatedAt: DateTime.utc(2026, 10, 12));
    try {
      await library.add(b);
      time = time.add(const Duration(minutes: 1));
      await library.add(a);
      time = time.add(const Duration(minutes: 1));
      await library.add(c);
      expect(library.sortedBooks.map((book) => book.id), ['c', 'a', 'b']);
      await library.setShelfSort(ShelfSort.name);
      expect(library.sortedBooks.map((book) => book.id), ['a', 'b', 'c']);
      await library.setShelfSort(ShelfSort.updated);
      expect(library.sortedBooks.map((book) => book.id), ['b', 'c', 'a']);
      await library.setShelfSort(ShelfSort.lastActive);
      time = time.add(const Duration(minutes: 1));
      await library.markActive(b);
      expect(library.sortedBooks.map((book) => book.id), ['b', 'c', 'a']);
      time = time.add(const Duration(minutes: 1));
      await library.remember(a, 0, 4);
      expect(library.sortedBooks.map((book) => book.id), ['a', 'b', 'c']);
      await library.setShelfSort(ShelfSort.updated);
      final oldActive = library.lastActiveTimes[b.key];
      await library.add(sample('b', 'Beta refreshed'));
      expect(library.lastActiveTimes[b.key], oldActive);
      expect(library.sortedBooks.map((book) => book.id), ['b', 'c', 'a']);
      final reopened = await Library.open(library.source, directory: root);
      expect(reopened.shelfSort, ShelfSort.updated);
      expect(reopened.sortedBooks.map((book) => book.id), ['b', 'c', 'a']);
      expect(reopened.lastActiveTimes[a.key], time.millisecondsSinceEpoch);
      expect(reopened.progress[a.key], [0, 4]);
      reopened.dispose();
    } finally {
      library.dispose();
      api.close();
      await root.delete(recursive: true);
    }
  });
  test('本地小说按导入时间更新；旧书库缺少时间时保留原始顺序', () async {
    final root = await Directory.systemTemp.createTemp('unr-shelf-legacy-');
    final api = SfacgApi();
    var time = DateTime.utc(2026, 10, 13, 12);
    final library = Library(root, SfacgSource(api), clock: () => time);
    final a = sample('a', 'A', source: 'local'),
        b = sample('b', 'B', source: 'local');
    try {
      await library.add(a);
      time = time.add(const Duration(minutes: 1));
      await library.add(b);
      await library.setShelfSort(ShelfSort.updated);
      expect(library.sortedBooks.map((book) => book.id), ['b', 'a']);
      time = time.add(const Duration(minutes: 1));
      await library.add(a);
      expect(library.sortedBooks.map((book) => book.id), ['a', 'b']);
      final legacy = [
        b.toJson()..remove('updatedAt'),
        a.toJson()..remove('updatedAt'),
      ];
      await File(
        '${root.path}/index.json',
      ).writeAsString(jsonEncode({'books': legacy}));
      final reopened = await Library.open(library.source, directory: root);
      expect(reopened.shelfSort, ShelfSort.lastActive);
      expect(reopened.sortedBooks.map((book) => book.id), ['b', 'a']);
      reopened.shelfSort = ShelfSort.updated;
      expect(reopened.sortedBooks.map((book) => book.id), ['b', 'a']);
      reopened.dispose();
    } finally {
      library.dispose();
      api.close();
      await root.delete(recursive: true);
    }
  });
  test('菠萝包目录更新时间按北京时间解析，保存后不丢失', () async {
    final api = SfacgApi(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'status': {'httpCode': 200},
            'data': request.url.path.endsWith('/dirs')
                ? {
                    'lastUpdateTime': '2026-10-13T18:00:00',
                    'volumeList': [
                      {
                        'volumeId': 1,
                        'chapterList': [
                          {'chapId': 2, 'title': '一'},
                        ],
                      },
                    ],
                  }
                : {
                    'novelName': '测试',
                    'authorName': '作者',
                    'lastUpdateTime': '2026-10-12T18:00:00',
                  },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    final book = await SfacgSource(api).getBook('1');
    expect(book.updatedAt, DateTime.utc(2026, 10, 13, 10));
    expect(Book.fromJson(book.toJson()).updatedAt, book.updatedAt);
    api.close();
  });
  testWidgets('设置页切换三种排序会改变书架顺序，打开作品记录活跃时间', (tester) async {
    var time = DateTime.utc(2026, 10, 13, 12);
    final library = ShelfMemoryLibrary(() => time);
    library.books.addAll([
      sample('c', 'C', updatedAt: DateTime.utc(2026, 10, 12)),
      sample('b', 'B', updatedAt: DateTime.utc(2026, 10, 13)),
      sample('a', 'A', updatedAt: DateTime.utc(2026, 10, 11)),
    ]);
    await tester.pumpWidget(UnrApp(library: library));
    List<String> titles() => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(GridView),
            matching: find.byWidgetPredicate(
              (widget) => widget is Text && widget.maxLines == 2,
            ),
          ),
        )
        .map((text) => text.data!)
        .toList();
    Future<void> choose(String label) async {
      await tester.tap(find.text('我的').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('软件设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-shelf-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shelf-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('书库'));
      await tester.pumpAndSettle();
    }

    expect(titles(), ['C', 'B', 'A']);
    await choose('按名称');
    expect(titles(), ['A', 'B', 'C']);
    await choose('按更新时间');
    expect(titles(), ['B', 'C', 'A']);
    time = time.add(const Duration(minutes: 1));
    await tester.tap(find.text('A').last);
    await tester.pumpAndSettle();
    expect(library.lastActiveTimes['sfacg:a'], time.millisecondsSinceEpoch);
    expect(find.byType(ReaderPage), findsOneWidget);
    await showReadingControls(tester);
    await tester.tap(find.byType(BackButton).hitTestable());
    await tester.pumpAndSettle();
    await choose('按上次活跃时间');
    expect(titles(), ['A', 'C', 'B']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
    library.source.api.close();
  });
}
