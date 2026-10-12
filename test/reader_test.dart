import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg_api.dart';
import 'package:unr/sources/sfacg_source.dart';
import 'package:unr/ui/reader.dart';

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
    library.first.complete(
      const ChapterContent([Paragraph('过时正文'), Paragraph('另一段')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('　　过时正文'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('字号增大'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SelectableText>(find.text('　　第二章正文')).style!.fontSize,
      22,
    );
    library.source.api.close();
  });
}
