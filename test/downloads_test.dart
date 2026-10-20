import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/data/download_queue.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/book_page.dart';
import 'package:unr/ui/downloads.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/reading_taps.dart';

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

class DownloadsLibrary extends Library {
  DownloadsLibrary() : super(Directory.systemTemp, offlineSource());
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
  Future<void> save() async => notifyListeners();
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async {
    reads.add(chapter.id);
    return content;
  }

  @override
  Future<ChapterContent?> cached(Book book, Chapter chapter) async => null;
  @override
  Future<Set<String>> cachedChapterIds(Book book) async =>
      (await cachedContents(book)).keys.toSet();
  @override
  Future<Map<String, ChapterContent>> cachedContents(Book book) async => {};
}

SfacgSource offlineSource() => SfacgSource(
  SfacgApi(client: MockClient((_) async => throw StateError('不应访问网络'))),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('下载按真实章节文件计数、跨书源隔离，脱离书架和阅读历史后仍可恢复', () async {
    final root = await Directory.systemTemp.createTemp('unr-downloaded-');
    addTearDown(() => root.delete(recursive: true));
    final source = offlineSource();
    addTearDown(source.api.close);
    final library = Library(root, source);
    addTearDown(library.dispose);
    final partial = sample('1'), complete = sample('1', source: 'fanqie');
    await library.add(partial);
    await library.recordReading(partial);
    await library.store(partial, chapters[1], content);
    await Future.wait([
      for (final chapter in chapters) library.store(complete, chapter, content),
    ]);
    await library.add(sample('no-cache'));
    await library.removeFromShelf(partial);
    await library.removeFromShelf(partial, shelfId: Library.recentShelfId);
    final restored = await Library.open(source, directory: root);
    addTearDown(restored.dispose);
    final snapshot = await restored.downloadedBooks();
    expect(snapshot.unreadable, 0);
    final byKey = {for (final entry in snapshot.books) entry.book.key: entry};
    expect(byKey.keys, unorderedEquals(['sfacg:1', 'fanqie:1']));
    expect(byKey['sfacg:1']!.chapterIds, {'2'});
    expect(byKey['fanqie:1']!.chapterIds, {'1', '2', '3'});
    expect(restored.books.single.id, 'no-cache');
    expect(restored.recentBooks, isEmpty);
    expect(
      (await restored.read(partial, chapters[1])).paragraphs.single.text,
      '已保存的正文',
    );
    await File(
      '${root.path}/${Library.safeKey(complete.key)}/${Library.safeKey('3')}.json',
    ).delete();
    final refreshed = await restored.downloadedBooks();
    expect(
      refreshed.books.firstWhere((e) => e.book.key == complete.key).chapterIds,
      {'1', '2'},
    );
  });

  test('兼容旧版缓存、最近阅读和本地导入，忽略封面与临时文件，保留完整目录', () async {
    final root = await Directory.systemTemp.createTemp('unr-old-downloaded-');
    addTearDown(() => root.delete(recursive: true));
    final source = offlineSource();
    addTearDown(source.api.close);
    final library = Library(root, source);
    addTearDown(library.dispose);
    final legacy = sample('legacy'), local = sample('local', source: 'local');
    library.books.addAll([legacy, sample('image-only')]);
    library.recentBooks.addAll([legacy, local]);
    Future<void> write(Book book, String name, String data) async {
      final file = File('${root.path}/${Library.safeKey(book.key)}/$name');
      await file.parent.create(recursive: true);
      await file.writeAsString(data);
    }

    for (final book in [legacy, local]) {
      await write(
        book,
        '${Library.safeKey('1')}.json',
        jsonEncode(content.toJson()),
      );
      await write(book, '${Library.safeKey('2')}.json.tmp', '未完成');
    }
    await write(sample('image-only'), 'images/cover', '封面');
    expect((await library.downloadedBooks()).books.length, 2);
    // Once discovered, old caches also remain discoverable without the index.
    library.books.clear();
    library.recentBooks.clear();
    final preview = legacy.withChapters([]);
    library.books.add(preview);
    final snapshot = await library.downloadedBooks();
    expect(snapshot.unreadable, 0);
    expect(snapshot.books.length, 2);
    expect(
      snapshot.books
          .firstWhere((e) => e.book.key == legacy.key)
          .book
          .chapters
          .length,
      3,
    );
    expect(snapshot.books.every((e) => e.chapterIds.length == 1), isTrue);
  });

  test('损坏或错位的下载记录不妨碍其他书籍，元数据未落盘时可重试', () async {
    final root = await Directory.systemTemp.createTemp('unr-bad-downloaded-');
    addTearDown(() => root.delete(recursive: true));
    final source = offlineSource();
    addTearDown(source.api.close);
    final library = Library(root, source);
    addTearDown(library.dispose);
    final book = sample('good');
    final file = File('${root.path}/${Library.safeKey(book.key)}/book.json');
    await file.create(recursive: true);
    // An unwritable metadata target must not leave a permanently failed future.
    await file.delete();
    final blocker = Directory(file.path);
    await blocker.create();
    await expectLater(
      library.store(book, chapters.first, content),
      throwsA(isA<FileSystemException>()),
    );
    await blocker.delete();
    await library.store(book, chapters.first, content);
    for (final (name, text) in [
      ('broken', '{'),
      ('wrong-directory', jsonEncode(book.toJson())),
    ]) {
      final bad = File('${root.path}/$name/book.json');
      await bad.create(recursive: true);
      await bad.writeAsString(text);
    }
    final snapshot = await library.downloadedBooks();
    expect(snapshot.books.single.book.key, book.key);
    expect(snapshot.unreadable, 2);
  });

  DownloadsLibrary memoryLibrary() {
    final library = DownloadsLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    return library;
  }

  testWidgets('从我的进入下载，可离线打开部分下载章节、恢复进度并逐级返回', (tester) async {
    final library = memoryLibrary();
    final book = sample('1');
    library.snapshot = DownloadedBooksSnapshot(
      books: [
        DownloadedBook(book: book, chapterIds: {'2'}),
      ],
    );
    library.progress[book.key] = [0, 0];
    await tester.pumpWidget(UnrApp(library: library));
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('my-downloads-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadsPage), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('已下载 1 / 3 章 · 部分下载'), findsOneWidget);
    final card = find.byKey(ValueKey('downloaded-book-${book.key}'));
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ReaderPage>(find.byType(ReaderPage)).initialChapter,
      1,
    );
    expect(library.reads.first, '2');
    await showReadingControls(tester);
    await tester.tap(find.byType(BackButton).hitTestable());
    await tester.pumpAndSettle();
    // With a cached saved chapter, ReaderPage restores the saved paragraph too.
    library.progress[book.key] = [1, 0];
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ReaderPage>(find.byType(ReaderPage)).initialChapter,
      isNull,
    );
    await showReadingControls(tester);
    await tester.tap(find.byType(BackButton).hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('作品详情'));
    await tester.pumpAndSettle();
    expect(find.byType(BookPage), findsOneWidget);
    await tester.tap(find.byType(BackButton).hitTestable());
    await tester.pumpAndSettle();
    expect(library.loads, greaterThanOrEqualTo(4));
    await tester.tap(find.byType(BackButton).hitTestable());
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
    expect(library.books, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('加载、空列表、失败重试及离开后的异步结果均正常处理', (tester) async {
    final library = memoryLibrary()
      ..pending = Completer<DownloadedBooksSnapshot>();
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(library: library)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    library.pending!.complete(const DownloadedBooksSnapshot(books: []));
    library.pending = null;
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无已下载的书籍'), findsOneWidget);
    library.fail = true;
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('下载记录加载失败，请重试。'), findsOneWidget);
    library.fail = false;
    library.snapshot = DownloadedBooksSnapshot(
      books: [
        DownloadedBook(book: sample('1'), chapterIds: {'1', '2', '3'}),
      ],
      unreadable: 1,
    );
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('已下载 3 / 3 章 · 已全部下载'), findsOneWidget);
    expect(find.text('1 条下载记录读取失败，可刷新重试。'), findsOneWidget);
    library.pending = Completer<DownloadedBooksSnapshot>();
    await tester.tap(find.byTooltip('刷新下载记录'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    library.pending!.complete(library.snapshot);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按进入多选，点击仅切换勾选，可全选及退出选择', (tester) async {
    final library = memoryLibrary();
    library.snapshot = DownloadedBooksSnapshot(
      books: [
        for (final id in ['1', '2'])
          DownloadedBook(book: sample(id), chapterIds: {'1'}),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(library: library)));
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('downloaded-book-sfacg:1'));
    final second = find.byKey(const ValueKey('downloaded-book-sfacg:2'));
    expect(find.byType(Checkbox), findsNothing);
    await tester.longPress(first);
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text('已选 1 本'), findsOneWidget);
    await tester.tap(second);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 本'), findsOneWidget);
    expect(find.byType(ReaderPage), findsNothing);
    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 本'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('download-selected')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 本'), findsOneWidget);
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    await tester.longPress(first);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(DownloadsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('页面销毁后不继续删除其他书籍或更新界面', (tester) async {
    final library = memoryLibrary();
    library.snapshot = DownloadedBooksSnapshot(
      books: [
        for (final id in ['1', '2'])
          DownloadedBook(book: sample(id), chapterIds: {'1'}),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(library: library)));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('downloaded-book-sfacg:1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-selected')));
    await tester.pumpAndSettle();
    library.pendingDelete = Completer<void>();
    await tester.tap(find.text('删除下载'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    library.pendingDelete!.complete();
    await tester.pumpAndSettle();
    expect(library.deleted, ['sfacg:1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('页面销毁后批量下载继续并自动开始后续书籍', (tester) async {
    final library = memoryLibrary();
    library.snapshot = DownloadedBooksSnapshot(
      books: [
        for (final id in ['1', '2'])
          DownloadedBook(book: sample(id), chapterIds: {'1'}),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(library: library)));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('downloaded-book-sfacg:1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    library.pendingDownload = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('download-selected')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    library.pendingDownload!.complete();
    await tester.pumpAndSettle();
    expect(library.downloadCalls, ['sfacg:1', 'sfacg:2']);
    expect(
      library.downloadQueue.tasks.every(
        (task) => task.state == DownloadTaskState.completed,
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量删除需确认，提示本地书籍，失败项保留勾选并可重试', (tester) async {
    final library = memoryLibrary();
    final first = sample('1'), local = sample('1', source: 'local');
    library.snapshot = DownloadedBooksSnapshot(
      books: [
        DownloadedBook(book: first, chapterIds: {'1'}),
        DownloadedBook(book: local, chapterIds: {'1'}),
      ],
    );
    library.deleteFailures.add(local.key);
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(library: library)));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(ValueKey('downloaded-book-${first.key}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('downloaded-book-${local.key}')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('download-selected')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('delete-selected')));
    await tester.pumpAndSettle();
    expect(find.textContaining('需重新导入原文件'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(library.deleted, isEmpty);
    await tester.tap(find.byKey(const ValueKey('delete-selected')));
    await tester.pumpAndSettle();
    library.pendingDelete = Completer<void>();
    await tester.tap(find.text('删除下载'));
    await tester.pumpAndSettle();
    expect(find.text('正在删除本地下载…'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('delete-selected')))
          .onPressed,
      isNull,
    );
    library.pendingDelete!.complete();
    library.pendingDelete = null;
    await tester.pumpAndSettle();
    expect(find.text('已删除 1 本，1 本删除失败'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('downloaded-book-${first.key}')), findsNothing);
    expect(find.text('已选 1 本'), findsOneWidget);
    library.deleteFailures.clear();
    await tester.tap(find.byKey(const ValueKey('delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除下载'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无已下载的书籍'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量下载仅处理勾选书籍，停止当前任务后自动接续排队任务', (tester) async {
    final library = memoryLibrary();
    library.snapshot = DownloadedBooksSnapshot(
      books: [
        for (final id in ['1', '2', '3'])
          DownloadedBook(book: sample(id), chapterIds: {'1'}),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(library: library)));
    await tester.pumpAndSettle();
    Future<void> select() async {
      await tester.longPress(
        find.byKey(const ValueKey('downloaded-book-sfacg:1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('downloaded-book-sfacg:2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('download-selected')));
      await tester.pumpAndSettle();
    }

    library.pendingDownload = Completer<void>();
    await select();
    expect(library.downloadCalls, ['sfacg:1']);
    expect(find.text('排队中 · 第 1 位 · 0 / 3 章'), findsOneWidget);
    await tester.tap(find.text('停止下载'));
    await tester.pumpAndSettle();
    library.pendingDownload!.complete();
    library.pendingDownload = null;
    await tester.pumpAndSettle();
    expect(find.text('已停止 · 0 / 3 章'), findsOneWidget);
    expect(library.downloadCalls, ['sfacg:1', 'sfacg:2']);
    await tester.tap(find.text('移除记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无下载任务'), findsOneWidget);
    await tester.tap(find.text('已下载'));
    await tester.pumpAndSettle();
    library.downloadCalls.clear();
    library.failChapter = true;
    await select();
    expect(library.downloadCalls, ['sfacg:1', 'sfacg:2']);
    expect(find.text('成功 2 章，失败 1 章'), findsNWidgets(2));
    expect(find.textContaining('章节无权限'), findsNWidgets(2));
    await tester.tap(find.text('已下载'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单本下载任务失败后继续其他勾选书籍，不自动重发失败任务', (tester) async {
    final library = memoryLibrary();
    library.snapshot = DownloadedBooksSnapshot(
      books: [
        for (final id in ['1', '2'])
          DownloadedBook(book: sample(id), chapterIds: {'1'}),
      ],
    );
    library.downloadFailures.add('sfacg:1');
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(library: library)));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('downloaded-book-sfacg:1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-selected')));
    await tester.pumpAndSettle();
    expect(library.downloadCalls, ['sfacg:1', 'sfacg:2']);
    expect(library.downloadQueue.tasks.map((task) => task.state), [
      DownloadTaskState.failed,
      DownloadTaskState.completed,
    ]);
    expect(find.textContaining('下载任务失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [320.0, 1400.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('下载列表长书名布局（宽$width，缩放$scale）', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final library = memoryLibrary();
        library.snapshot = DownloadedBooksSnapshot(
          books: [
            DownloadedBook(
              book: sample('1', title: '这是一本很长很长的书名需要换行显示也不能导致手机和宽屏布局溢出'),
              chapterIds: {'1'},
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: DownloadsPage(library: library),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('downloaded-book-sfacg:1')),
          findsOneWidget,
        );
        await tester.longPress(
          find.byKey(const ValueKey('downloaded-book-sfacg:1')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Checkbox), findsOneWidget);
        expect(find.byKey(const ValueKey('download-selected')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
