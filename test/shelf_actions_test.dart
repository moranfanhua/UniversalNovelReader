import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/bookshelf.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'helpers/memory_library.dart';
import 'helpers/viewport.dart';

const a = Book(
  id: '1',
  title: 'Alpha',
  author: '作者',
  chapters: [Chapter(id: '1', title: '第一章')],
);
const b = Book(
  id: '2',
  title: 'Beta',
  author: '作者',
  chapters: [Chapter(id: '1', title: '第一章')],
);
const other = Book(
  id: '1',
  source: 'fanqie',
  title: '同 ID 其他平台',
  author: '作者',
  chapters: [Chapter(id: '1', title: '第一章')],
);
const shelf = Bookshelf(
  id: 'custom',
  name: '我的收藏',
  source: 'sfacg',
  remoteId: 'remote',
  bookKeys: ['sfacg:1', 'sfacg:2'],
);

class ActionsLibrary extends TestLibrary with MemoryPersistence {
  @override
  Future<void> saveShelfUpdateTimes() => save();
}

void main() {
  test('置顶优先于三种排序，取消后恢复原序，最近阅读保持原有容量和记录顺序', () async {
    final library = useLibrary(ActionsLibrary());
    library.books.addAll([a, b, other]);
    library.recentBooks.addAll([a, b, other]);
    library.lastActiveTimes.addAll({a.key: 3, b.key: 2, other.key: 1});
    library.updatedTimes.addAll({a.key: 3, b.key: 2, other.key: 1});
    for (final sort in ShelfSort.values) {
      await library.setShelfSort(sort);
      final original = library.sortedBooks.map((book) => book.key).toList();
      await library.setBookPinned(b, true);
      expect(library.sortedBooks.first.key, b.key);
      expect(
        library.sortedBooks.skip(1).map((book) => book.key),
        original.where((key) => key != b.key),
      );
      expect(library.sortedRecentBooks.map((book) => book.key), [
        b.key,
        a.key,
        other.key,
      ]);
      expect(library.recentBooks.map((book) => book.key), [
        a.key,
        b.key,
        other.key,
      ]);
      await library.setBookPinned(b, false);
      expect(library.sortedBooks.map((book) => book.key), original);
      expect(library.sortedRecentBooks.map((book) => book.key), [
        a.key,
        b.key,
        other.key,
      ]);
    }
    await library.setBookPinned(a, true);
    expect(library.isBookPinned(other), isFalse);
  });

  test('置顶和移除持久化，旧书库默认不置顶，移除保留跨平台作品、缓存与进度', () async {
    final root = await Directory.systemTemp.createTemp('unr-shelf-actions-');
    addTearDown(() => root.delete(recursive: true));
    final source = SfacgSource(SfacgApi());
    addTearDown(source.api.close);
    await File('${root.path}/index.json').writeAsString(
      jsonEncode({
        'books': [a.toJson(), b.toJson(), other.toJson()],
      }),
    );
    Future<Library> open() async {
      final value = await Library.open(source, directory: root);
      addTearDown(value.dispose);
      return value;
    }

    final library = await open();
    expect(library.isBookPinned(a), isFalse);
    library.shelves.add(shelf);
    await library.store(
      a,
      a.chapters.single,
      const ChapterContent([Paragraph('缓存正文')]),
    );
    await library.remember(a, 0, 3);
    library.pageOffsets[a.key] = 42;
    await library.recordReading(a);
    await library.setBookPinned(a, true);
    expect((await open()).isBookPinned(a), isTrue);
    await library.removeFromShelf(a);
    final restored = await open();
    expect(restored.books.map((book) => book.key), [b.key, other.key]);
    expect(restored.shelves.single.bookKeys, [b.key]);
    expect(restored.recentBooks.single.key, a.key);
    expect(restored.isBookPinned(a), isTrue);
    expect(restored.progress[a.key], [0, 3]);
    expect(restored.pageOffsets[a.key], 42);
    expect(
      (await restored.cached(a, a.chapters.single))!.paragraphs.single.text,
      '缓存正文',
    );
    await restored.removeFromShelf(a, shelfId: Library.recentShelfId);
    final removedRecent = await open();
    expect(removedRecent.recentBooks, isEmpty);
    expect(removedRecent.isBookPinned(a), isFalse);
    expect(removedRecent.progress[a.key], [0, 3]);
    expect(
      (await removedRecent.cached(
        a,
        a.chapters.single,
      ))!.paragraphs.single.text,
      '缓存正文',
    );
  });

  test('命名书架和最近阅读的移除仅影响当前书架，置顶最近作品不自动加入书架', () async {
    final library = useLibrary(ActionsLibrary());
    library.books.addAll([a, b]);
    library.recentBooks.addAll([a, b, other]);
    library.shelves.addAll([
      shelf,
      const Bookshelf(
        id: 'second',
        name: '其他收藏',
        source: 'sfacg',
        remoteId: 'remote2',
        bookKeys: ['sfacg:1'],
      ),
    ]);
    await library.removeFromShelf(a, shelfId: shelf.id);
    expect(library.shelves.first.bookKeys, [b.key]);
    expect(library.shelves.last.bookKeys, [a.key]);
    expect(library.books, [a, b]);
    expect(library.recentBooks, [a, b, other]);
    await library.setBookPinned(other, true);
    expect(library.books, [a, b]);
    expect(library.sortedRecentBooks.first.key, other.key);
    await library.removeFromShelf(a, shelfId: Library.recentShelfId);
    expect(library.recentBooks, [b, other]);
    expect(library.books, [a, b]);
    expect(library.shelves.last.bookKeys, [a.key]);
  });

  test('置顶和三种移除保存失败均回滚，不丢失原有书架成员或最近记录', () async {
    final library = useLibrary(ActionsLibrary());
    library.books.addAll([a, b]);
    library.recentBooks.addAll([a, b]);
    library.shelves.add(shelf);
    library.failSave = true;
    await expectLater(
      library.setBookPinned(a, true),
      throwsA(isA<FileSystemException>()),
    );
    expect(library.isBookPinned(a), isFalse);
    library.failSave = false;
    await library.setBookPinned(a, true);
    library.failSave = true;
    await expectLater(
      library.setBookPinned(a, false),
      throwsA(isA<FileSystemException>()),
    );
    for (final id in [null, shelf.id, Library.recentShelfId]) {
      await expectLater(
        library.removeFromShelf(a, shelfId: id),
        throwsA(isA<FileSystemException>()),
      );
      expect(library.books, [a, b]);
      expect(library.recentBooks, [a, b]);
      expect(library.shelves.single.bookKeys, [a.key, b.key]);
      expect(library.isBookPinned(a), isTrue);
    }
  });

  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  void viewport(WidgetTester tester) {
    setTestViewport(
      tester,
      defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1400, 900)
          : const Size(390, 844),
    );
  }

  Future<void> action(WidgetTester tester, Book book, String label) async {
    await tester.longPress(find.byKey(ValueKey('shelf-book-${book.key}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('bookshelf-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  for (final layout in ShelfLayout.values) {
    testWidgets('长按底栏置顶、取消和移除立即生效（${layout.name}）', (tester) async {
      viewport(tester);
      final library = useLibrary(ActionsLibrary()..shelfLayout = layout);
      library.books.addAll([a, b]);
      await tester.pumpWidget(UnrApp(library: library));
      await tester.pumpAndSettle();
      List<Key?> order() => tester
          .widgetList<InkWell>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is InkWell &&
                  widget.key.toString().contains('shelf-book-'),
            ),
          )
          .map((widget) => widget.key)
          .toList();
      expect(order().first, ValueKey('shelf-book-${a.key}'));
      library.failSave = true;
      await action(tester, b, '置顶');
      expect(library.isBookPinned(b), isFalse);
      expect(find.textContaining('书架操作失败'), findsOneWidget);
      library.failSave = false;
      await action(tester, b, '置顶');
      expect(order().first, ValueKey('shelf-book-${b.key}'));
      expect(find.byTooltip('已置顶'), findsOneWidget);
      await action(tester, b, '取消置顶');
      expect(order().first, ValueKey('shelf-book-${a.key}'));
      expect(find.byTooltip('已置顶'), findsNothing);
      library.failSave = true;
      await action(tester, b, '移除');
      expect(library.isOnShelf(b), isTrue);
      library.failSave = false;
      await action(tester, b, '移除');
      expect(find.byKey(ValueKey('shelf-book-${b.key}')), findsNothing);
      expect(library.books, [a]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: platforms);
  }

  testWidgets('底栏移除只影响选中的命名书架或最近阅读', (tester) async {
    viewport(tester);
    final library = useLibrary(ActionsLibrary());
    library.books.addAll([a, b]);
    library.recentBooks.addAll([a, b]);
    library.shelves.add(shelf);
    await tester.pumpWidget(UnrApp(library: library));
    await tester.pumpAndSettle();
    await select(tester, '我的收藏（2）');
    await action(tester, a, '移除');
    expect(find.byKey(ValueKey('shelf-book-${a.key}')), findsNothing);
    expect(library.books, [a, b]);
    await select(tester, '最近阅读');
    expect(find.byKey(ValueKey('shelf-book-${a.key}')), findsOneWidget);
    await action(tester, a, '移除');
    expect(library.recentBooks, [b]);
    await select(tester, '全部作品');
    expect(find.byKey(ValueKey('shelf-book-${a.key}')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);
}
