import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/chapter_download_dialog.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/reading_taps.dart';
import 'helpers/memory_library.dart';
import 'helpers/viewport.dart';

const chapters = [
  Chapter(id: '1', title: '第一章'),
  Chapter(id: '2', title: '第二章'),
  Chapter(id: '3', title: '第三章'),
];
Book sample({String source = 'sfacg', bool preview = false}) => Book(
  id: 'entry',
  source: source,
  title: '很长的下载入口测试书名用于验证手机宽屏及文字放大时的布局',
  author: '作者',
  wordCount: 30000,
  chapters: preview ? [] : chapters,
);

class EntrySource extends SfacgSource {
  EntrySource()
    : super(
        SfacgApi(client: MockClient((_) async => throw StateError('不应联网'))),
      );
  int calls = 0;
  bool fail = false;
  Completer<Book>? pending;
  @override
  Future<Book> getBook(String input) async {
    calls++;
    if (fail) throw const SourceException('目录加载失败');
    return pending == null ? sample() : pending!.future;
  }
}

class EntryLibrary extends TestLibrary with MemoryPersistence {
  EntryLibrary(EntrySource source) : super(source: source) {
    showParagraphComments = false;
  }
  final downloads = <({Book book, List<Chapter> chapters})>[];
  @override
  Future<ShelfUpdateResult> refreshShelfBooks({
    String? shelfId,
    required bool Function() isCancelled,
  }) async => const ShelfUpdateResult();
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      ChapterContent([
        for (var i = 0; i < 20; i++) Paragraph('段落$i ${'下载入口测试正文。' * 30}'),
      ]);
  @override
  Future<ChapterContent?> cached(Book book, Chapter chapter) async => null;
  @override
  Future<void> downloadChapters(
    Book book,
    List<Chapter> chapters, {
    required void Function(Chapter chapter, Object? error) onProgress,
    bool Function()? isCancelled,
    bool refreshCached = false,
  }) async {
    downloads.add((book: book, chapters: chapters));
    for (final chapter in chapters) {
      onProgress(chapter, null);
    }
  }
}

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  late EntrySource source;
  late EntryLibrary library;
  setUp(() {
    source = EntrySource();
    library = EntryLibrary(source);
  });
  tearDown(() {
    library.dispose();
    source.api.close();
  });

  void viewport(WidgetTester tester) {
    setTestViewport(
      tester,
      defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1400, 900)
          : const Size(320, 720),
    );
  }

  Future<void> shelfDownload(WidgetTester tester, Book book) async {
    await tester.longPress(find.byKey(ValueKey('shelf-book-${book.key}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载章节'));
  }

  Future<void> downloadRange(WidgetTester tester) async {
    expect(find.byType(DownloadDialog), findsOneWidget);
    expect(library.downloads, isEmpty);
    await tester.enterText(find.widgetWithText(TextField, '起始章'), '2');
    await tester.enterText(find.widgetWithText(TextField, '结束章'), '3');
    final start = find.widgetWithText(FilledButton, '开始下载');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(library.downloads.single.book.key, sample().key);
    expect(library.downloads.single.chapters.map((c) => c.id), ['2', '3']);
    expect(find.text('下载完成 · 成功 2 章，失败 0 章'), findsOneWidget);
    final close = find.widgetWithText(TextButton, '关闭');
    await tester.ensureVisible(close);
    await tester.tap(close);
    await tester.pumpAndSettle();
  }

  for (final layout in ShelfLayout.values) {
    testWidgets('书架长按可直接选择范围下载，不进入详情或阅读页（${layout.name}）', (tester) async {
      viewport(tester);
      final book = sample();
      library
        ..shelfLayout = layout
        ..books.add(book);
      await tester.pumpWidget(UnrApp(library: library));
      await tester.pumpAndSettle();
      await shelfDownload(tester, book);
      await tester.pumpAndSettle();
      await downloadRange(tester);
      expect(source.calls, 0);
      expect(find.byType(ReaderPage), findsNothing);
      expect(library.recentBooks, isEmpty);
      expect(find.byKey(ValueKey('shelf-book-${book.key}')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: platforms);
  }

  testWidgets('预览作品下载先加载完整目录，失败可重试', (tester) async {
    viewport(tester);
    final book = sample(preview: true);
    library.books.add(book);
    source.fail = true;
    await tester.pumpWidget(UnrApp(library: library));
    await tester.pumpAndSettle();
    await shelfDownload(tester, book);
    await tester.pumpAndSettle();
    expect(find.text('目录加载失败'), findsOneWidget);
    expect(find.byType(DownloadDialog), findsNothing);
    expect(library.books.single.chapters, isEmpty);
    source.fail = false;
    await shelfDownload(tester, book);
    await tester.pumpAndSettle();
    expect(source.calls, 2);
    expect(
      tester
          .widget<DownloadDialog>(find.byType(DownloadDialog))
          .book
          .chapters
          .length,
      3,
    );
    await downloadRange(tester);
    expect(library.recentBooks, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  for (final dispose in [false, true]) {
    testWidgets('下载目录加载期间离开页面，忽略迟到结果（销毁=$dispose）', (tester) async {
      viewport(tester);
      final book = sample(preview: true);
      library.books.add(book);
      source.pending = Completer<Book>();
      await tester.pumpWidget(UnrApp(library: library));
      await tester.pumpAndSettle();
      await shelfDownload(tester, book);
      await tester.pump();
      expect(source.calls, 1);
      if (dispose) {
        await tester.pumpWidget(const SizedBox.shrink());
      } else {
        await tester.tap(find.text('我的').last);
        await tester.pump();
      }
      source.pending!.complete(sample());
      await tester.pumpAndSettle();
      expect(find.byType(DownloadDialog), findsNothing);
      expect(library.books.single.chapters, isEmpty);
      expect(library.downloads, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: platforms);
  }

  for (final mode in ReadingMode.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('阅读顶栏下载后保留章节和阅读位置（${mode.name}，缩放$scale）', (tester) async {
        viewport(tester);
        final book = sample();
        library.readingMode = mode;
        library.progress[book.key] = [1, 4];
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: ReaderPage(library: library, book: book),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('下载章节').hitTestable(), findsNothing);
        await showReadingControls(tester);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byTooltip('下载章节'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('reader-bottom-toolbar')),
            matching: find.byTooltip('下载章节'),
          ),
          findsNothing,
        );
        final reader = tester.state(find.byType(ReaderPage)) as dynamic;
        final position = (
          reader.chapter,
          reader.paragraph,
          reader.characterOffset,
        );
        await tester.tap(find.byTooltip('下载章节'));
        await tester.pumpAndSettle();
        await downloadRange(tester);
        expect((
          reader.chapter,
          reader.paragraph,
          reader.characterOffset,
        ), position);
        expect(library.books, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: platforms);
    }
  }

  for (final sourceId in ['local', 'unavailable']) {
    testWidgets('本地或不可用书源不显示下载入口（$sourceId）', (tester) async {
      viewport(tester);
      final book = sample(source: sourceId);
      library.books.add(book);
      await tester.pumpWidget(UnrApp(library: library));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(ValueKey('shelf-book-${book.key}')));
      await tester.pumpAndSettle();
      expect(find.text('下载章节'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shelf-book-${book.key}')));
      await tester.pumpAndSettle();
      await showReadingControls(tester);
      await tester.pumpAndSettle();
      expect(find.byTooltip('下载章节'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: platforms);
  }
}
