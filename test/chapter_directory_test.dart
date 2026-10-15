import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/book_page.dart';
import 'package:unr/ui/chapter_directory.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/reading_taps.dart';

const book = Book(
  id: 'volumes',
  source: 'local',
  title: '分卷作品',
  author: '作者',
  chapters: [
    Chapter(id: '1', title: '甲章', volume: '卷一'),
    Chapter(id: '2', title: '乙章', volume: '卷一'),
    Chapter(id: '3', title: '丙章', volume: '卷二', vip: true),
    Chapter(id: '4', title: '丁章', volume: '卷二'),
    Chapter(id: '5', title: '尾声'),
  ],
);

class DirectoryLibrary extends Library {
  DirectoryLibrary() : super(Directory.systemTemp, SfacgSource(SfacgApi()));
  @override
  Future<Map<String, ChapterContent>> cachedContents(Book book) async => {
    '3': const ChapterContent([Paragraph('正文3')]),
  };
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      ChapterContent([Paragraph('正文${chapter.id}')]);
  @override
  Future<void> save() async => notifyListeners();
}

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  void configure(WidgetTester tester) {
    tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
        ? const Size(1400, 900)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('详情阅读按钮只依据当前作品的非空阅读记录', (tester) async {
    configure(tester);
    final library = DirectoryLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    library.progress['sfacg:${book.id}'] = [2, 0];
    library.pageOffsets[book.key] = 0;
    await library.markActive(book);
    for (final saved in <List<int>?>[
      null,
      [],
      [0, 0],
      [2, 0],
    ]) {
      if (saved == null) {
        library.progress.remove(book.key);
      } else {
        library.progress[book.key] = saved;
      }
      await tester.pumpWidget(
        MaterialApp(
          home: BookPage(library: library, book: book),
        ),
      );
      await tester.pumpAndSettle();
      final hasProgress = saved?.isNotEmpty == true;
      expect(find.text(hasProgress ? '继续阅读' : '开始阅读'), findsOneWidget);
      expect(find.text(hasProgress ? '开始阅读' : '继续阅读'), findsNothing);
      expect(find.text('目录 · 已缓存 1 / 5 章'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('首次阅读返回详情后改为继续阅读，并恢复已读章节', (tester) async {
    configure(tester);
    final library = DirectoryLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BookPage(library: library, book: book),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始阅读'));
    await tester.pumpAndSettle();
    expect(find.textContaining('正文1').hitTestable(), findsOneWidget);
    await showReadingControls(tester);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    expect(find.textContaining('正文2').hitTestable(), findsOneWidget);
    await showReadingControls(tester);
    await tester.tap(find.byType(BackButton).hitTestable());
    await tester.pumpAndSettle();
    expect(library.progress[book.key]?.first, 1);
    expect(find.text('开始阅读'), findsNothing);
    await tester.tap(find.text('继续阅读'));
    await tester.pumpAndSettle();
    expect(find.textContaining('正文2').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('分卷默认折叠，独立展开收起并保持全书序号与缓存和权限标记', (tester) async {
    var selected = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              ChapterDirectory(
                chapters: book.chapters,
                selectedChapter: 2,
                cachedChapterIds: const {'3'},
                onChapterSelected: (i) => selected = i,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('卷一'), findsOneWidget);
    expect(find.text('卷二'), findsOneWidget);
    expect(find.text('正文'), findsOneWidget);
    expect(find.text('丙章'), findsNothing);
    expect(find.text('2 章 · 当前阅读'), findsOneWidget);
    await tester.tap(find.text('卷二'));
    await tester.pumpAndSettle();
    expect(find.text('甲章'), findsNothing);
    final row = find.byKey(const ValueKey('directory-chapter-3'));
    expect(find.descendant(of: row, matching: find.text('3')), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byTooltip('已缓存')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.lock_outline)),
      findsOneWidget,
    );
    await tester.tap(row);
    expect(selected, 2);
    await tester.tap(find.text('卷一'));
    await tester.pumpAndSettle();
    expect(find.text('甲章'), findsOneWidget);
    expect(find.text('丙章'), findsOneWidget);
    await tester.tap(find.text('卷二'));
    await tester.pumpAndSettle();
    expect(find.text('丙章'), findsNothing);
    expect(find.text('甲章'), findsOneWidget);
  });

  testWidgets('同名卷不合并非连续章节，无卷名章节归入正文', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              ChapterDirectory(
                chapters: const [
                  Chapter(id: '1', title: '第一段', volume: '同名卷'),
                  Chapter(id: '2', title: '第二段'),
                  Chapter(id: '3', title: '第三段', volume: '同名卷'),
                ],
                onChapterSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('同名卷'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('directory-volume-3')));
    await tester.pumpAndSettle();
    expect(find.text('第一段'), findsNothing);
    expect(find.text('第三段'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('directory-chapter-3')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('正文'));
    await tester.pumpAndSettle();
    expect(find.text('第二段'), findsOneWidget);
  });

  testWidgets('作品详情按卷收纳，展开后跳转到对应章节首页', (tester) async {
    configure(tester);
    final library = DirectoryLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BookPage(library: library, book: book),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('目录 · 已缓存 1 / 5 章'), findsOneWidget);
    expect(find.byKey(const ValueKey('directory-chapter-3')), findsNothing);
    await tester.scrollUntilVisible(
      find.text('卷二'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('卷二'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('directory-chapter-3')),
    );
    await tester.tap(find.byKey(const ValueKey('directory-chapter-3')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ReaderPage>(find.byType(ReaderPage)).initialChapter,
      2,
    );
    expect(find.textContaining('正文3').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('阅读页目录按卷折叠，跨卷跳转保持全书章节索引', (tester) async {
    configure(tester);
    final library = DirectoryLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: book),
      ),
    );
    await tester.pumpAndSettle();
    await showReadingControls(tester);
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('directory-chapter-3')), findsNothing);
    await tester.tap(find.text('卷二'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('directory-chapter-3')));
    await tester.pumpAndSettle();
    expect(library.progress[book.key]?.first, 2);
    expect(find.textContaining('正文3').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);
}
