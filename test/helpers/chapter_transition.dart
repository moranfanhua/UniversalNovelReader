import 'dart:async';
import 'package:unr/domain/models.dart';
import 'memory_library.dart';

class TransitionLibrary extends TestLibrary
    with MemoryPersistence, MemoryReadingProgress {
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
