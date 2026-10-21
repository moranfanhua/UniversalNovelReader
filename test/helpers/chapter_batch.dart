import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/chapter_batch_source.dart';

const chapters = [
  Chapter(id: '1', title: '第一章'),
  Chapter(id: '2', title: '第二章'),
  Chapter(id: '3', title: '第三章'),
  Chapter(id: '4', title: '第四章'),
  Chapter(id: '5', title: '第五章'),
];
const book = Book(
  id: '1',
  source: 'batch',
  title: '下载测试',
  author: '作者',
  chapters: chapters,
);

ChapterBatchResult content(Chapter chapter) => ChapterBatchResult.success(
  chapter.id,
  ChapterContent([Paragraph('正文 ${chapter.id}')]),
);

class BatchSource implements ChapterBatchSource {
  @override
  String get id => 'batch';
  @override
  String get name => '批量书源';
  @override
  int chapterBatchSize = 2;
  @override
  int chapterBatchConcurrency = 2;
  final calls = <List<Chapter>>[];
  Future<List<ChapterBatchResult>> Function(List<Chapter>)? fetch;
  Future<ChapterContent>? singleRead;
  bool singleReadStarted = false;
  @override
  Future<Book> getBook(String input) async => book;
  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async {
    if (singleRead != null) {
      singleReadStarted = true;
      return singleRead!;
    }
    fail('批量下载不应退回逐章接口');
  }

  @override
  Future<List<ChapterBatchResult>> readChapterBatch(
    Book book,
    List<Chapter> chapters,
  ) async {
    calls.add(chapters);
    return fetch == null ? chapters.map(content).toList() : fetch!(chapters);
  }
}

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 2000 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(predicate(), isTrue);
}
