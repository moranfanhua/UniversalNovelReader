import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/paged_chapter.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/reading_taps.dart';

class WideLibrary extends Library {
  WideLibrary(this.content)
    : super(Directory.systemTemp, SfacgSource(SfacgApi()));
  final ChapterContent content;
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async => content;
  @override
  Future<void> save() async => notifyListeners();
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

void main() {
  void size(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
  }

  const book = Book(
    id: 'wide',
    source: 'local',
    title: '宽屏小说',
    author: '',
    chapters: [Chapter(id: '1', title: '第一章')],
  );

  testWidgets('宽屏短页顶部对齐，滚动正文加宽，底栏与顶栏同宽', (tester) async {
    size(tester, const Size(1920, 1080));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = WideLibrary(const ChapterContent([Paragraph('短页正文')]))
      ..readingMode = ReadingMode.paged;
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: book),
      ),
    );
    await tester.pumpAndSettle();
    var text = tester.getRect(find.text('　　短页正文'));
    expect(text.top, lessThan(180));
    expect(text.left, lessThan(250));
    expect(text.width, inInclusiveRange(750, 900));
    library.readingMode = ReadingMode.scroll;
    await library.save();
    await tester.pumpAndSettle();
    text = tester.getRect(find.text('　　短页正文'));
    expect(text.width, inInclusiveRange(1000, 1080));
    await showReadingControls(tester);
    expect(tester.getCenter(find.byTooltip('上一章')).dx, lessThan(120));
    expect(tester.getCenter(find.byTooltip('下一章')).dx, greaterThan(1800));
    expect(
      tester.getSize(find.byKey(const ValueKey('reader-bottom-toolbar'))).width,
      1920,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
  });

  testWidgets('宽屏双页包含两页段评范围，奇数末页保持左侧顶部对齐', (tester) async {
    size(tester, const Size(1920, 1080));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Set<int> rows = {};
    const content = ChapterContent([
      Paragraph('首页正文', remoteIndex: 1),
      Paragraph('', image: 'right', remoteIndex: 2),
      Paragraph('末页短正文', remoteIndex: 3),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PagedChapter(
            content: content,
            title: '双页章节',
            fontSize: 20,
            initialParagraph: 0,
            initialOffset: 0,
            comments: true,
            onPosition: (_, _, visible) => rows = visible,
            imageBuilder: (url) =>
                Container(key: ValueKey('image-$url'), color: Colors.green),
            commentBuilder: (p) => Text('段评${p.remoteIndex}'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(rows, {1, 2});
    final image = tester.getRect(
      find.byKey(const ValueKey('image-right')).hitTestable(),
    );
    expect(image.left, greaterThan(900));
    await tapReadingSide(tester, 1);
    await tester.pumpAndSettle();
    expect(rows, {3});
    final ending = tester.getRect(find.text('　　末页短正文').hitTestable());
    expect(ending.left, lessThan(250));
    expect(ending.top, lessThan(100));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pumpAndSettle();
    expect(rows, {1, 2});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('宽窄屏切换重新分页保留当前文字位置', (tester) async {
    size(tester, const Size(1920, 1080));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = WideLibrary(ChapterContent([Paragraph('连续正文中文😀。' * 1600)]))
      ..readingMode = ReadingMode.paged;
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: book),
      ),
    );
    await tester.pumpAndSettle();
    expect(readingPager(tester).columns, 2);
    expect(readingPager(tester).page, 0);
    await tapReadingSide(tester, 1);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    final offset = library.pageOffsets[book.key]!;
    expect(offset, greaterThan(0));
    size(tester, const Size(360, 640));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(library.pageOffsets[book.key], offset);
    size(tester, const Size(1920, 1080));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(library.pageOffsets[book.key], offset);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
  });
}
