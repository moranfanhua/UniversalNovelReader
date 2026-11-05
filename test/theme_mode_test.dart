import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/reading_taps.dart';

class ThemeLibrary extends Library {
  ThemeLibrary()
    : super(
        Directory.systemTemp,
        SfacgSource(
          SfacgApi(client: MockClient((_) async => throw StateError('不应请求网络'))),
        ),
      );

  bool failSave = false;
  int reads = 0;
  final content = ChapterContent([
    for (var i = 0; i < 30; i++) Paragraph('第 $i 段 ${'夜间阅读测试。' * 20}'),
  ]);

  @override
  Future<void> save() async {
    notifyListeners();
    if (failSave) throw const FileSystemException('无法写入');
  }

  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async {
    reads++;
    return content;
  }

  @override
  Future<ChapterContent?> cached(Book book, Chapter chapter) async => content;
}

const book = Book(
  id: 'theme',
  source: 'local',
  title: '用于检查夜间模式和长书名布局的测试小说',
  author: '测试作者',
  chapters: [Chapter(id: '1', title: '第一章')],
);

void main() {
  test('新书库默认跟随系统，旧日夜偏好迁移并保留书库及进度', () async {
    final root = await Directory.systemTemp.createTemp('unr-theme-');
    addTearDown(() => root.delete(recursive: true));
    final source = SfacgSource(SfacgApi());
    addTearDown(source.api.close);
    Future<Library> open() async {
      final library = await Library.open(source, directory: root);
      addTearDown(library.dispose);
      return library;
    }

    expect((await open()).themeMode, AppThemeMode.system);
    for (final night in [null, false, true]) {
      await File('${root.path}/index.json').writeAsString(
        jsonEncode({
          'books': [book.toJson()],
          'night': ?night,
          'fontSize': 26,
          'progress': {
            book.key: [0, 5],
          },
        }),
      );
      final migrated = await open();
      final expected = night == null
          ? AppThemeMode.system
          : night
          ? AppThemeMode.dark
          : AppThemeMode.light;
      expect(migrated.themeMode, expected);
      await migrated.save();
      final restored = await open();
      expect(restored.themeMode, expected);
      expect(restored.books.single.key, book.key);
      expect(restored.progress[book.key], [0, 5]);
      expect(restored.fontSize, 26);
    }

    for (final mode in AppThemeMode.values) {
      final library = await open();
      await library.setThemeMode(mode);
      expect((await open()).themeMode, mode);
      await library.resetReadingPreferences();
      expect((await open()).themeMode, mode);
      expect(library.progress[book.key], [0, 5]);
    }
  });

  test('未知显示模式回退旧偏好，保存失败恢复当前选择', () async {
    final root = await Directory.systemTemp.createTemp('unr-theme-fallback-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/index.json').writeAsString(
      jsonEncode({'books': [], 'themeMode': 'unknown', 'night': true}),
    );
    final source = SfacgSource(SfacgApi());
    addTearDown(source.api.close);
    final restored = await Library.open(source, directory: root);
    addTearDown(restored.dispose);
    expect(restored.themeMode, AppThemeMode.dark);

    final library = ThemeLibrary()..failSave = true;
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await expectLater(
      library.setThemeMode(AppThemeMode.dark),
      throwsA(isA<FileSystemException>()),
    );
    expect(library.themeMode, AppThemeMode.system);
  });

  void viewport(WidgetTester tester) {
    tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
        ? const Size(1400, 900)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }

  ThemeLibrary libraryForTest() {
    final library = ThemeLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    return library;
  }

  ThemeData currentTheme(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(Scaffold).last));

  Future<void> selectMode(WidgetTester tester, String label) async {
    final dropdown = find.byKey(const ValueKey('theme-mode'));
    await tester.ensureVisible(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });

  testWidgets('外观设置跟随系统实时更新，手动模式优先，保存失败可重试', (tester) async {
    viewport(tester);
    final library = libraryForTest();
    await tester.pumpWidget(UnrApp(library: library));
    expect(currentTheme(tester).brightness, Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(currentTheme(tester).brightness, Brightness.dark);
    expect(
      currentTheme(tester).scaffoldBackgroundColor.computeLuminance(),
      lessThan(.1),
    );

    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('软件设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-appearance-entry')));
    await tester.pumpAndSettle();
    expect(find.text('外观设置'), findsOneWidget);
    await selectMode(tester, '日间模式');
    expect(library.themeMode, AppThemeMode.light);
    expect(currentTheme(tester).brightness, Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    await selectMode(tester, '夜间模式');
    expect(currentTheme(tester).brightness, Brightness.dark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(currentTheme(tester).brightness, Brightness.dark);

    final overlay = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
    );
    expect(overlay.value.statusBarIconBrightness, Brightness.light);
    expect(overlay.value.systemNavigationBarIconBrightness, Brightness.light);

    library.failSave = true;
    await selectMode(tester, '日间模式');
    expect(library.themeMode, AppThemeMode.dark);
    expect(currentTheme(tester).brightness, Brightness.dark);
    expect(find.textContaining('显示模式保存失败'), findsOneWidget);
    library.failSave = false;
    await selectMode(tester, '跟随系统');
    expect(library.themeMode, AppThemeMode.system);
    expect(currentTheme(tester).brightness, Brightness.light);
    expect(find.textContaining('显示模式保存失败'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  for (final mode in ReadingMode.values) {
    testWidgets('阅读设置切换显示模式，面板即时更新且保持进度（${mode.name}）', (tester) async {
      viewport(tester);
      final library = libraryForTest()
        ..readingMode = mode
        ..books.add(book);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpWidget(UnrApp(library: library));
      await tester.tap(find.byKey(ValueKey('shelf-book-${book.key}')));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsOneWidget);
      if (mode == ReadingMode.paged) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      } else {
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -800),
        );
      }
      await tester.pumpAndSettle();
      await showReadingControls(tester);
      await tester.pumpAndSettle();
      final reader = tester.state(find.byType(ReaderPage)) as dynamic;
      final position = (
        reader.chapter,
        reader.paragraph,
        reader.characterOffset,
      );
      final reads = library.reads;
      expect(find.byTooltip('日夜模式'), findsNothing);
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await selectMode(tester, '日间模式');
      await tester.pumpAndSettle();
      expect(library.themeMode, AppThemeMode.light);
      expect(currentTheme(tester).brightness, Brightness.light);
      expect((
        reader.chapter,
        reader.paragraph,
        reader.characterOffset,
      ), position);
      expect(library.reads, reads);
      await selectMode(tester, '跟随系统');
      final dropdownContext = tester.element(
        find.byKey(const ValueKey('theme-mode')),
      );
      expect(Theme.of(dropdownContext).brightness, Brightness.dark);
      expect(
        Theme.of(tester.element(find.byType(BottomSheet))).brightness,
        Brightness.dark,
      );
      await tester.tap(find.byTooltip('关闭阅读设置'));
      await tester.pumpAndSettle();
      expect((
        reader.chapter,
        reader.paragraph,
        reader.characterOffset,
      ), position);
      expect(currentTheme(tester).brightness, Brightness.dark);
      final text = tester.widget<EditableText>(find.byType(EditableText).first);
      expect(text.style.color!.computeLuminance(), greaterThan(.5));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: platforms);
  }
}
