import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/reader.dart';
import 'package:unr/ui/reading_tap_zones.dart';
import 'helpers/reading_taps.dart';

class ImmersiveLibrary extends Library {
  ImmersiveLibrary() : super(Directory.systemTemp, SfacgSource(SfacgApi()));
  final reads = <String>[];
  final contents = <String, ChapterContent>{
    '1': ChapterContent([Paragraph('正文内容。' * 500)]),
    '2': const ChapterContent([Paragraph('第二章正文')]),
    '3': const ChapterContent([Paragraph('第三章正文')]),
  };
  bool fullyCached = true;
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async {
    reads.add(chapter.id);
    return contents[chapter.id]!;
  }

  @override
  Future<ChapterContent?> cached(Book book, Chapter chapter) async =>
      fullyCached || chapter.id == '1' ? contents[chapter.id] : null;
  @override
  Future<void> save() async => notifyListeners();
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

const book = Book(
  id: 'immersive',
  source: 'local',
  title: '沉浸阅读',
  author: '',
  wordCount: 30000,
  chapters: [
    Chapter(id: '1', title: '第一章'),
    Chapter(id: '2', title: '第二章'),
    Chapter(id: '3', title: '第三章'),
  ],
);

void main() {
  Future<void> open(
    WidgetTester tester,
    ImmersiveLibrary library, {
    int chapter = 0,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: book, initialChapter: chapter),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> center(WidgetTester tester) async {
    await tester.tapAt(tester.getCenter(find.byType(ReadingTapZones)));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
  }

  for (final mode in ReadingMode.values) {
    testWidgets(
      '默认隐藏菜单，手机点击中央切换且正文不移动（${mode.name}）',
      (tester) async {
        final library = ImmersiveLibrary()..readingMode = mode;
        await open(tester, library);
        expect(find.byType(AppBar), findsNothing);
        expect(find.text('下一章'), findsNothing);
        final area = tester.getRect(find.byType(ReadingTapZones));
        final page = mode == ReadingMode.paged
            ? readingPager(tester).page
            : null;
        final reader = tester.state(find.byType(ReaderPage)) as dynamic;
        final position = (
          reader.chapter,
          reader.paragraph,
          reader.characterOffset,
        );
        await center(tester);
        expect(find.byType(AppBar), findsOneWidget);
        expect(find.text('下一章'), findsOneWidget);
        expect(tester.getRect(find.byType(ReadingTapZones)), area);
        if (page != null) expect(readingPager(tester).page, page);
        expect((
          reader.chapter,
          reader.paragraph,
          reader.characterOffset,
        ), position);
        expect(find.textContaining(RegExp(r'^第 .* 页')), findsNothing);
        expect(find.text('1 / 3'), findsNothing);
        await center(tester);
        expect(find.byType(AppBar), findsNothing);
        expect(find.text('下一章'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    '桌面 Esc 切换菜单，隐藏时仍可用方向键翻页',
    (tester) async {
      final library = ImmersiveLibrary()..readingMode = ReadingMode.paged;
      await open(tester, library);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(readingPager(tester).page, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(readingPager(tester).page, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('完整缓存按全书累计页码，跨章不重置为一', (tester) async {
    final library = ImmersiveLibrary()..readingMode = ReadingMode.paged;
    library.contents['1'] = const ChapterContent([Paragraph('第一章正文')]);
    await open(tester, library, chapter: 1);
    await showReadingControls(tester);
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    expect(library.reads, ['2', '3']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未缓存章节以全书字数估算，仅总页数加约，不自动读取全书', (tester) async {
    final library = ImmersiveLibrary()
      ..readingMode = ReadingMode.paged
      ..fullyCached = false;
    await open(tester, library);
    await showReadingControls(tester);
    String label() => tester
        .widget<Text>(find.byKey(const ValueKey('book-page-progress')))
        .data!;
    expect(label(), matches(r'^1/约\d+$'));
    final before = int.parse(label().split('约').last);
    library.fontSize = 30;
    await library.save();
    await tester.pumpAndSettle();
    expect(int.parse(label().split('约').last), greaterThan(before));
    expect(library.reads, ['1']);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
