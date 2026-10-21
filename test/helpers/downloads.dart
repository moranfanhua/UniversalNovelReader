import 'dart:async';
import 'dart:io';
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'memory_library.dart';

const chapters = [
  Chapter(id: '1', title: '第一章'),
  Chapter(id: '2', title: '第二章'),
  Chapter(id: '3', title: '第三章'),
];
const content = ChapterContent([Paragraph('已保存的正文')]);
Book sample(String id, {String source = 'sfacg', String? title}) => Book(
  id: id,
  source: source,
  title: title ?? '下载作品$id',
  author: '作者',
  chapters: chapters,
);

class DownloadsLibrary extends TestLibrary
    with MemoryPersistence, EmptyChapterCache {
  DownloadsLibrary() : super(source: offlineSource());
  DownloadedBooksSnapshot snapshot = const DownloadedBooksSnapshot(books: []);
  Completer<DownloadedBooksSnapshot>? pending;
  bool fail = false;
  int loads = 0;
  final reads = <String>[];
  final deleted = <String>[];
  final deleteFailures = <String>{};
  final downloadCalls = <String>[];
  final downloadFailures = <String>{};
  Completer<void>? pendingDelete, pendingDownload;
  bool failChapter = false;

  @override
  Future<void> deleteDownloadedBook(Book book) async {
    deleted.add(book.key);
    await pendingDelete?.future;
    if (deleteFailures.contains(book.key)) {
      throw const FileSystemException('删除失败');
    }
    snapshot = DownloadedBooksSnapshot(
      books: snapshot.books
          .where((entry) => entry.book.key != book.key)
          .toList(),
    );
  }

  @override
  Future<void> downloadChapters(
    Book book,
    List<Chapter> chapters, {
    required void Function(Chapter chapter, Object? error) onProgress,
    bool Function()? isCancelled,
    bool refreshCached = false,
  }) async {
    downloadCalls.add(book.key);
    await pendingDownload?.future;
    if (downloadFailures.contains(book.key)) {
      throw const SourceException('下载任务失败');
    }
    for (final chapter in chapters) {
      if (isCancelled?.call() == true) break;
      onProgress(
        chapter,
        failChapter && chapter.id == '2'
            ? const SourceException('章节无权限')
            : null,
      );
    }
  }

  @override
  Future<DownloadedBooksSnapshot> downloadedBooks() async {
    loads++;
    if (fail) throw const FileSystemException('无法读取');
    return pending == null ? snapshot : pending!.future;
  }

  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async {
    reads.add(chapter.id);
    return content;
  }

  @override
  Future<ChapterContent?> cached(Book book, Chapter chapter) async => null;
}

SfacgSource offlineSource() => SfacgSource(
  SfacgApi(client: MockClient((_) async => throw StateError('不应访问网络'))),
);
