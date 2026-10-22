import 'dart:async';
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
import 'package:unr/ui/home.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/reading_taps.dart';

const book = Book(
  id: 'resume',
  source: 'local',
  title: '恢复阅读测试',
  author: '作者',
  chapters: [
    Chapter(id: '1', title: '第一章'),
    Chapter(id: '2', title: '第二章'),
    Chapter(id: '3', title: '第三章'),
  ],
);

class ShelfNavigationLibrary extends Library {
  ShelfNavigationLibrary({SfacgSource? source})
    : super(Directory.systemTemp, source ?? SfacgSource(SfacgApi()));
  final reads = <String>[];
  // These tests isolate opening cached books and loading missing directories.
  // Automatic visit updates are covered by shelf_updates_test.dart.
  @override
  Future<ShelfUpdateResult> refreshShelfBooks({
    String? shelfId,
    required bool Function() isCancelled,
  }) async => const ShelfUpdateResult();
  @override
  Future<void> save() async => notifyListeners();
  @override
  Future<Set<String>> cachedChapterIds(Book book) async =>
      (await cachedContents(book)).keys.toSet();
  @override
  Future<Map<String, ChapterContent>> cachedContents(Book book) async => {};
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async {
    reads.add(chapter.id);
    return ChapterContent([
      for (var i = 0; i < 40; i++)
        Paragraph('章节${chapter.id}段$i ${'用于恢复阅读的正文。' * 70}'),
    ]);
  }
}

const preview = Book(id: '1', title: '待加载作品', author: '作者', chapters: []);
const loadedBook = Book(
  id: '1',
  title: '待加载作品',
  author: '作者',
  chapters: [
    Chapter(id: '1', title: '第一章'),
    Chapter(id: '2', title: '第二章'),
  ],
);

class DirectorySource extends SfacgSource {
  DirectorySource() : super(SfacgApi());
  int calls = 0;
  bool fail = false;
  Completer<Book>? pending;
  @override
  Future<Book> getBook(String input) async {
    calls++;
    if (fail) throw const SourceException('目录获取失败，请重试');
    return pending == null ? loadedBook : pending!.future;
  }
}

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  late ShelfNavigationLibrary library;
  setUp(() => library = ShelfNavigationLibrary());
  tearDown(() {
    library.dispose();
    library.source.api.close();
  });
  void viewport(WidgetTester tester) {
    tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
        ? const Size(1400, 900)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final layout in ShelfLayout.values) {
    for (final mode in ReadingMode.values) {
      testWidgets('书架直接阅读继承章节、段落与页内位置（${layout.name}，${mode.name}）', (
        tester,
      ) async {
        viewport(tester);
        library
          ..shelfLayout = layout
          ..readingMode = mode
          ..books.add(book);
        library.progress[book.key] = [1, 8];
        library.pageOffsets[book.key] = mode == ReadingMode.paged ? 72 : 0;
        library.pagedChapterEntries['${book.key}:1'] = [1, 0, 0];
        await tester.pumpWidget(UnrApp(library: library));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('shelf-book-${book.key}')));
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsOneWidget);
        expect(find.byType(BookPage), findsNothing);
        expect(readingChapter(tester), 1);
        expect(library.reads.first, '2');
        expect(
          tester.widget<ReaderPage>(find.byType(ReaderPage)).initialChapter,
          isNull,
        );
        if (mode == ReadingMode.paged) {
          final pager = readingPager(tester);
          expect(pager.anchorParagraph, 8);
          expect(pager.anchorOffset, 72);
          expect(
            pager.columns,
            defaultTargetPlatform == TargetPlatform.windows ? 2 : 1,
          );
        } else {
          final restored = tester.getRect(find.textContaining('章节2段8 '));
          final viewport = tester.getRect(find.byType(SingleChildScrollView));
          expect(restored.top, closeTo(viewport.top, .1));
          expect(restored.overlaps(viewport), isTrue);
        }
        await showReadingControls(tester);
        await tester.tap(find.byType(BackButton).hitTestable());
        await tester.pumpAndSettle();
        expect(find.byType(HomePage), findsOneWidget);
        expect(library.progress[book.key], [1, 8]);
        expect(
          library.pageOffsets[book.key],
          mode == ReadingMode.paged ? 72 : 0,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: platforms);
    }

    testWidgets('长按书架作品显示底栏并可进入详情（${layout.name}）', (tester) async {
      viewport(tester);
      library
        ..shelfLayout = layout
        ..books.add(book);
      await tester.pumpWidget(UnrApp(library: library));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(ValueKey('shelf-book-${book.key}')));
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('移除'), findsOneWidget);
      expect(find.byType(BookPage), findsNothing);
      await tester.tap(find.text('作品详情'));
      await tester.pumpAndSettle();
      expect(find.byType(BookPage), findsOneWidget);
      expect(find.byType(ReaderPage), findsNothing);
      expect(library.progress, isEmpty);
      expect(library.recentBooks, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: platforms);
  }

  for (final mode in ReadingMode.values) {
    testWidgets('没有本平台阅读记录时从第一章开始（${mode.name}）', (tester) async {
      viewport(tester);
      library
        ..readingMode = mode
        ..books.add(book);
      library.progress['sfacg:${book.id}'] = [2, 20];
      await tester.pumpWidget(UnrApp(library: library));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shelf-book-${book.key}')));
      await tester.pumpAndSettle();
      expect(readingChapter(tester), 0);
      expect(library.reads.first, '1');
      if (mode == ReadingMode.paged) {
        expect(readingPager(tester).anchorParagraph, 0);
        expect(readingPager(tester).anchorOffset, 0);
      } else {
        final first = tester.getRect(find.textContaining('章节1段0 '));
        expect(
          first.overlaps(tester.getRect(find.byType(SingleChildScrollView))),
          isTrue,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: platforms);
  }

  testWidgets('没有章节的作品提示不可阅读，长按仍能打开详情', (tester) async {
    viewport(tester);
    const empty = Book(
      id: 'empty',
      source: 'local',
      title: '无章节作品',
      author: '',
      chapters: [],
    );
    library.books.add(empty);
    await tester.pumpWidget(UnrApp(library: library));
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('shelf-book-${empty.key}'));
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsNothing);
    expect(find.textContaining('暂无可阅读章节'), findsOneWidget);
    await tester.longPress(card);
    await tester.pumpAndSettle();
    await tester.tap(find.text('作品详情'));
    await tester.pumpAndSettle();
    expect(find.byType(BookPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  for (final mode in ReadingMode.values) {
    testWidgets('导入的预览首次打开加载目录并保留续读位置，再次打开复用目录（${mode.name}）', (tester) async {
      viewport(tester);
      final source = DirectorySource();
      final value = ShelfNavigationLibrary(source: source)
        ..books.add(preview)
        ..readingMode = mode;
      value.progress[preview.key] = [1, 8];
      value.pageOffsets[preview.key] = mode == ReadingMode.paged ? 72 : 0;
      addTearDown(value.dispose);
      addTearDown(source.api.close);
      await tester.pumpWidget(UnrApp(library: value));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shelf-book-${preview.key}')));
      await tester.pumpAndSettle();
      expect(source.calls, 1);
      expect(value.books.single, same(loadedBook));
      expect(readingChapter(tester), 1);
      expect(value.reads.first, '2');
      expect(value.progress[preview.key], [1, 8]);
      if (mode == ReadingMode.paged) {
        expect(readingPager(tester).anchorOffset, 72);
      }
      await showReadingControls(tester);
      await tester.tap(find.byType(BackButton).hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shelf-book-${preview.key}')));
      await tester.pumpAndSettle();
      expect(source.calls, 1);
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: platforms);
  }

  testWidgets('预览目录失败可重试，长按详情也会先补齐目录', (tester) async {
    viewport(tester);
    final source = DirectorySource()..fail = true;
    final value = ShelfNavigationLibrary(source: source)..books.add(preview);
    addTearDown(value.dispose);
    addTearDown(source.api.close);
    await tester.pumpWidget(UnrApp(library: value));
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('shelf-book-${preview.key}'));
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.textContaining('目录获取失败'), findsOneWidget);
    expect(find.byType(ReaderPage), findsNothing);
    expect(value.books.single, same(preview));
    expect(value.progress, isEmpty);
    source.fail = false;
    await tester.longPress(card);
    await tester.pumpAndSettle();
    await tester.tap(find.text('作品详情'));
    await tester.pumpAndSettle();
    expect(source.calls, 2);
    expect(find.byType(BookPage), findsOneWidget);
    expect(
      tester.widget<BookPage>(find.byType(BookPage)).book,
      same(loadedBook),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('加载预览目录期间防重复点击，页面销毁后忽略结果', (tester) async {
    viewport(tester);
    final source = DirectorySource()..pending = Completer<Book>();
    final value = ShelfNavigationLibrary(source: source)..books.add(preview);
    addTearDown(value.dispose);
    addTearDown(source.api.close);
    await tester.pumpWidget(UnrApp(library: value));
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('shelf-book-${preview.key}'));
    await tester.tap(card);
    await tester.pump();
    await tester.tap(card);
    await tester.pump();
    expect(source.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    source.pending!.complete(loadedBook);
    await tester.pumpAndSettle();
    expect(value.books.single, same(preview));
    expect(value.lastActiveTimes, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('切换页面后忽略迟到的目录，不自动进入阅读器', (tester) async {
    viewport(tester);
    final source = DirectorySource()..pending = Completer<Book>();
    final value = ShelfNavigationLibrary(source: source)..books.add(preview);
    addTearDown(value.dispose);
    addTearDown(source.api.close);
    await tester.pumpWidget(UnrApp(library: value));
    await tester.pumpAndSettle();
    expect(find.textContaining('目录待加载'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('shelf-book-${preview.key}')));
    await tester.pump();
    await tester.tap(find.text('书源'));
    await tester.pump();
    source.pending!.complete(loadedBook);
    await tester.pumpAndSettle();
    expect(value.books.single, same(preview));
    expect(value.lastActiveTimes, isEmpty);
    expect(find.byType(ReaderPage), findsNothing);
    expect(find.text('搜索书名或作者'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);
}
