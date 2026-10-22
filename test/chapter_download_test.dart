import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/chapter_batch_source.dart';
import 'package:unr/sources/novel_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late BatchSource source;
  late Library library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('unr-download-');
    source = BatchSource();
    final api = SfacgApi(
      client: MockClient((_) async => throw const SocketException('离线')),
    );
    addTearDown(api.close);
    library = Library(root, SfacgSource(api), novelSources: [source]);
  });
  tearDown(() => root.delete(recursive: true));

  test('书源明确限制访问后停止调度，保留并发批次已完成的成功与失败结果', () async {
    const restricted = SourceAccessRestrictedException('需要稍后重试', code: -4403);
    final gate = Completer<void>();
    source.fetch = (batch) async {
      if (batch.first.id == '1') {
        return [
          content(batch.first),
          ChapterBatchResult.failure(batch.last.id, restricted),
        ];
      }
      await gate.future;
      return batch.map(content).toList();
    };
    final completed = <String, Object?>{};
    final downloading = library.downloadChapters(
      book,
      chapters,
      onProgress: (chapter, error) {
        completed[chapter.id] = error;
      },
    );
    final check = expectLater(downloading, throwsA(same(restricted)));
    await until(() => completed.containsKey('2'));
    expect(source.calls.length, 2);
    gate.complete();
    await check;
    expect(source.calls.length, 2);
    expect(completed.keys, unorderedEquals(['1', '2', '3', '4']));
    expect(completed['2'], same(restricted));
    expect(
      (await library.cached(book, chapters.first))!.paragraphs.single.text,
      '正文 1',
    );
    expect(
      (await library.cached(book, chapters[2]))!.paragraphs.single.text,
      '正文 3',
    );
    expect(await library.cached(book, chapters.last), isNull);
  });

  test('按书源批量及并发上限调度，乱序响应仍对应原章节并可离线读取', () async {
    final gate = Completer<void>();
    var active = 0, maximum = 0;
    source.fetch = (batch) async {
      active++;
      if (active > maximum) maximum = active;
      await gate.future;
      active--;
      return batch.reversed.map(content).toList();
    };
    final completed = <String>[];
    final download = library.downloadChapters(
      book,
      chapters,
      onProgress: (chapter, error) {
        expect(error, isNull);
        completed.add(chapter.id);
      },
    );
    await until(() => source.calls.length == 2);
    expect(maximum, 2);
    expect(source.calls.map((batch) => batch.length), [2, 2]);
    gate.complete();
    await download;
    expect(source.calls.map((batch) => batch.length), [2, 2, 1]);
    expect(completed, unorderedEquals(chapters.map((chapter) => chapter.id)));
    for (final chapter in chapters) {
      expect(
        (await library.read(book, chapter)).paragraphs.single.text,
        '正文 ${chapter.id}',
      );
    }
  });

  test('重试跳过成功缓存，只重新请求缺失和失败章节', () async {
    source.chapterBatchConcurrency = 1;
    await library.store(book, chapters.first, content(chapters.first).content!);
    source.fetch = (batch) async => [
      for (final chapter in batch)
        if (chapter.id == '3')
          ChapterBatchResult.failure(chapter.id, const SourceException('无权限'))
        else if (chapter.id != '4')
          content(chapter),
    ];
    final failed = <String>[];
    await library.downloadChapters(
      book,
      chapters,
      onProgress: (chapter, error) {
        if (error != null) failed.add(chapter.id);
      },
    );
    expect(failed, ['3', '4']);
    expect(source.calls.expand((batch) => batch).map((c) => c.id), [
      '2',
      '3',
      '4',
      '5',
    ]);
    source.calls.clear();
    source.fetch = null;
    await library.downloadChapters(
      book,
      chapters,
      onProgress: (_, error) => expect(error, isNull),
    );
    expect(source.calls.expand((batch) => batch).map((c) => c.id), ['3', '4']);
  });

  test('下载与阅读共享同章在途请求，重复下载任务被拒绝且完成后释放', () async {
    final gate = Completer<void>();
    source.fetch = (batch) async {
      await gate.future;
      return batch.map(content).toList();
    };
    final download = library.downloadChapters(
      book,
      chapters.take(2).toList(),
      onProgress: (_, error) => expect(error, isNull),
    );
    await until(() => source.calls.isNotEmpty);
    final reading = library.read(book, chapters.first);
    await expectLater(
      library.downloadChapters(book, chapters, onProgress: (_, _) {}),
      throwsA(isA<SourceException>()),
    );
    gate.complete();
    await download;
    expect((await reading).paragraphs.single.text, '正文 1');
    await library.downloadChapters(
      book,
      chapters.take(2).toList(),
      onProgress: (_, _) {},
    );
    expect(source.calls.length, 1);
  });

  test('主动重取指定缓存章节，下载期间旧正文仍可阅读，正文与进度按成功结果保留', () async {
    source.chapterBatchConcurrency = 1;
    for (final chapter in chapters.take(3)) {
      await library.store(book, chapter, content(chapter).content!);
    }
    await library.add(book);
    library.pageOffsets[book.key] = 7;
    await library.remember(book, 0, 1);
    final gate = Completer<void>();
    source.fetch = (batch) async {
      await gate.future;
      return [
        for (final chapter in batch)
          ChapterBatchResult.success(
            chapter.id,
            ChapterContent([Paragraph('重取正文 ${chapter.id}', remoteIndex: 3)]),
          ),
      ];
    };
    final download = library.downloadChapters(
      book,
      chapters.take(2).toList(),
      refreshCached: true,
      onProgress: (_, error) => expect(error, isNull),
    );
    await until(() => source.calls.isNotEmpty);
    expect(
      (await library
              .read(book, chapters.first)
              .timeout(const Duration(seconds: 2)))
          .paragraphs
          .single
          .text,
      '正文 1',
    );
    gate.complete();
    await download;
    expect(source.calls.single.map((c) => c.id), ['1', '2']);
    expect(
      (await library.read(book, chapters.first)).paragraphs.single.remoteIndex,
      3,
    );
    expect(
      (await library.read(book, chapters[2])).paragraphs.single.text,
      '正文 3',
    );
    expect(library.progress[book.key], [0, 1]);
    expect(library.pageOffsets[book.key], 7);
    final restored = await Library.open(
      library.source,
      directory: root,
      novelSources: [source],
    );
    addTearDown(restored.dispose);
    expect(restored.progress[book.key], [0, 1]);
    expect(restored.pageOffsets[book.key], 7);
  });

  test('主动重取网络或插图失败均保留旧正文和进度，之后可再次重取', () async {
    final old = content(chapters.first).content!;
    await library.store(book, chapters.first, old);
    await library.remember(book, 0, 4);
    for (final withImage in [false, true]) {
      source.fetch = (batch) async {
        if (!withImage) throw const SocketException('离线');
        return [
          ChapterBatchResult.success(
            batch.single.id,
            const ChapterContent([
              Paragraph('不完整的新正文', remoteIndex: 1),
              Paragraph('', image: 'https://example.test/image.png'),
            ]),
          ),
        ];
      };
      Object? failure;
      await library.downloadChapters(
        book,
        [chapters.first],
        refreshCached: true,
        onProgress: (_, error) => failure = error,
      );
      expect(failure, isA<SocketException>());
      expect((await library.read(book, chapters.first)).toJson(), old.toJson());
      expect(library.progress[book.key], [0, 4]);
    }
    source.fetch = null;
    await library.downloadChapters(
      book,
      [chapters.first],
      refreshCached: true,
      onProgress: (_, error) => expect(error, isNull),
    );
    expect(library.progress[book.key], [0, 4]);
  });

  test('重取等待正在读取的旧请求写入完成，再请求新正文避免迟到覆盖', () async {
    final gate = Completer<ChapterContent>();
    source.singleRead = gate.future;
    final reading = library.read(book, chapters.first);
    await until(() => source.singleReadStarted);
    source.fetch = (batch) async => [
      ChapterBatchResult.success(
        batch.single.id,
        const ChapterContent([Paragraph('重取后的正文', remoteIndex: 3)]),
      ),
    ];
    final refreshing = library.downloadChapters(
      book,
      [chapters.first],
      refreshCached: true,
      onProgress: (_, error) => expect(error, isNull),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(source.calls, isEmpty);
    gate.complete(const ChapterContent([Paragraph('旧请求正文')]));
    expect((await reading).paragraphs.single.text, '旧请求正文');
    await refreshing;
    expect(
      (await library.read(book, chapters.first)).paragraphs.single.text,
      '重取后的正文',
    );
    expect(source.calls.length, 1);
  });

  test('停止后只完成在途批次，继续下载复用已落盘章节', () async {
    source.chapterBatchConcurrency = 1;
    var cancelled = false, done = 0;
    await library.downloadChapters(
      book,
      chapters,
      isCancelled: () => cancelled,
      onProgress: (_, error) {
        expect(error, isNull);
        done++;
        cancelled = true;
      },
    );
    expect(done, 2);
    expect(source.calls.length, 1);
    expect((await library.cachedContents(book)).length, 2);
    await library.downloadChapters(book, chapters, onProgress: (_, _) {});
    expect((await library.cachedContents(book)).length, 5);
    expect(source.calls.skip(1).expand((batch) => batch).map((c) => c.id), [
      '3',
      '4',
      '5',
    ]);
  });

  test('拒绝重复或其他章节的批量响应，不污染缓存，失败后可重试', () async {
    source.chapterBatchConcurrency = 1;
    for (final invalid in [
      [content(chapters.first), content(chapters.first)],
      [content(chapters.last)],
    ]) {
      source.fetch = (_) async => invalid;
      var failed = 0;
      await library.downloadChapters(
        book,
        chapters.take(2).toList(),
        onProgress: (_, error) {
          expect(error, isA<SourceException>());
          failed++;
        },
      );
      expect(failed, 2);
      expect(await library.cachedContents(book), isEmpty);
    }
    source.fetch = (_) async => throw const SocketException('离线');
    await library.downloadChapters(
      book,
      chapters.take(2).toList(),
      onProgress: (_, error) => expect(error, isNotNull),
    );
    source.fetch = null;
    await library.downloadChapters(
      book,
      chapters,
      onProgress: (_, error) => expect(error, isNull),
    );
    expect((await library.cachedContents(book)).length, 5);
  });

  test('插图失败不会标记下载成功，正文缓存保留供离线阅读及补图重试', () async {
    source.fetch = (batch) async => [
      ChapterBatchResult.success(
        batch.single.id,
        const ChapterContent([
          Paragraph('带图正文'),
          Paragraph('', image: 'https://example.com/image.png'),
        ]),
      ),
    ];
    Object? failure;
    await library.downloadChapters(book, [
      chapters.first,
    ], onProgress: (_, error) => failure = error);
    expect(failure, isA<SocketException>());
    expect(
      (await library.cached(book, chapters.first))!.paragraphs.first.text,
      '带图正文',
    );
    await library.downloadChapters(book, [
      chapters.first,
    ], onProgress: (_, error) => expect(error, isNotNull));
    expect(source.calls.length, 1);
  });
}
