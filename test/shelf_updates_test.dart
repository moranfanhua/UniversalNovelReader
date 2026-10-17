import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/bookshelf.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/novel_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/reader.dart';

Book sample(String id, {String source = 'sfacg', bool updated = false}) => Book(
  id: id,
  source: source,
  title: '作品$id',
  author: '作者',
  chapters: [
    const Chapter(id: 'first', title: '第一章'),
    if (updated) const Chapter(id: 'new', title: '新增章节'),
  ],
);

class UpdateSource extends SfacgSource {
  UpdateSource() : super(SfacgApi());
  final calls = <String>[];
  Future<Book> Function(String)? load;
  @override
  Future<Book> getBook(String input) async {
    calls.add(input);
    return load == null ? sample(input, updated: true) : load!(input);
  }
}

class OtherUpdateSource implements NovelSource {
  final calls = <String>[];
  @override
  String get id => 'other';
  @override
  String get name => '其他书源';
  @override
  Future<Book> getBook(String input) async {
    calls.add(input);
    return sample(input, source: id, updated: true);
  }

  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async =>
      const ChapterContent([Paragraph('测试正文')]);
}

class UpdateLibrary extends Library {
  UpdateLibrary(super.root, super.source, {super.clock, super.novelSources});
  bool failSave = false;
  int saves = 0;
  @override
  Future<void> save() async {
    saves++;
    if (failSave) throw const FileSystemException('保存失败');
    notifyListeners();
  }

  @override
  Future<Map<String, ChapterContent>> cachedContents(Book book) async => {};
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      const ChapterContent([Paragraph('测试正文')]);
}

void main() {
  late UpdateSource source;
  late DateTime now;
  setUp(() {
    source = UpdateSource();
    now = DateTime.utc(2026, 10, 18);
  });
  tearDown(() => source.api.close());

  UpdateLibrary memory({Iterable<NovelSource> sources = const []}) {
    final library = UpdateLibrary(
      Directory.systemTemp,
      source,
      clock: () => now,
      novelSources: sources,
    );
    addTearDown(library.dispose);
    return library;
  }

  test('更新目录和信息，保留缓存、书架与按章节标识恢复的阅读位置，重开仍限频', () async {
    final root = await Directory.systemTemp.createTemp('unr-shelf-updates-');
    addTearDown(() => root.delete(recursive: true));
    final library = await Library.open(
      source,
      directory: root,
      clock: () => now,
    );
    addTearDown(library.dispose);
    final original = sample('1');
    await library.add(original);
    library.recentBooks.add(original);
    library.shelves.add(
      Bookshelf(
        id: 'shelf',
        name: '收藏',
        source: source.id,
        remoteId: 'remote',
        bookKeys: [original.key],
      ),
    );
    library.progress[original.key] = [0, 7];
    library.pageOffsets[original.key] = 12;
    library.pagedChapterEntries['${original.key}:0'] = [1, 3, 9];
    await library.setBookPinned(original, true);
    const content = ChapterContent([Paragraph('原正文')]);
    await library.store(original, original.chapters.first, content);
    final activeTime = library.lastActiveTimes[original.key];
    source.load = (id) async => Book(
      id: id,
      title: '更新后的书名',
      author: '作者',
      updatedAt: now,
      chapters: const [
        Chapter(id: 'preface', title: '新序章'),
        Chapter(id: 'first', title: '第一章'),
        Chapter(id: 'new', title: '新增章节'),
      ],
    );
    final result = await library.refreshShelfBooks(isCancelled: () => false);
    expect(result.checked, 1);
    expect(result.failed, 0);
    expect(library.books.single.chapters.length, 3);
    expect(library.recentBooks.single.title, '更新后的书名');
    expect(library.progress[original.key], [1, 7]);
    expect(library.pageOffsets[original.key], 12);
    expect(library.pagedChapterEntries['${original.key}:1'], [1, 3, 9]);
    expect(
      library.pagedChapterEntries.containsKey('${original.key}:0'),
      isFalse,
    );
    expect(library.lastActiveTimes[original.key], activeTime);
    expect(library.isBookPinned(original), isTrue);
    expect(library.shelves.single.bookKeys, [original.key]);
    expect(
      (await library.cached(
        original,
        original.chapters.first,
      ))!.paragraphs.single.text,
      '原正文',
    );

    final reopened = await Library.open(
      source,
      directory: root,
      clock: () => now,
    );
    addTearDown(reopened.dispose);
    now = now.add(const Duration(minutes: 9, seconds: 59));
    expect(
      (await reopened.refreshShelfBooks(
        shelfId: 'shelf',
        isCancelled: () => false,
      )).checked,
      0,
    );
    expect(source.calls, ['1']);
    now = now.add(const Duration(seconds: 1));
    expect(
      (await reopened.refreshShelfBooks(isCancelled: () => false)).checked,
      1,
    );
    expect(source.calls, ['1', '1']);
  });

  test('仅更新当前书架，跨书架共用间隔，跨平台相同 ID 和本地作品互不影响', () async {
    final other = OtherUpdateSource();
    final library = memory(sources: [other]);
    library.books.addAll([
      sample('1'),
      sample('2'),
      sample('1', source: 'other'),
      sample('1', source: 'local'),
    ]);
    library.shelves.add(
      const Bookshelf(
        id: 'shelf',
        name: '收藏',
        source: 'sfacg',
        remoteId: 'remote',
        bookKeys: ['sfacg:1'],
      ),
    );
    await library.refreshShelfBooks(shelfId: 'shelf', isCancelled: () => false);
    expect(source.calls, ['1']);
    expect(other.calls, isEmpty);
    await library.refreshShelfBooks(isCancelled: () => false);
    expect(source.calls, ['1', '2']);
    expect(other.calls, ['1']);
    expect(library.books.last.chapters.length, 1);
    await library.refreshShelfBooks(
      shelfId: 'removed-shelf',
      isCancelled: () => false,
    );
    expect(source.calls, ['1', '2']);
  });

  test('失败不影响其他作品且重开后十分钟内不重发，错误作品或空目录不会覆盖旧数据', () async {
    final root = await Directory.systemTemp.createTemp('unr-shelf-failures-');
    addTearDown(() => root.delete(recursive: true));
    final library = await Library.open(
      source,
      directory: root,
      clock: () => now,
    );
    addTearDown(library.dispose);
    for (final id in ['1', '2', '3', '4']) {
      await library.add(sample(id));
    }
    source.load = (id) async => switch (id) {
      '1' => throw const SourceException('暂时失败'),
      '2' => sample('2', source: 'other'),
      '3' => const Book(id: '3', title: '空目录', author: '', chapters: []),
      _ => sample(id, updated: true),
    };
    final result = await library.refreshShelfBooks(isCancelled: () => false);
    expect(result.checked, 4);
    expect(result.failed, 3);
    expect(
      library.books
          .where((b) => b.id != '4')
          .every((b) => b.chapters.length == 1),
      isTrue,
    );
    expect(library.books.first.chapters.length, 2);
    final reopened = await Library.open(
      source,
      directory: root,
      clock: () => now,
    );
    addTearDown(reopened.dispose);
    expect(
      (await reopened.refreshShelfBooks(isCancelled: () => false)).checked,
      0,
    );
    expect(source.calls.length, 4);
    now = now.add(const Duration(minutes: 10));
    await reopened.refreshShelfBooks(isCancelled: () => false);
    expect(source.calls.length, 8);
  });

  test('最多并发三本，重复访问不重复请求，取消后不应用结果或开始下一批', () async {
    final library = memory();
    library.books.addAll([for (var i = 0; i < 5; i++) sample('$i')]);
    final pending = <String, Completer<Book>>{};
    final started = Completer<void>();
    source.load = (id) {
      final value = pending[id] = Completer<Book>();
      if (pending.length == 3) started.complete();
      return value.future;
    };
    var cancelled = false;
    final first = library.refreshShelfBooks(isCancelled: () => cancelled);
    final duplicate = library.refreshShelfBooks(isCancelled: () => true);
    await started.future;
    expect(source.calls.length, 3);
    cancelled = true;
    for (final entry in pending.entries) {
      entry.value.complete(sample(entry.key, updated: true));
    }
    await Future.wait([first, duplicate]);
    expect(source.calls.length, 3);
    expect(library.books.every((book) => book.chapters.length == 1), isTrue);
    source.load = null;
    final remaining = await library.refreshShelfBooks(isCancelled: () => false);
    expect(remaining.checked, 2);
    expect(source.calls.length, 5);
  });

  test('迟到的结果不覆盖已更新或已移除作品，保存失败回滚目录与进度', () async {
    final library = memory()..books.add(sample('1'));
    final pending = Completer<Book>(), started = Completer<void>();
    source.load = (id) {
      started.complete();
      return pending.future;
    };
    final updating = library.refreshShelfBooks(isCancelled: () => false);
    await started.future;
    final manual = sample('1');
    await library.updateBook(manual);
    pending.complete(sample('1', updated: true));
    await updating;
    expect(library.books.single, same(manual));
    library.progress[manual.key] = [0, 7];
    library.pagedChapterEntries['${manual.key}:0'] = [1, 0, 0];
    library.failSave = true;
    final changed = Book(
      id: '1',
      title: '新目录',
      author: '',
      chapters: [
        const Chapter(id: 'new', title: '序章'),
        ...manual.chapters,
      ],
    );
    await expectLater(
      library.updateBook(changed, preserveChapterPosition: true),
      throwsA(isA<FileSystemException>()),
    );
    expect(library.books.single, same(manual));
    expect(library.progress[manual.key], [0, 7]);
    expect(library.pagedChapterEntries, {
      '${manual.key}:0': [1, 0, 0],
    });
  });

  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  testWidgets('首次进入、切回书库、返回阅读页和恢复前台均检查，十分钟内不重发', (tester) async {
    tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
        ? const Size(1400, 900)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = memory()..books.add(sample('1'));
    await tester.pumpWidget(UnrApp(library: library));
    await tester.pumpAndSettle();
    expect(source.calls, ['1']);
    await tester.tap(find.text('书源'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书库'));
    await tester.pumpAndSettle();
    expect(source.calls, ['1']);
    now = now.add(const Duration(minutes: 10));
    await tester.tap(find.byKey(const ValueKey('shelf-book-sfacg:1')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(ReaderPage))).pop();
    await tester.pumpAndSettle();
    expect(source.calls, ['1', '1']);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    now = now.add(const Duration(minutes: 10));
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(source.calls, ['1', '1', '1']);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('刷新不阻塞打开本地目录，离开或销毁后忽略迟到结果', (tester) async {
    final library = memory()..books.add(sample('1'));
    final pending = Completer<Book>();
    source.load = (_) => pending.future;
    await tester.pumpWidget(UnrApp(library: library));
    await tester.pump();
    expect(source.calls, ['1']);
    await tester.tap(find.byKey(const ValueKey('shelf-book-sfacg:1')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsOneWidget);
    pending.complete(sample('1', updated: true));
    await tester.pumpAndSettle();
    expect(library.books.single.chapters.length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
