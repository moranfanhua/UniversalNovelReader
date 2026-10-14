import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/reading_taps.dart';

class TransitionLibrary extends Library {
  TransitionLibrary() : super(Directory.systemTemp, SfacgSource(SfacgApi()));
  final requests = <String>[];
  final contents = <String, ChapterContent>{
    '1': ChapterContent([
      for (var i = 0; i < 40; i++) Paragraph('第一章段落$i'),
      const Paragraph('上一章结尾标记'),
    ]),
    '2': const ChapterContent([Paragraph('第二章正文')]),
    '3': const ChapterContent([Paragraph('第三章正文')]),
  };
  Completer<ChapterContent>? pending;
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async {
    requests.add(chapter.id);
    if (chapter.id == '2' && pending != null) return pending!.future;
    return contents[chapter.id]!;
  }

  @override
  Future<void> save() async => notifyListeners();
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

const transitionBook = Book(
  id: 'transitions',
  source: 'local',
  title: '连续阅读',
  author: '',
  chapters: [
    Chapter(id: '1', title: '第一章'),
    Chapter(id: '2', title: '第二章'),
    Chapter(id: '3', title: '第三章'),
  ],
);

void main() {
  Future<void> open(
    WidgetTester tester,
    TransitionLibrary library, {
    int chapter = 0,
    double width = 360,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          library: library,
          book: transitionBook,
          initialChapter: chapter,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
  }

  testWidgets('上一页进入上一章末页，下一页和键盘在章节边界连续阅读', (tester) async {
    final library = TransitionLibrary()..readingMode = ReadingMode.paged;
    await open(tester, library, chapter: 1);
    await tapReadingSide(tester, -1);
    await settle(tester);
    expect(readingChapter(tester), 0);
    expect(find.textContaining('上一章结尾标记').hitTestable(), findsOneWidget);
    expect(library.progress[transitionBook.key]!.last, greaterThan(20));
    final pager = readingPager(tester);
    expect(pager.page, pager.pages.length - 1);
    await tapReadingSide(tester, 1);
    await settle(tester);
    expect(readingChapter(tester), 1);
    expect(find.text('　　第二章正文'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await settle(tester);
    expect(readingChapter(tester), 2);
    await tapReadingSide(tester, 1);
    await settle(tester);
    expect(readingChapter(tester), 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settle(tester);
    expect(readingChapter(tester), 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [360.0, 1920.0]) {
    testWidgets('单页和双页横向滑动到边界衔接相邻章（$width）', (tester) async {
      final library = TransitionLibrary()..readingMode = ReadingMode.paged;
      await open(tester, library, chapter: 1, width: width);
      if (width > 1000) {
        // Both remaining one-page chapters now share the final spread.
        expect(find.text('　　第三章正文').hitTestable(), findsOneWidget);
        await tapReadingSide(tester, 1);
        await settle(tester);
        expect(readingChapter(tester), 1);
        await tester.drag(find.byType(PageView), const Offset(320, 0));
        await settle(tester);
        expect(readingChapter(tester), 0);
        expect(find.textContaining('上一章结尾标记').hitTestable(), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        return;
      }
      await tester.drag(find.byType(PageView), const Offset(-320, 0));
      await settle(tester);
      expect(readingChapter(tester), 2);
      await tester.drag(find.byType(PageView), const Offset(320, 0));
      await settle(tester);
      expect(readingChapter(tester), 1);
      expect(find.text('　　第二章正文').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('滚动到底自动追加下一章，原章节仍可回读', (tester) async {
    final library = TransitionLibrary();
    library.contents['2'] = ChapterContent([
      const Paragraph('第二章正文'),
      for (var i = 0; i < 40; i++) Paragraph('第二章段落$i'),
    ]);
    await open(tester, library);
    final view = find.byType(SingleChildScrollView);
    final controller = tester.widget<SingleChildScrollView>(view).controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await settle(tester);
    expect(readingChapter(tester), 0);
    expect(library.requests, ['1', '2']);
    expect(find.text('　　第二章正文'), findsOneWidget);
    await Scrollable.ensureVisible(
      tester.element(find.text('　　第二章正文')),
      alignment: 0,
    );
    await settle(tester);
    expect(readingChapter(tester), 1);
    await Scrollable.ensureVisible(
      tester.element(find.text('　　上一章结尾标记')),
      alignment: 0,
    );
    await settle(tester);
    expect(readingChapter(tester), 0);
    expect(find.text('　　上一章结尾标记').hitTestable(), findsOneWidget);
    expect(library.progress[transitionBook.key]!.last, greaterThan(20));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面滚轮到达章末便加载下一章，回滚不需重新加载当前章', (tester) async {
    final library = TransitionLibrary();
    await open(tester, library, width: 1920);
    final controller = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    final end = controller.position.maxScrollExtent;
    controller.jumpTo(end - 20);
    await settle(tester);
    Future<void> wheel(double delta) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(SingleChildScrollView)),
          scrollDelta: Offset(0, delta),
        ),
      );
      await settle(tester);
    }

    await wheel(30);
    expect(library.requests, ['1', '2']);
    expect(find.text('　　第二章正文'), findsOneWidget);
    expect(controller.offset, closeTo(end, .01));
    await wheel(-30);
    expect(controller.offset, closeTo(end - 30, .01));
    expect(readingChapter(tester), 0);
    expect(find.text('　　上一章结尾标记').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('惯性到达章末会追加下一章，停止惯性以保留当前章结尾', (tester) async {
    final library = TransitionLibrary();
    await open(tester, library);
    final view = find.byType(SingleChildScrollView);
    final controller = tester.widget<SingleChildScrollView>(view).controller!;
    final end = controller.position.maxScrollExtent;
    controller.jumpTo(end - 600);
    await tester.pump();
    await tester.fling(view, const Offset(0, -300), 4000);
    await settle(tester);
    expect(controller.offset, closeTo(end, 0.01));
    expect(readingChapter(tester), 0);
    expect(library.requests, ['1', '2']);
    expect(find.text('　　上一章结尾标记').hitTestable(), findsOneWidget);
    expect(find.text('　　第二章正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('相邻章加载期间重复输入不跳章，失败显示重试且可返回', (tester) async {
    final library = TransitionLibrary()
      ..readingMode = ReadingMode.paged
      ..pending = Completer<ChapterContent>();
    await open(tester, library, chapter: 2);
    await tapReadingSide(tester, -1);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pump();
    expect(library.requests, ['3', '2']);
    library.pending!.completeError(const SourceException('章节权限无效'));
    await settle(tester);
    expect(find.text('章节权限无效'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    library.pending = null;
    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(find.text('　　第二章正文'), findsOneWidget);
    expect(readingChapter(tester), 1);
    expect(library.requests, ['3', '2', '2']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
