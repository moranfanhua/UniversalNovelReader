import 'dart:async';
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
import 'package:unr/ui/book_page.dart';
import 'package:unr/ui/chapter_page_layout.dart';
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

class DelayedScrollLibrary extends ImmersiveLibrary {
  final nextChapter = Completer<ChapterContent>();

  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async {
    if (chapter.id == '2') {
      reads.add(chapter.id);
      return nextChapter.future;
    }
    return super.read(book, chapter);
  }
}

class DelayedSeekLibrary extends ImmersiveLibrary {
  final targetChapter = Completer<ChapterContent>();

  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async {
    if (chapter.id == '3') {
      reads.add(chapter.id);
      return targetChapter.future;
    }
    return super.read(book, chapter);
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
    double width = 360,
    double textScale = 1,
    bool disableAnimations = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
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
    testWidgets('上下菜单同步滑动 200ms，快速反向切换不改变正文（${mode.name}）', (tester) async {
      final library = ImmersiveLibrary()..readingMode = mode;
      await open(tester, library);
      final viewport = tester.getRect(find.byType(ReadingTapZones));
      final bottom = find.byKey(const ValueKey('reader-bottom-toolbar'));
      final reader = tester.state(find.byType(ReaderPage)) as dynamic;
      final position = (
        reader.chapter,
        reader.paragraph,
        reader.characterOffset,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(find.byType(AppBar)).top, inExclusiveRange(-56, 0));
      final middle = tester.getRect(bottom);
      expect(middle.bottom, greaterThan(640));
      expect(middle.top, lessThan(640));
      expect(tester.getRect(find.byType(ReadingTapZones)), viewport);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(find.byType(AppBar)).top, 0);
      expect(tester.getRect(bottom).bottom, 640);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      final closing = tester.getRect(bottom).top;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.getRect(bottom).top, closeTo(closing, .1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
      expect(tester.getRect(bottom).bottom, 640);
      expect(tester.getRect(find.byType(ReadingTapZones)), viewport);
      expect((
        reader.chapter,
        reader.paragraph,
        reader.characterOffset,
      ), position);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reader.controlsVisible, isFalse);
      expect(reader.controlsAnimation.value, 0);
      expect(find.byType(AppBar), findsNothing);
      expect(bottom, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '默认隐藏菜单，手机点击中央切换且正文不移动（${mode.name}）',
      (tester) async {
        final library = ImmersiveLibrary()..readingMode = mode;
        await open(tester, library);
        expect(find.byType(AppBar), findsNothing);
        expect(find.byTooltip('下一章'), findsNothing);
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
        expect(find.byTooltip('下一章'), findsOneWidget);
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
        expect(find.byTooltip('下一章'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('底栏章名居中、符号切章，详情返回后保留阅读位置（${mode.name}）', (tester) async {
      final library = ImmersiveLibrary()..readingMode = mode;
      await open(tester, library, chapter: 1);
      await showReadingControls(tester);
      final reader = tester.state(find.byType(ReaderPage)) as dynamic;
      final position = (
        reader.chapter,
        reader.paragraph,
        reader.characterOffset,
      );
      final reads = List.of(library.reads);
      final title = find.byKey(const ValueKey('book-progress-title'));
      final toolbar = find.byKey(const ValueKey('reader-bottom-toolbar'));
      expect(tester.widget<Text>(title).textAlign, TextAlign.center);
      expect(
        tester.getCenter(title).dx,
        closeTo(tester.getCenter(toolbar).dx, .1),
      );
      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
      expect(find.text('上一章'), findsNothing);
      expect(find.text('下一章'), findsNothing);
      expect(find.byTooltip('日夜模式'), findsNothing);
      expect(
        find.descendant(of: toolbar, matching: find.byType(Divider)),
        findsNothing,
      );
      await tester.tap(find.byTooltip('作品详情'));
      await tester.pumpAndSettle();
      expect(find.byType(BookPage), findsOneWidget);
      expect(tester.widget<BookPage>(find.byType(BookPage)).book.key, book.key);
      await tester.tap(find.byType(BackButton).hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(BookPage), findsNothing);
      expect(tester.state(find.byType(ReaderPage)), same(reader));
      expect((
        reader.chapter,
        reader.paragraph,
        reader.characterOffset,
      ), position);
      expect(library.reads, reads);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('系统关闭动画时菜单直接切换', (tester) async {
    await open(tester, ImmersiveLibrary(), disableAnimations: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.getRect(find.byType(AppBar)).top, 0);
    expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(AppBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('拖动跨章只预览章名和百分比，松手后加载并跳转', (tester) async {
    final library = DelayedSeekLibrary()
      ..readingMode = ReadingMode.paged
      ..fullyCached = false;
    library.contents['1'] = const ChapterContent([Paragraph('第一章正文')]);
    await open(tester, library);
    await showReadingControls(tester);
    final slider = find.byKey(const ValueKey('book-progress-slider'));
    final rect = tester.getRect(slider);
    final canceled = await tester.startGesture(
      Offset(rect.left + 12, rect.center.dy),
    );
    await canceled.moveTo(Offset(rect.right - 12, rect.center.dy));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await canceled.up();
    await tester.pumpAndSettle();
    expect(library.reads, ['1']);
    expect(readingChapter(tester), 0);
    await showReadingControls(tester);
    expect(find.byKey(const ValueKey('book-progress-preview')), findsNothing);
    final before = library.progress[book.key]?.toList();
    final gesture = await tester.startGesture(
      Offset(rect.left + 12, rect.center.dy),
    );
    await gesture.moveTo(Offset(rect.right - 12, rect.center.dy));
    await tester.pump();
    final preview = find.byKey(const ValueKey('book-progress-preview'));
    expect(tester.widget<Semantics>(preview).properties.label, contains('第三章'));
    expect(find.text('100.0%'), findsOneWidget);
    expect(library.reads, ['1']);
    expect(library.progress[book.key], before);
    expect(readingChapter(tester), 0);
    await gesture.up();
    await tester.pump();
    expect(library.reads, ['1', '3']);
    expect(find.text('正在跳转…'), findsOneWidget);
    expect(readingChapter(tester), 0);
    library.targetChapter.complete(library.contents['3']);
    await tester.pumpAndSettle();
    expect(readingChapter(tester), 2);
    expect(preview, findsNothing);
    expect(find.text('正在跳转…'), findsNothing);
    expect(library.reads, isNot(contains('2')));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

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
    await tester.tap(find.byTooltip('下一章'));
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

  for (final mode in ReadingMode.values) {
    for (final width in [360.0, 1280.0]) {
      testWidgets('进度滑条在 $mode / $width 跳转章内页并拖至全书两端', (tester) async {
        final library = ImmersiveLibrary()..readingMode = mode;
        await open(tester, library, width: width);
        await showReadingControls(tester);
        await tester.pumpAndSettle();
        final sliderFinder = find.byKey(const ValueKey('book-progress-slider'));
        final slider = tester.widget<Slider>(sliderFinder);
        final target = ((slider.max - 2) / 2).roundToDouble();
        expect(target, greaterThan(1));
        slider.onChangeStart!(slider.value);
        slider.onChanged!(target);
        await tester.pump();
        tester.widget<Slider>(sliderFinder).onChangeEnd!(target);
        await tester.pumpAndSettle();
        expect(tester.widget<Slider>(sliderFinder).value, greaterThan(1));
        expect(library.progress[book.key]!.first, 0);
        final toolbar = tester.getRect(
          find.byKey(const ValueKey('reader-bottom-toolbar')),
        );
        final appBar = tester.getRect(find.byType(AppBar));
        expect(toolbar.height, greaterThan(appBar.height));
        expect(toolbar.width, appBar.width);
        expect(
          tester.getRect(sliderFinder).bottom,
          lessThan(
            tester
                .getRect(find.byKey(const ValueKey('reader-bottom-actions')))
                .top,
          ),
        );

        Future<void> dragTo(bool end) async {
          final rect = tester.getRect(sliderFinder);
          final gesture = await tester.startGesture(rect.center);
          await gesture.moveTo(
            Offset(end ? rect.right - 12 : rect.left + 12, rect.center.dy),
          );
          await gesture.up();
          await tester.pumpAndSettle();
        }

        await dragTo(true);
        expect(library.progress[book.key]!.first, 2);
        await dragTo(false);
        expect(library.progress[book.key], [0, 0]);
        expect(tester.widget<Slider>(sliderFinder).value, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final prefix in [false, true]) {
    for (final shortNext in [false, true]) {
      testWidgets('滚动滑条跳到非末章长段落的末页（前置段落 $prefix，紧邻短章 $shortNext）', (
        tester,
      ) async {
        final library = ImmersiveLibrary()..readingMode = ReadingMode.scroll;
        library.contents[shortNext ? '3' : '2'] = library.contents['1']!;
        if (prefix) {
          library.contents['1'] = ChapterContent([
            const Paragraph('前置段落'),
            ...library.contents['1']!.paragraphs,
          ]);
        }
        await open(tester, library);
        await showReadingControls(tester);
        await tester.pumpAndSettle();
        final sliderFinder = find.byKey(const ValueKey('book-progress-slider'));
        final slider = tester.widget<Slider>(sliderFinder);
        final layout =
            (tester.state(find.byType(ReaderPage)) as dynamic).pageLayout
                as ChapterPageLayout;
        final target = layout
            .paginate(library.contents['1']!, book.chapters.first.title)
            .length
            .toDouble();
        expect(target, greaterThan(1));
        slider.onChangeStart!(slider.value);
        slider.onChanged!(target);
        await tester.pump();
        tester.widget<Slider>(sliderFinder).onChangeEnd!(target);
        await tester.pumpAndSettle();
        expect(library.reads, ['1', '1', '2', if (shortNext) '3']);
        expect(readingChapter(tester), 0);
        expect(tester.widget<Slider>(sliderFinder).value, target);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(library.pageOffsets[book.key], greaterThan(0));
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(library: library, book: book),
          ),
        );
        await tester.pumpAndSettle();
        await showReadingControls(tester);
        await tester.pumpAndSettle();
        expect(tester.widget<Slider>(sliderFinder).value, target);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final cancel in [false, true]) {
    testWidgets('章末字符定位等待下一章，用户滚动可取消（取消 $cancel）', (tester) async {
      final library = DelayedScrollLibrary()..readingMode = ReadingMode.scroll;
      library.contents['2'] = library.contents['1']!;
      await open(tester, library);
      await showReadingControls(tester);
      await tester.pumpAndSettle();
      final layout =
          (tester.state(find.byType(ReaderPage)) as dynamic).pageLayout
              as ChapterPageLayout;
      final target = layout
          .paginate(library.contents['1']!, book.chapters.first.title)
          .length
          .toDouble();
      final sliderFinder = find.byKey(const ValueKey('book-progress-slider'));
      final slider = tester.widget<Slider>(sliderFinder);
      slider.onChangeStart!(slider.value);
      slider.onChanged!(target);
      await tester.pump();
      tester.widget<Slider>(sliderFinder).onChangeEnd!(target);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(const ValueKey('scroll-next-loading')), findsOneWidget);
      expect(library.reads, ['1', '1', '2']);
      final scrollFinder = find.byType(SingleChildScrollView);
      final scroll = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      if (cancel) {
        await tester.drag(scrollFinder, const Offset(0, 240));
        scroll.jumpTo(scroll.offset);
        await tester.pump();
      }
      final beforeAppend = scroll.offset;
      library.nextChapter.complete(library.contents['2']);
      await tester.pumpAndSettle();
      if (cancel) {
        expect(scroll.offset, closeTo(beforeAppend, .1));
        expect(tester.widget<Slider>(sliderFinder).value, lessThan(target));
      } else {
        expect(tester.widget<Slider>(sliderFinder).value, target);
        expect(scroll.offset, greaterThan(beforeAppend));
      }
      expect(library.reads, ['1', '1', '2']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('窄屏两倍文字的底栏分行显示进度与功能并保留章节按钮', (tester) async {
    final library = ImmersiveLibrary()..readingMode = ReadingMode.paged;
    await open(tester, library, width: 320, textScale: 2);
    await showReadingControls(tester);
    expect(find.byTooltip('上一章'), findsOneWidget);
    expect(find.byTooltip('下一章'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('reader-bottom-toolbar')))
          .height,
      greaterThan(kToolbarHeight * 2),
    );
    for (final tooltip in ['目录', '作品详情', '阅读设置']) {
      expect(find.byTooltip(tooltip).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
