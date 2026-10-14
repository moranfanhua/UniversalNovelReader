import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/reader.dart';
import 'chapter_preview_test.dart' show PreviewComments;
import 'helpers/reading_taps.dart';

final scrollBook = Book(
  id: 'continuous-scroll',
  source: 'alternate',
  title: '连续滚动',
  author: '',
  chapters: [for (var i = 1; i <= 6; i++) Chapter(id: '$i', title: '章节$i')],
);

class ScrollLibrary extends Library {
  ScrollLibrary({CommentSource? comments})
    : super(
        Directory.systemTemp,
        SfacgSource(SfacgApi()),
        commentSources: comments == null ? [] : [comments],
      );
  final requests = <String>[];
  final contents = <String, ChapterContent>{
    for (var i = 1; i <= 6; i++)
      '$i': ChapterContent([
        for (var row = 0; row < 30; row++)
          Paragraph('第$i章段落$row', remoteIndex: row),
      ]),
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

void main() {
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
  }

  Future<void> mount(WidgetTester tester, ScrollLibrary library) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: scrollBook),
      ),
    );
    await settle(tester);
  }

  Future<void> open(WidgetTester tester, ScrollLibrary library) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await mount(tester, library);
  }

  ScrollController controller(WidgetTester tester) => tester
      .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
      .controller!;
  Future<void> end(WidgetTester tester) async {
    final scroll = controller(tester);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await settle(tester);
  }

  testWidgets('到章末立即追加下一章，不需第二次滑动、不改变原末尾位置', (tester) async {
    final library = ScrollLibrary();
    await open(tester, library);
    final scroll = controller(tester);
    final offset = scroll.position.maxScrollExtent;
    scroll.jumpTo(offset);
    await settle(tester);
    expect(library.requests, ['1', '2']);
    expect(scroll.offset, closeTo(offset, .1));
    expect(scroll.position.maxScrollExtent, greaterThan(offset));
    expect(find.text('　　第1章段落29').hitTestable(), findsOneWidget);
    expect(find.text('　　第2章段落0'), findsOneWidget);
    expect(library.progress[scrollBook.key]!.first, 0);
    await Scrollable.ensureVisible(
      tester.element(find.text('　　第2章段落5')),
      alignment: 0,
    );
    await settle(tester);
    expect(readingChapter(tester), 1);
    expect(library.progress[scrollBook.key], [1, 5]);
    await Scrollable.ensureVisible(
      tester.element(find.text('　　第1章段落29')),
      alignment: 0,
    );
    await settle(tester);
    expect(readingChapter(tester), 0);
    expect(library.requests, ['1', '2']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('下一章加载期间不重复请求，失败保留正文并可重试', (tester) async {
    final library = ScrollLibrary()..pending = Completer<ChapterContent>();
    await open(tester, library);
    final scroll = controller(tester);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('scroll-next-loading')), findsOneWidget);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    expect(library.requests, ['1', '2']);
    library.pending!.completeError(const SourceException('章节权限无效'));
    await settle(tester);
    expect(find.text('　　第1章段落29'), findsOneWidget);
    expect(find.textContaining('下一章加载失败'), findsOneWidget);
    library.pending = null;
    await tester.ensureVisible(find.byKey(const ValueKey('retry-scroll-next')));
    await tester.tap(find.byKey(const ValueKey('retry-scroll-next')));
    await settle(tester);
    expect(library.requests, ['1', '2', '2']);
    expect(find.text('　　第2章段落0'), findsOneWidget);
    expect(find.byKey(const ValueKey('scroll-next-error')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('等待追加时手动切章，旧结果不得插入新章节', (tester) async {
    final library = ScrollLibrary()..pending = Completer<ChapterContent>();
    await open(tester, library);
    controller(tester).jumpTo(controller(tester).position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    await showReadingControls(tester);
    await tester.tap(find.text('下一章'));
    await tester.pump();
    await showReadingControls(tester);
    await tester.tap(find.text('下一章'));
    await settle(tester);
    library.pending!.complete(library.contents['2']);
    await settle(tester);
    expect(readingChapter(tester), 2);
    expect(find.text('　　第3章段落0'), findsOneWidget);
    expect(find.text('　　第2章段落0'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('跨章后的进度以及需要下一章才能对齐的章末书签可恢复', (tester) async {
    final library = ScrollLibrary();
    library.progress[scrollBook.key] = [0, 28];
    await open(tester, library);
    expect(library.requests, ['1', '2']);
    expect(library.progress[scrollBook.key], [0, 28]);
    await Scrollable.ensureVisible(
      tester.element(find.text('　　第2章段落15')),
      alignment: 0,
    );
    await settle(tester);
    final saved = library.progress[scrollBook.key]!.toList();
    expect(saved, [1, 15]);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, library);
    expect(library.progress[scrollBook.key], saved);
    expect(readingChapter(tester), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    '长时间连续阅读回收旧章节，保留位置并可回到前一章',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final library = ScrollLibrary();
        await open(tester, library);
        for (var i = 0; i < 5; i++) {
          await end(tester);
        }
        expect(library.requests, ['1', '2', '3', '4', '5', '6']);
        expect(find.text('章节1'), findsNothing);
        expect(find.text('章节2'), findsNothing);
        expect(find.text('章节3'), findsNothing);
        expect(find.text('章节4'), findsOneWidget);
        expect(find.text('　　第5章段落29').hitTestable(), findsOneWidget);
        final scroll = controller(tester);
        scroll.jumpTo(0);
        await settle(tester);
        await tester.drag(
          find.byType(SingleChildScrollView),
          const Offset(0, 150),
        );
        await settle(tester);
        expect(find.text('章节3'), findsOneWidget);
        expect(find.text('　　第3章段落29').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('已追加章节相同段号的段评仍请求对应书源章节', (tester) async {
    final comments = PreviewComments();
    final library = ScrollLibrary(comments: comments);
    await open(tester, library);
    await end(tester);
    await Scrollable.ensureVisible(
      tester.element(find.text('　　第2章段落0')),
      alignment: 0,
    );
    await settle(tester);
    final row = find.ancestor(
      of: find.text('　　第2章段落0'),
      matching: find.byType(Row),
    );
    final button = find.descendant(
      of: row,
      matching: find.widgetWithText(TextButton, '22'),
    );
    expect(button, findsOneWidget);
    await tester.tap(button);
    await settle(tester);
    expect(comments.locations.last.chapter.id, '2');
    expect(comments.locations.last.paragraph.remoteIndex, 0);
    Navigator.of(tester.element(find.byType(ReaderPage))).pop();
    await settle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('短章节自动补足视窗，最后一章不再请求下一章', (tester) async {
    final library = ScrollLibrary();
    for (var i = 1; i <= 6; i++) {
      library.contents['$i'] = const ChapterContent([Paragraph('短正文')]);
    }
    await open(tester, library);
    for (var i = 0; i < 6 && library.requests.length < 6; i++) {
      await end(tester);
    }
    expect(library.requests.length, 6);
    final requests = library.requests.toList();
    await end(tester);
    expect(library.requests, requests);
    expect(find.text('章节6'), findsOneWidget);
    expect(find.byKey(const ValueKey('scroll-next-loading')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
