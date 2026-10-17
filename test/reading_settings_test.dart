import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/data/reader_fonts.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/domain/reading_preferences.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/paged_chapter.dart';
import 'package:unr/ui/reader.dart';
import 'package:unr/ui/reading_settings.dart';
import 'helpers/reading_taps.dart';

class FakeFonts extends ReaderFonts {
  FakeFonts() : super(Directory.systemTemp);
  @override
  Future<String> load(String id) async => 'UNR_test_font';
  @override
  Future<String> download(
    String id, {
    void Function(int, int?)? onProgress,
  }) async {
    onProgress?.call(10, 10);
    return load(id);
  }
}

class PreferencesLibrary extends Library {
  PreferencesLibrary()
    : super(Directory.systemTemp, SfacgSource(SfacgApi()), fonts: FakeFonts());
  final content = ChapterContent([
    for (var i = 0; i < 40; i++) Paragraph('段落$i ${'中文正文' * 30}'),
  ]);
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async => content;
  @override
  Future<void> save() async {
    notifyListeners();
  }

  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

void main() {
  test('翻页动画兼容旧书库和未知设置，三种选择可保存且恢复默认不丢进度', () async {
    final root = await Directory.systemTemp.createTemp('unr-turn-animation-');
    addTearDown(() => root.delete(recursive: true));
    final source = SfacgSource(SfacgApi());
    addTearDown(source.api.close);
    Future<Library> open() async {
      final library = await Library.open(source, directory: root);
      addTearDown(library.dispose);
      return library;
    }

    expect((await open()).pageTurnAnimation, PageTurnAnimation.slide);
    for (final stored in [null, 'unknown', 123]) {
      await File('${root.path}/index.json').writeAsString(
        jsonEncode({
          'books': [],
          'pageTurnAnimation': ?stored,
          'progress': {
            'local:1': [2, 3],
          },
          'pageOffsets': {'local:1': 16},
        }),
      );
      final library = await open();
      expect(library.pageTurnAnimation, PageTurnAnimation.slide);
      for (final animation in PageTurnAnimation.values) {
        library.pageTurnAnimation = animation;
        await library.save();
        final restored = await open();
        expect(restored.pageTurnAnimation, animation);
        expect(restored.progress['local:1'], [2, 3]);
        expect(restored.pageOffsets['local:1'], 16);
      }
      library.pageTurnAnimation = PageTurnAnimation.simulation;
      await library.resetReadingPreferences();
      final defaults = await open();
      expect(defaults.pageTurnAnimation, PageTurnAnimation.slide);
      expect(defaults.progress['local:1'], [2, 3]);
      expect(defaults.pageOffsets['local:1'], 16);
    }
  });

  for (final width in [360.0, 1000.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('翻页动画选项可切换且滚动阅读保留选择（宽$width，缩放$scale）', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final library = PreferencesLibrary();
        addTearDown(library.dispose);
        addTearDown(library.source.api.close);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ReadingSettings(library: library),
              ),
            ),
          ),
        );
        final selection = find.byKey(
          const ValueKey('reading-page-turn-animation'),
        );
        expect(selection, findsNothing);
        await tester.tap(find.text('翻页阅读'));
        await tester.pumpAndSettle();
        for (final entry in {
          '无动画': PageTurnAnimation.none,
          '仿真': PageTurnAnimation.simulation,
          '滑动': PageTurnAnimation.slide,
        }.entries) {
          await tester.tap(find.text(entry.key));
          await tester.pumpAndSettle();
          expect(library.pageTurnAnimation, entry.value);
          expect(
            tester
                .widget<SegmentedButton<PageTurnAnimation>>(selection)
                .selected,
            {entry.value},
          );
        }
        await tester.tap(find.text('仿真'));
        await tester.tap(find.text('滚动阅读'));
        await tester.pumpAndSettle();
        expect(selection, findsNothing);
        await tester.tap(find.text('翻页阅读'));
        await tester.pumpAndSettle();
        expect(library.pageTurnAnimation, PageTurnAnimation.simulation);
        await tester.ensureVisible(find.text('恢复默认阅读设置'));
        await tester.tap(find.text('恢复默认阅读设置'));
        await tester.pumpAndSettle();
        expect(library.pageTurnAnimation, PageTurnAnimation.slide);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  test('显示段评默认开启，旧书库兼容，关闭后持久化并可恢复默认', () async {
    final root = await Directory.systemTemp.createTemp(
      'unr-comment-preference-',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = SfacgSource(SfacgApi());
    addTearDown(source.api.close);
    Future<Library> open() async {
      final library = await Library.open(source, directory: root);
      addTearDown(library.dispose);
      return library;
    }

    final initial = await open();
    expect(initial.showParagraphComments, isTrue);
    expect(initial.paragraphCommentPlacement, ParagraphCommentPlacement.right);
    await File('${root.path}/index.json').writeAsString(
      jsonEncode({
        'books': [],
        'fontSize': 26,
        'paragraphCommentPlacement': 'unknown',
        'progress': {
          'sfacg:1': [2, 3],
        },
      }),
    );
    final migrated = await open();
    expect(migrated.showParagraphComments, isTrue);
    expect(migrated.paragraphCommentPlacement, ParagraphCommentPlacement.right);
    migrated.showParagraphComments = false;
    migrated.paragraphCommentPlacement = ParagraphCommentPlacement.paragraphEnd;
    await migrated.save();
    final restored = await open();
    expect(restored.showParagraphComments, isFalse);
    expect(
      restored.paragraphCommentPlacement,
      ParagraphCommentPlacement.paragraphEnd,
    );
    expect(restored.fontSize, 26);
    expect(restored.progress['sfacg:1'], [2, 3]);
    await restored.resetReadingPreferences();
    final defaults = await open();
    expect(defaults.showParagraphComments, isTrue);
    expect(defaults.paragraphCommentPlacement, ParagraphCommentPlacement.right);
    expect(restored.progress['sfacg:1'], [2, 3]);
  });

  testWidgets('字体下载选项、四个偏好滑块和恢复默认设置可用', (tester) async {
    final library = PreferencesLibrary();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ReadingSettings(library: library)),
        ),
      ),
    );
    final comments = find.byKey(const ValueKey('reading-paragraph-comments'));
    expect(tester.widget<SwitchListTile>(comments).value, isTrue);
    await tester.tap(find.text('跟随段尾'));
    await tester.pumpAndSettle();
    expect(
      library.paragraphCommentPlacement,
      ParagraphCommentPlacement.paragraphEnd,
    );
    await tester.tap(comments);
    await tester.pumpAndSettle();
    expect(library.showParagraphComments, isFalse);
    expect(
      find.byKey(const ValueKey('reading-comment-placement')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('reading-font')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Noto Sans SC · 黑体').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载并使用字体'));
    await tester.pumpAndSettle();
    expect(library.readingFontId, 'noto-sans-sc');
    expect(library.readingFontFamily, 'UNR_test_font');
    for (final preference in {
      'reading-font-size': 26.0,
      'reading-horizontal-margin': 40.0,
      'reading-vertical-margin': 32.0,
      'reading-line-height': 2.2,
    }.entries) {
      final slider = tester.widget<Slider>(
        find.byKey(ValueKey(preference.key)),
      );
      slider.onChanged!(preference.value);
      slider.onChangeEnd!(preference.value);
      await tester.pump();
    }
    expect(
      [
        library.fontSize,
        library.horizontalMargin,
        library.verticalMargin,
        library.lineHeight,
      ],
      [26, 40, 32, 2.2],
    );
    await tester.ensureVisible(find.text('恢复默认阅读设置'));
    await tester.tap(find.text('恢复默认阅读设置'));
    await tester.pumpAndSettle();
    expect(library.readingFontId, '');
    expect(library.showParagraphComments, isTrue);
    expect(library.paragraphCommentPlacement, ParagraphCommentPlacement.right);
    expect(
      [
        library.fontSize,
        library.horizontalMargin,
        library.verticalMargin,
        library.lineHeight,
      ],
      [20, 22, 24, 1.9],
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
    library.source.api.close();
  });
  for (final width in [360.0, 1280.0]) {
    testWidgets('新增字体在宽度 $width 和放大文字下显示来源并可下载切换', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = PreferencesLibrary();
      addTearDown(library.dispose);
      addTearDown(library.source.api.close);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReadingSettings(library: library),
            ),
          ),
        ),
      );
      final dropdown = find.byKey(const ValueKey('reading-font'));
      for (final font in ReaderFonts.catalog.skip(2)) {
        tester.widget<DropdownButton<String>>(dropdown).onChanged!(font.id);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('来源：${font.source} · SIL OFL 1.1'),
          findsOneWidget,
        );
        if (font.notice != null) {
          expect(find.text(font.notice!), findsOneWidget);
        } else {
          expect(find.textContaining('上游预览测试版'), findsNothing);
        }
        final download = find.text('下载并使用字体');
        await tester.ensureVisible(download);
        await tester.tap(download);
        await tester.pumpAndSettle();
        expect(library.readingFontId, font.id);
        expect(library.downloadedFonts, contains(font.id));
        expect(find.text('${font.name} · 已下载'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('阅读设置同时改变滚动页与翻页布局，关闭面板保留阅读段落', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = PreferencesLibrary();
    const book = Book(
      id: 'local',
      source: 'local',
      title: '测试',
      author: '',
      chapters: [Chapter(id: '1', title: '一')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: book),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -800),
    );
    await tester.pumpAndSettle();
    await showReadingControls(tester);
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    final saved = library.progress[book.key]!.last;
    expect(saved, greaterThan(0));
    for (final preference in {
      'reading-font-size': 28.0,
      'reading-horizontal-margin': 40.0,
      'reading-vertical-margin': 32.0,
      'reading-line-height': 2.4,
    }.entries) {
      final slider = tester.widget<Slider>(
        find.byKey(ValueKey(preference.key)),
      );
      slider.onChanged!(preference.value);
      slider.onChangeEnd!(preference.value);
      await tester.pump();
    }
    await tester.tap(find.text('翻页阅读'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仿真'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭阅读设置'));
    await tester.pumpAndSettle();
    final paged = tester.widget<PagedChapter>(find.byType(PagedChapter));
    expect(paged.pageTurnAnimation, PageTurnAnimation.simulation);
    expect(
      [
        paged.fontSize,
        paged.horizontalMargin,
        paged.verticalMargin,
        paged.lineHeight,
      ],
      [28, 40, 32, 2.4],
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(library.progress[book.key]!.last, saved);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(640, 360);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
    library.source.api.close();
  });
}
