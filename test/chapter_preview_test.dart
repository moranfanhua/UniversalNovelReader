import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/reader.dart';
import 'comment_source_test.dart' show AlternateComments;
import 'helpers/reading_taps.dart';

const previewBook = Book(
  id: 'preview-book',
  source: 'alternate',
  title: '跨章双页',
  author: '',
  chapters: [
    Chapter(id: '1', title: '甲章'),
    Chapter(id: '2', title: '乙章'),
    Chapter(id: '3', title: '丙章'),
  ],
);

class PreviewComments extends AlternateComments {
  @override
  Future<int> paragraphCommentCount(
    CommentLocation location, {
    bool refresh = false,
  }) async {
    locations.add(location);
    return int.parse(location.chapter.id) * 11;
  }
}

class PreviewLibrary extends Library {
  PreviewLibrary({PreviewComments? comments})
    : super(
        Directory.systemTemp,
        SfacgSource(SfacgApi()),
        commentSources: comments == null ? [] : [comments],
      );
  final requests = <String>[];
  Completer<ChapterContent>? pending;
  final contents = <String, ChapterContent>{
    '1': const ChapterContent([
      Paragraph('甲章首页', remoteIndex: 7),
      Paragraph('', image: 'a-image', remoteIndex: 8),
      Paragraph('甲章末页', remoteIndex: 9),
    ]),
    '2': const ChapterContent([
      Paragraph('乙章首页', remoteIndex: 7),
      Paragraph('', image: 'b-image', remoteIndex: 8),
      Paragraph('乙章末页', remoteIndex: 9),
    ]),
    '3': const ChapterContent([Paragraph('丙章首页', remoteIndex: 7)]),
  };
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async {
    requests.add(chapter.id);
    if (chapter.id == '2' && pending != null) return pending!.future;
    return contents[chapter.id]!;
  }

  @override
  Future<Uint8List> loadImage(Book book, String url) async => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1QAAAAASUVORK5CYII=',
  );
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
  }

  Future<void> mount(WidgetTester tester, PreviewLibrary library) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: previewBook),
      ),
    );
    await settle(tester);
  }

  Future<void> open(
    WidgetTester tester,
    PreviewLibrary library, {
    double width = 1920,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await mount(tester, library);
  }

  Future<void> next(WidgetTester tester) async {
    await tapReadingSide(tester, 1);
    await settle(tester);
  }

  testWidgets('奇数末页右侧显示下一章，继续阅读不重复首页，返回恢复原跨章双页', (tester) async {
    final library = PreviewLibrary()..readingMode = ReadingMode.paged;
    await open(tester, library);
    expect(library.requests, ['1']);
    await next(tester);
    expect(
      tester.getRect(find.text('　　甲章末页').hitTestable()).left,
      lessThan(900),
    );
    expect(
      tester.getRect(find.text('　　乙章首页').hitTestable()).left,
      greaterThan(900),
    );
    expect(find.text('乙章').hitTestable(), findsOneWidget);
    expect(library.progress[previewBook.key], [0, 2]);
    await next(tester);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.text('　　乙章首页').hitTestable(), findsNothing);
    expect(find.text('　　乙章末页').hitTestable(), findsOneWidget);
    expect(library.progress[previewBook.key], [1, 1]);
    expect(library.requests, ['1', '2', '2']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(find.text('　　甲章末页').hitTestable(), findsOneWidget);
    expect(find.text('　　乙章首页').hitTestable(), findsOneWidget);
    await next(tester);
    await next(tester);
    expect(find.text('3 / 3'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(320, 0));
    await settle(tester);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.text('　　乙章首页').hitTestable(), findsNothing);
    expect(find.text('　　乙章末页').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('下一章仅一页时整章已在右页展示，下一次翻页及返回都不重复该章', (tester) async {
    final library = PreviewLibrary()..readingMode = ReadingMode.paged;
    library.contents['2'] = const ChapterContent([Paragraph('乙章单页')]);
    await open(tester, library);
    await next(tester);
    expect(find.text('　　乙章单页').hitTestable(), findsOneWidget);
    await next(tester);
    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.text('　　丙章首页').hitTestable(), findsOneWidget);
    await tapReadingSide(tester, -1);
    await settle(tester);
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.text('　　甲章末页').hitTestable(), findsOneWidget);
    expect(find.text('　　乙章单页').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('跨章双页两侧相同段号的计数及点击段评各归属正确章节', (tester) async {
    final comments = PreviewComments();
    final library = PreviewLibrary(comments: comments)
      ..readingMode = ReadingMode.paged;
    library.contents['1'] = const ChapterContent([
      Paragraph('甲章首页', remoteIndex: 7),
    ]);
    await open(tester, library);
    expect(find.text('11').hitTestable(), findsOneWidget);
    expect(find.text('22').hitTestable(), findsOneWidget);
    expect(comments.locations.map((location) => location.chapter.id).toSet(), {
      '1',
      '2',
    });
    await tester.tap(find.widgetWithText(TextButton, '22').hitTestable());
    await settle(tester);
    expect(comments.locations.last.chapter.id, '2');
    expect(comments.locations.last.paragraph.remoteIndex, 7);
    expect(library.progress[previewBook.key]!.first, 0);
    Navigator.of(tester.element(find.byType(ReaderPage))).pop();
    await settle(tester);
    expect(find.text('11').hitTestable(), findsOneWidget);
    expect(find.text('22').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('预读失败保留当前正文及位置，右页可重试', (tester) async {
    final library = PreviewLibrary()
      ..readingMode = ReadingMode.paged
      ..pending = Completer<ChapterContent>();
    await open(tester, library);
    await tapReadingSide(tester, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('　　甲章末页').hitTestable(), findsOneWidget);
    expect(find.text('正在加载下一章'), findsOneWidget);
    library.pending!.completeError(const SourceException('章节权限无效'));
    await settle(tester);
    expect(find.textContaining('下一章加载失败'), findsOneWidget);
    expect(library.progress[previewBook.key], [0, 2]);
    library.pending = null;
    await tester.tap(find.text('重试下一章'));
    await settle(tester);
    expect(find.text('　　乙章首页').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('重新进入及宽窄屏切换保留已消费的下一章首页和阅读锚点', (tester) async {
    final library = PreviewLibrary()..readingMode = ReadingMode.paged;
    await open(tester, library);
    await next(tester);
    await next(tester);
    final saved = library.progress[previewBook.key]!.toList();
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, library);
    expect(find.text('　　乙章首页').hitTestable(), findsNothing);
    expect(library.progress[previewBook.key], saved);
    for (final width in [360.0, 1920.0]) {
      tester.view.physicalSize = Size(width, 640);
      await settle(tester);
      expect(library.progress[previewBook.key], saved);
      expect(tester.takeException(), isNull);
    }
    await tapReadingSide(tester, -1);
    await settle(tester);
    expect(find.text('　　甲章末页').hitTestable(), findsOneWidget);
    expect(find.text('　　乙章首页').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('偶数双页末尾不预读，最终章保留正常空白右页', (tester) async {
    final library = PreviewLibrary()..readingMode = ReadingMode.paged;
    library.contents['1'] = const ChapterContent([
      Paragraph('甲章首页'),
      Paragraph('', image: 'a-image'),
    ]);
    await open(tester, library);
    expect(library.requests, ['1']);
    await tester.tap(find.text('下一章'));
    await settle(tester);
    await tester.tap(find.text('下一章'));
    await settle(tester);
    expect(find.text('　　丙章首页').hitTestable(), findsOneWidget);
    expect(find.text('正在加载下一章'), findsNothing);
    await tapReadingSide(tester, 1);
    await settle(tester);
    expect(find.text('3 / 3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄屏单页章末不加载双页预读', (tester) async {
    final library = PreviewLibrary()..readingMode = ReadingMode.paged;
    library.contents['1'] = const ChapterContent([Paragraph('甲章单页')]);
    await open(tester, library, width: 360);
    expect(library.requests, ['1']);
    expect(find.text('　　乙章首页'), findsNothing);
    expect(find.text('正在加载下一章'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('下一章长段落拆页后的字符位置可以继续及恢复', (tester) async {
    final library = PreviewLibrary()..readingMode = ReadingMode.paged;
    library.contents['2'] = ChapterContent([
      Paragraph('乙章长段落${'连续正文文字。' * 800}'),
    ]);
    await open(tester, library);
    await next(tester);
    await next(tester);
    final offset = library.pageOffsets[previewBook.key]!;
    expect(offset, greaterThan(0));
    expect(library.progress[previewBook.key], [1, 0]);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, library);
    expect(library.pageOffsets[previewBook.key], offset);
    expect(library.progress[previewBook.key], [1, 0]);
    expect(find.textContaining('　　乙章长段落').hitTestable(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('从目录指定章节重新开始时仍显示首页，不沿用旧的预读偏移', (tester) async {
    final library = PreviewLibrary()..readingMode = ReadingMode.paged;
    await open(tester, library);
    await next(tester);
    await next(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          library: library,
          book: previewBook,
          initialChapter: 1,
        ),
      ),
    );
    await settle(tester);
    expect(find.text('　　乙章首页').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, library);
    expect(find.text('　　乙章首页').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('双页进入方式与上一跨章页来源可以保存并重开', () async {
    final directory = await Directory.systemTemp.createTemp(
      'unr-preview-progress-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = SfacgSource(SfacgApi());
    addTearDown(source.api.close);
    final library = await Library.open(source, directory: directory);
    addTearDown(library.dispose);
    library.pagedChapterEntries['book:1'] = [1, 0, 0];
    library.pagedChapterEntries['book:3'] = [0, 1, 1];
    await library.save();
    final reopened = await Library.open(source, directory: directory);
    addTearDown(reopened.dispose);
    expect(reopened.pagedChapterEntries, library.pagedChapterEntries);
  });
}
