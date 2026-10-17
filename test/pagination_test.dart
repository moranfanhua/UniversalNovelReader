import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/domain/reading_preferences.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/settings.dart';
import 'package:unr/ui/paged_chapter.dart';
import 'package:unr/ui/reader.dart';
import 'package:unr/ui/text_pagination.dart';
import 'helpers/reading_taps.dart';

class PagedLibrary extends Library {
  PagedLibrary() : super(Directory.systemTemp, SfacgSource(SfacgApi()));
  final content = ChapterContent([Paragraph('连续正文😀中文。' * 300)]);
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
  TestWidgetsFlutterBinding.ensureInitialized();
  test('分页不丢文字、换行或表情，插图独立成页', () {
    final text = '中文😀组合👩‍💻连续正文。\n换行段落。' * 80;
    final pages = TextPagination.paginate(
      [
        Paragraph(text, remoteIndex: 1),
        const Paragraph('', image: 'local:picture'),
        const Paragraph('结尾'),
      ],
      width: 280,
      height: 260,
      headingSpace: 40,
      comments: true,
      style: const TextStyle(fontSize: 20, height: 1.9),
      scaler: TextScaler.noScaling,
      direction: TextDirection.ltr,
    );
    final fragments = pages.expand((page) => page).toList();
    expect(
      fragments.where((p) => p.paragraph == 0).map((p) => p.text).join(),
      '　　$text',
    );
    expect(fragments.where((p) => p.image).length, 1);
    expect(pages.where((page) => page.any((p) => p.image)).single.length, 1);
    expect(fragments.last.text, '　　结尾');
    for (var i = 0; i < pages.length; i++) {
      expect(
        pages[i].fold<double>(
          i == 0 ? 40 : 0,
          (height, p) => height + p.height + 18,
        ),
        lessThanOrEqualTo(260.01),
      );
      for (final fragment in pages[i].where((p) => !p.image)) {
        expect(fragment.text.runes, isNot(contains(0xfffd)));
        expect(
          fragment.text.isEmpty ||
              fragment.text.codeUnitAt(0) < 0xdc00 ||
              fragment.text.codeUnitAt(0) > 0xdfff,
          isTrue,
        );
      }
    }
  });
  test('阅读模式及页内进度可持久保存，旧设置默认滚动模式', () async {
    final root = await Directory.systemTemp.createTemp('unr-paged-settings-');
    final api = SfacgApi();
    final library = Library(root, SfacgSource(api));
    library.readingMode = ReadingMode.paged;
    library.pageOffsets['local:1'] = 256;
    await library.save();
    final restored = await Library.open(library.source, directory: root);
    expect(restored.readingMode, ReadingMode.paged);
    expect(restored.pageOffsets['local:1'], 256);
    await File(
      '${root.path}/index.json',
    ).writeAsString(jsonEncode({'books': []}));
    expect(
      (await Library.open(library.source, directory: root)).readingMode,
      ReadingMode.scroll,
    );
    await root.delete(recursive: true);
    restored.dispose();
    library.dispose();
    api.close();
  });
  testWidgets('设置中可选择翻页阅读，也可切回滚动阅读', (tester) async {
    final library = PagedLibrary();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            library: library,
            gbk: false,
            onEncodingChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('settings-reading-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻页阅读'));
    await tester.pump();
    expect(library.readingMode, ReadingMode.paged);
    await tester.tap(find.text('滚动阅读'));
    await tester.pump();
    expect(library.readingMode, ReadingMode.scroll);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
    library.source.api.close();
  });
  for (final animation in PageTurnAnimation.values) {
    testWidgets('手机点击两侧、滑动、键盘与字号调整保持进度，重新打开恢复（${animation.name}）', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = PagedLibrary()
        ..readingMode = ReadingMode.paged
        ..pageTurnAnimation = animation;
      const book = Book(
        id: 'local',
        title: '测试小说',
        author: '作者',
        source: 'local',
        chapters: [Chapter(id: '1', title: '第一章')],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ReaderPage(library: library, book: book),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.byType(PagedChapter), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tapReadingSide(tester, 1);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PageView), const Offset(-300, 0));
      await tester.pumpAndSettle();
      int currentPage() => readingPager(tester).page + 1;
      final beforeKeyboard = currentPage();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(currentPage(), beforeKeyboard + 1);
      await tester.pump(const Duration(milliseconds: 700));
      final offset = library.pageOffsets[book.key]!;
      expect(offset, greaterThan(0));
      await showReadingControls(tester);
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      final larger = tester.widget<Slider>(
        find.byKey(const ValueKey('reading-font-size')),
      );
      larger.onChanged!(22);
      larger.onChangeEnd!(22);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭阅读设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tapReadingSide(tester, 1);
      await tester.pump(const Duration(milliseconds: 50));
      await showReadingControls(tester);
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      final smaller = tester.widget<Slider>(
        find.byKey(const ValueKey('reading-font-size')),
      );
      smaller.onChanged!(20);
      smaller.onChangeEnd!(20);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭阅读设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      final savedOffset = library.pageOffsets[book.key]!;
      expect(savedOffset, greaterThan(0));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      expect(library.pageOffsets[book.key], savedOffset);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      library.dispose();
      library.source.api.close();
    });
  }
}
