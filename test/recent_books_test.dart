import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/book_page.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/reading_taps.dart';

Book sample(String id, {String source = 'sfacg', String? title}) => Book(
  id: id,
  title: title ?? '作品$id',
  author: '作者',
  source: source,
  chapters: const [Chapter(id: 'chapter', title: '第一章')],
);

class RecentSource extends SfacgSource {
  RecentSource() : super(SfacgApi());
  Book opened = sample('1');
  @override
  Future<Book> getBook(String input) async => opened;
  @override
  Future<List<Book>> search(String keyword, {int page = 0}) async => [opened];
}

class RecentLibrary extends Library {
  RecentLibrary(RecentSource source) : super(Directory.systemTemp, source);
  bool failSave = false;
  int saves = 0;
  Completer<void>? saving;
  Completer<ChapterContent>? pendingRead;
  @override
  Future<void> saveShelfUpdateTimes() => save();
  @override
  Future<void> save() async {
    saves++;
    if (failSave) throw const FileSystemException('保存失败');
    notifyListeners();
    await saving?.future;
  }

  @override
  Future<Set<String>> cachedChapterIds(Book book) async =>
      (await cachedContents(book)).keys.toSet();
  @override
  Future<Map<String, ChapterContent>> cachedContents(Book book) async => {};
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      pendingRead == null
      ? const ChapterContent([Paragraph('阅读正文')])
      : pendingRead!.future;
}

void main() {
  late RecentSource source;
  setUp(() => source = RecentSource());
  tearDown(() => source.api.close());

  test('阅读记录去重、跨平台隔离、限制五十本，淘汰不改变书架缓存或进度', () async {
    final root = await Directory.systemTemp.createTemp('unr-recent-');
    addTearDown(() => root.delete(recursive: true));
    final library = Library(root, source);
    addTearDown(library.dispose);
    final first = sample('0');
    await library.add(first);
    await library.store(
      first,
      first.chapters.single,
      const ChapterContent([Paragraph('缓存正文')]),
    );
    await library.remember(first, 0, 3);
    for (var i = 0; i < 51; i++) {
      await library.recordReading(sample('$i'));
    }
    expect(library.books.map((b) => b.key), [first.key]);
    expect(library.recentBooks.length, 50);
    expect(library.recentBooks.first.key, 'sfacg:50');
    expect(library.recentBooks.last.key, 'sfacg:1');
    expect(library.progress[first.key], [0, 3]);
    expect(
      (await library.cached(
        first,
        first.chapters.single,
      ))!.paragraphs.single.text,
      '缓存正文',
    );
    await library.recordReading(sample('1', title: '刷新后的作品'));
    expect(library.recentBooks.first.title, '刷新后的作品');
    expect(library.recentBooks.length, 50);
    await library.recordReading(sample('1', source: 'fanqie'));
    expect(library.recentBooks.take(2).map((b) => b.key), [
      'fanqie:1',
      'sfacg:1',
    ]);
    final restored = await Library.open(source, directory: root);
    addTearDown(restored.dispose);
    expect(
      restored.recentBooks.map((b) => b.key),
      library.recentBooks.map((b) => b.key),
    );
    expect(restored.books.single.key, first.key);
    expect(restored.progress[first.key], [0, 3]);
  });

  test('旧书架成员保持不变，已读作品迁入最近阅读但未读作品不伪造记录', () async {
    final root = await Directory.systemTemp.createTemp('unr-recent-legacy-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/index.json').writeAsString(
      jsonEncode({
        'books': [for (var i = 0; i < 3; i++) sample('$i').toJson()],
        'progress': {
          'sfacg:0': [0, 0],
          'sfacg:1': [0, 3],
        },
        'lastActiveTimes': {'sfacg:0': 1, 'sfacg:1': 2, 'sfacg:2': 3},
      }),
    );
    final restored = await Library.open(source, directory: root);
    addTearDown(restored.dispose);
    expect(restored.books.length, 3);
    expect(restored.recentBooks.map((b) => b.key), ['sfacg:1', 'sfacg:0']);
  });

  test('刷新未加入书架的作品只更新最近记录，保存失败回滚加入与最近记录', () async {
    final library = RecentLibrary(source);
    addTearDown(library.dispose);
    final first = sample('1');
    await library.markActive(first);
    expect(library.recentBooks, isEmpty);
    await library.recordReading(first);
    final refreshed = sample('1', title: '新目录');
    await library.updateBook(refreshed);
    expect(library.books, isEmpty);
    expect(library.recentBooks.single.title, '新目录');
    library.failSave = true;
    await expectLater(
      library.add(refreshed),
      throwsA(isA<FileSystemException>()),
    );
    expect(library.books, isEmpty);
    await expectLater(
      library.recordReading(sample('2')),
      throwsA(isA<FileSystemException>()),
    );
    expect(library.recentBooks.single.key, first.key);
    expect(library.lastActiveTimes.containsKey('sfacg:2'), isFalse);
    await expectLater(
      library.updateBook(first),
      throwsA(isA<FileSystemException>()),
    );
    expect(library.recentBooks.single.title, '新目录');
    library.failSave = false;
    await library.add(refreshed);
    await library.add(refreshed);
    expect(library.books.length, 1);
    expect(library.recentBooks.length, 1);
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

  const sfacgLink = 'https://book.sfacg.com/Novel/1/';
  for (final (input, onShelf) in [(sfacgLink, true), ('作品', false)]) {
    for (final mode in ReadingMode.values) {
      testWidgets('重新打开已有作品同步目录并恢复新增章节（$input，${mode.name}）', (tester) async {
        viewport(tester);
        final previous = sample('1');
        source.opened = const Book(
          id: '1',
          title: '作品1',
          author: '作者',
          chapters: [
            Chapter(id: 'chapter', title: '第一章'),
            Chapter(id: 'new-chapter', title: '新增第二章'),
          ],
        );
        final library = RecentLibrary(source)..readingMode = mode;
        addTearDown(library.dispose);
        if (onShelf) library.books.add(previous);
        library.recentBooks.addAll([sample('2'), previous]);
        await tester.pumpWidget(UnrApp(library: library));
        await tester.pumpAndSettle();
        await tester.tap(find.text('书源'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), input);
        await tester.tap(find.byTooltip('搜索或添加作品'));
        await tester.pumpAndSettle();
        if (input != sfacgLink) {
          await tester.tap(find.byKey(ValueKey('search-${previous.key}')));
          await tester.pumpAndSettle();
        }
        expect(find.byType(BookPage), findsOneWidget);
        expect(library.isOnShelf(previous), onShelf);
        if (onShelf) expect(library.books.single.chapters.length, 2);
        expect(library.recentBooks.map((book) => book.key), [
          'sfacg:2',
          previous.key,
        ]);
        expect(library.recentBooks.last.chapters.length, 2);
        expect(library.progress, isEmpty);
        await tester.tap(find.text('开始阅读'));
        await tester.pumpAndSettle();
        await showReadingControls(tester);
        await tester.tap(find.text('下一章'));
        await tester.pumpAndSettle();
        expect(readingChapter(tester), 1);
        await showReadingControls(tester);
        await tester.tap(find.byType(BackButton).hitTestable());
        await tester.pumpAndSettle();
        expect(library.progress[previous.key]?.first, 1);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.text('书库'));
        await tester.pumpAndSettle();
        if (!onShelf) {
          await tester.tap(find.byKey(const ValueKey('bookshelf-selector')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('最近阅读').last);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(ValueKey('shelf-book-${previous.key}')));
        await tester.pumpAndSettle();
        expect(readingChapter(tester), 1);
        expect(library.isOnShelf(previous), onShelf);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: platforms);
    }
  }

  for (final mode in ReadingMode.values) {
    testWidgets('正文成功显示后才加入最近阅读，加载中和失败不记录（${mode.name}）', (tester) async {
      viewport(tester);
      final library = RecentLibrary(source)..readingMode = mode;
      addTearDown(library.dispose);
      await library.recordReading(sample('2'));
      final pending = Completer<ChapterContent>();
      library.pendingRead = pending;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(library: library, book: sample('1')),
        ),
      );
      await tester.pump();
      expect(library.recentBooks.single.key, 'sfacg:2');
      pending.completeError(const SourceException('正文暂不可用'));
      await tester.pumpAndSettle();
      expect(library.recentBooks.single.key, 'sfacg:2');
      expect(find.text('正文暂不可用'), findsOneWidget);
      library.pendingRead = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(library.recentBooks.map((b) => b.key), ['sfacg:1', 'sfacg:2']);
      expect(library.books, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('详情和刷新不计入最近阅读，实际阅读后可从最近阅读重开并主动入架', (tester) async {
    viewport(tester);
    final library = RecentLibrary(source);
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await tester.tap(find.text('书源'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '作品');
    await tester.tap(find.byTooltip('搜索或添加作品'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-sfacg:1')));
    await tester.pumpAndSettle();
    expect(find.byType(BookPage), findsOneWidget);
    expect(library.books, isEmpty);
    expect(library.recentBooks, isEmpty);
    await tester.tap(find.byTooltip('刷新目录'));
    await tester.pumpAndSettle();
    expect(library.books, isEmpty);
    expect(library.recentBooks, isEmpty);
    await tester.tap(find.text('开始阅读'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(library.recentBooks.single.key, 'sfacg:1');
    expect(library.books, isEmpty);
    await showReadingControls(tester);
    expect(find.byTooltip('加入书架'), findsOneWidget);
    await tester.tap(find.byType(BackButton).hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('继续阅读'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书库'));
    await tester.pumpAndSettle();
    expect(find.text('把故事放进你的书库'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bookshelf-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近阅读').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shelf-book-sfacg:1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shelf-book-sfacg:1')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.byType(BookPage), findsNothing);
    await showReadingControls(tester);
    await tester.tap(find.byTooltip('加入书架'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('已加入书架'), findsOneWidget);
    expect(library.books.single.key, 'sfacg:1');
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('阅读顶栏可加入书架并同步详情状态，保存失败可重试且防重复点击', (tester) async {
    viewport(tester);
    final library = RecentLibrary(source);
    addTearDown(library.dispose);
    final book = sample('1', title: '很长的书名用于检查阅读顶栏加入书架按钮不会溢出');
    await tester.pumpWidget(
      MaterialApp(
        home: BookPage(library: library, book: book),
      ),
    );
    await tester.pumpAndSettle();
    library.failSave = true;
    await tester.tap(find.text('加入书架'));
    await tester.pumpAndSettle();
    expect(find.textContaining('加入书架失败'), findsOneWidget);
    expect(library.books, isEmpty);
    library.failSave = false;
    await tester.tap(find.text('开始阅读'));
    await tester.pumpAndSettle();
    await showReadingControls(tester);
    final before = library.saves;
    library.saving = Completer<void>();
    await tester.tap(find.byTooltip('加入书架'));
    await tester.pump();
    expect(find.byTooltip('正在加入书架'), findsOneWidget);
    await tester.tap(find.byTooltip('正在加入书架'));
    await tester.pump();
    expect(library.saves, before + 1);
    library.saving!.complete();
    library.saving = null;
    await tester.pumpAndSettle();
    expect(find.byTooltip('已加入书架'), findsOneWidget);
    expect(library.books.length, 1);
    await tester.tap(find.byType(BackButton).hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('已加入书架'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);
}
