import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'helpers/chapter_batch.dart'
    show BatchSource, book, chapters, content, until;

class DelayedCacheLibrary extends Library {
  DelayedCacheLibrary(super.root, super.source);
  final pending = Completer<ChapterContent?>();
  @override
  Future<ChapterContent?> cached(Book book, Chapter chapter) => pending.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Library library;
  late SfacgSource fallback;
  late BatchSource source;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('unr-delete-cache-');
    fallback = SfacgSource(
      SfacgApi(client: MockClient((_) async => throw StateError('不应联网'))),
    );
    source = BatchSource();
    library = Library(root, fallback, novelSources: [source]);
  });
  tearDown(() async {
    library.dispose();
    fallback.api.close();
    await root.delete(recursive: true);
  });

  test('仅删除对应书源作品的正文、图片与元数据，保留成员和进度并支持重新下载', () async {
    final other = Book(
      id: book.id,
      source: 'other',
      title: book.title,
      author: '',
      chapters: chapters,
    );
    await library.add(book);
    await library.add(other);
    await library.recordReading(book);
    await library.remember(book, 1, 2);
    await library.store(book, chapters.first, content(chapters.first).content!);
    await library.store(
      other,
      chapters.first,
      content(chapters.first).content!,
    );
    await library.saveImage(book, 'local:cover', Uint8List.fromList([1, 2]));
    await library.deleteDownloadedBook(book);
    expect(await library.cached(book, chapters.first), isNull);
    expect(await library.image(book, 'local:cover'), isNull);
    expect(await library.cached(other, chapters.first), isNotNull);
    expect(library.isOnShelf(book), isTrue);
    expect(library.recentBooks.single.key, book.key);
    expect(library.progress[book.key], [1, 2]);
    final restored = await Library.open(
      fallback,
      directory: root,
      novelSources: [source],
    );
    addTearDown(restored.dispose);
    expect((await restored.downloadedBooks()).books.single.book.key, other.key);
    expect(restored.progress[book.key], [1, 2]);
    await library.downloadChapters(book, [
      chapters.first,
    ], onProgress: (_, error) => expect(error, isNull));
    final again = await Library.open(
      fallback,
      directory: root,
      novelSources: [source],
    );
    addTearDown(again.dispose);
    expect(
      (await again.downloadedBooks()).books.map((e) => e.book.key),
      contains(book.key),
    );
    await library.deleteDownloadedBook(book);
    await library.deleteDownloadedBook(book);
  });

  test('读取、下载和文件写入中的作品不能删除，既有缓存仍保留', () async {
    await library.store(book, chapters.first, content(chapters.first).content!);
    final gate = Completer<void>();
    source.fetch = (batch) async {
      await gate.future;
      return batch.map(content).toList();
    };
    final downloading = library.downloadChapters(book, [
      chapters.last,
    ], onProgress: (_, _) {});
    await until(() => source.calls.isNotEmpty);
    await expectLater(
      library.deleteDownloadedBook(book),
      throwsA(isA<SourceException>()),
    );
    expect(await library.cached(book, chapters.first), isNotNull);
    gate.complete();
    await downloading;
    final readingGate = Completer<ChapterContent>();
    source.singleRead = readingGate.future;
    final reading = library.read(book, chapters[1]);
    await until(() => source.singleReadStarted);
    await expectLater(
      library.deleteDownloadedBook(book),
      throwsA(isA<SourceException>()),
    );
    readingGate.complete(content(chapters[1]).content!);
    await reading;
    final fresh = Book(
      id: 'writing',
      source: book.source,
      title: '写入中',
      author: '',
      chapters: chapters,
    );
    final writing = library.store(
      fresh,
      chapters[2],
      content(chapters[2]).content!,
    );
    await expectLater(
      library.deleteDownloadedBook(fresh),
      throwsA(isA<SourceException>()),
    );
    await writing;
    expect(await library.cached(fresh, chapters[2]), isNotNull);
    await library.deleteDownloadedBook(book);
    expect(await library.cached(book, chapters.first), isNull);
  });

  test('队列中等待的作品不能删除，取消后可以删除且不会被后续任务重新缓存', () async {
    final waitingBook = Book(
      id: 'waiting',
      source: book.source,
      title: '排队作品',
      author: '',
      chapters: chapters,
    );
    await library.store(
      waitingBook,
      chapters.first,
      content(chapters.first).content!,
    );
    final gate = Completer<void>();
    source.fetch = (batch) async {
      await gate.future;
      return batch.map(content).toList();
    };
    final active = library.downloadQueue.enqueue(book, [chapters.first]);
    final waiting = library.downloadQueue.enqueue(waitingBook, chapters);
    await until(() => source.calls.isNotEmpty);
    await expectLater(
      library.deleteDownloadedBook(waitingBook),
      throwsA(isA<SourceException>()),
    );
    library.downloadQueue.cancel(waiting);
    await library.deleteDownloadedBook(waitingBook);
    gate.complete();
    await active.whenFinished;
    expect(source.calls.length, 1);
    expect(await library.cached(waitingBook, chapters.first), isNull);
    final downloaded = await library.downloadedBooks();
    expect(downloaded.books.single.book.key, book.key);
  });

  test('删除期间禁止新读取、下载和写入，完成后可以重建缓存', () async {
    await library.store(book, chapters.first, content(chapters.first).content!);
    final deleting = library.deleteDownloadedBook(book);
    final writing = library.store(
      book,
      chapters[1],
      content(chapters[1]).content!,
    );
    final reading = library.read(book, chapters.first);
    final image = library.saveImage(book, 'local:image', Uint8List(1));
    final downloading = library.downloadChapters(book, [
      chapters[1],
    ], onProgress: (_, _) {});
    await Future.wait([
      expectLater(writing, throwsA(isA<SourceException>())),
      expectLater(reading, throwsA(isA<SourceException>())),
      expectLater(image, throwsA(isA<SourceException>())),
      expectLater(downloading, throwsA(isA<SourceException>())),
    ]);
    await deleting;
    await library.store(book, chapters.first, content(chapters.first).content!);
    expect((await library.downloadedBooks()).books.single.book.key, book.key);
  });

  test('删除前启动但仍在检查缓存的旧读取不会在删除后重新下载', () async {
    await library.store(book, chapters.first, content(chapters.first).content!);
    final delayed = DelayedCacheLibrary(root, fallback);
    addTearDown(delayed.dispose);
    final reading = delayed.read(book, chapters.first);
    await delayed.deleteDownloadedBook(book);
    delayed.pending.complete(null);
    await expectLater(reading, throwsA(isA<SourceException>()));
    expect(
      await Directory('${root.path}/${Library.safeKey(book.key)}').exists(),
      isFalse,
    );
  });

  test('异常缓存路径拒绝删除，不影响书库其他文件', () async {
    final file = File('${root.path}/${Library.safeKey(book.key)}');
    await file.writeAsString('保留的异常文件');
    final sentinel = File('${root.path}/index-sentinel');
    await sentinel.writeAsString('保留');
    await expectLater(
      library.deleteDownloadedBook(book),
      throwsA(isA<SourceException>()),
    );
    expect(await file.readAsString(), '保留的异常文件');
    expect(await sentinel.readAsString(), '保留');
  });
}
