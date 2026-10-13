import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg_api.dart';
import 'package:unr/sources/sfacg_source.dart';
import 'package:unr/ui/reader.dart';
import 'package:unr/formats/ebook.dart';

class MemoryLibrary extends Library {
  MemoryLibrary() : super(Directory.systemTemp, SfacgSource(SfacgApi()));
  final first = Completer<ChapterContent>(),
      second = Completer<ChapterContent>();
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) =>
      chapter.id == '1' ? first.future : second.future;
  @override
  Future<void> save() async {
    notifyListeners();
  }

  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

void main() {
  testWidgets('外部 TXT 在手机尺寸可见，滚动后立即返回也保存进度', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final imported = Ebook.importTxt(
      Uint8List.fromList(
        utf8.encode(
          '第一章 开始\n${List.generate(40, (i) => '正文段落 $i').join('\n')}',
        ),
      ),
      '导入小说.txt',
    );
    final library = MemoryLibrary();
    library.second.complete(imported.contents.values.single);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      ReaderPage(library: library, book: imported.book),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final first = tester.getRect(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == '　　正文段落 0',
      ),
    );
    expect(first.top, greaterThan(50));
    expect(first.bottom, lessThan(580));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -700),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(library.progress[imported.book.key]![1], greaterThan(0));
    library.source.api.close();
  });
  testWidgets('快速切章时旧请求不得覆盖新章节，字号立即更新', (tester) async {
    final library = MemoryLibrary();
    const book = Book(
      id: '1',
      title: '测试书',
      author: '',
      source: 'local',
      chapters: [
        Chapter(id: '1', title: '第一章'),
        Chapter(id: '2', title: '第二章'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: book),
      ),
    );
    await tester.tap(find.text('下一章'));
    await tester.pump();
    library.second.complete(const ChapterContent([Paragraph('第二章正文')]));
    await tester.pumpAndSettle();
    expect(find.text('　　第二章正文'), findsOneWidget);
    final bodyRect = tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == '　　第二章正文',
      ),
    );
    final footerRect = tester.getRect(find.text('下一章'));
    expect(bodyRect.top, greaterThan(50));
    expect(bodyRect.bottom, lessThan(footerRect.top));
    expect(
      tester.getSize(find.byType(SingleChildScrollView)).height,
      greaterThan(100),
    );
    expect(footerRect.top, greaterThan(500));
    library.first.complete(
      const ChapterContent([Paragraph('过时正文'), Paragraph('另一段')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('　　过时正文'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('字号增大'), findsNothing);
    expect(find.byTooltip('字号减小'), findsNothing);
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    final size = tester.widget<Slider>(
      find.byKey(const ValueKey('reading-font-size')),
    );
    size.onChanged!(22);
    size.onChangeEnd!(22);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭阅读设置'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(
            find.byWidgetPredicate(
              (widget) => widget is SelectableText && widget.data == '　　第二章正文',
            ),
          )
          .style!
          .fontSize,
      22,
    );
    library.source.api.close();
  });
}
