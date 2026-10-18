import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/domain/reading_preferences.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/reader.dart';
import 'package:unr/ui/reading_settings.dart';
import 'chapter_transition_test.dart' show TransitionLibrary, transitionBook;
import 'helpers/reading_taps.dart';

const volumeChannel = MethodChannel('unr/reader_volume_keys');

void main() {
  final enabledCalls = <bool>[];
  setUp(() {
    enabledCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(volumeChannel, (call) async {
          expect(call.method, 'setEnabled');
          enabledCalls.add(call.arguments as bool);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(volumeChannel, null);
  });

  Future<void> open(
    WidgetTester tester,
    TransitionLibrary library, {
    int chapter = 0,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          library: library,
          book: transitionBook,
          initialChapter: chapter,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
  }

  Future<void> volume(WidgetTester tester, int delta) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      volumeChannel.name,
      volumeChannel.codec.encodeMethodCall(MethodCall('turnPage', delta)),
      (_) {},
    );
    await settle(tester);
  }

  for (final animation in PageTurnAnimation.values) {
    testWidgets('音量键逐页前后移动，并从下一章返回上一章末页（${animation.name}）', (tester) async {
      final library = TransitionLibrary()
        ..readingMode = ReadingMode.paged
        ..pageTurnAnimation = animation;
      await open(tester, library);
      expect(enabledCalls.last, isTrue);
      expect(readingPager(tester).page, 0);
      await volume(tester, 1);
      expect(readingPager(tester).page, 1);
      await volume(tester, -1);
      expect(readingPager(tester).page, 0);
      await showReadingControls(tester);
      await tester.tap(find.text('下一章'));
      await settle(tester);
      await volume(tester, -1);
      expect(readingChapter(tester), 0);
      expect(find.textContaining('上一章结尾标记').hitTestable(), findsOneWidget);
      await volume(tester, 1);
      expect(readingChapter(tester), 1);
      await volume(tester, 1);
      expect(readingChapter(tester), 2);
      await volume(tester, 1);
      expect(readingChapter(tester), 2);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(enabledCalls.last, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('滚动阅读音量键按一屏移动，到边界才切章', (tester) async {
    final library = TransitionLibrary();
    library.contents['2'] = ChapterContent([
      const Paragraph('第二章正文'),
      for (var i = 0; i < 40; i++) Paragraph('第二章段落$i'),
    ]);
    await open(tester, library);
    final controller = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    final initialOffset = controller.offset;
    await volume(tester, 1);
    expect(controller.offset, greaterThan(100));
    expect(readingChapter(tester), 0);
    await volume(tester, -1);
    expect(controller.offset, closeTo(initialOffset, .1));
    final chapterEnd = controller.position.maxScrollExtent;
    controller.jumpTo(chapterEnd);
    await settle(tester);
    await volume(tester, 1);
    expect(readingChapter(tester), 1);
    await volume(tester, -1);
    expect(readingChapter(tester), 0);
    expect(controller.offset, closeTo(chapterEnd, .1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mode in ReadingMode.values) {
    testWidgets(
      '四个方向键操控阅读，跨章保持正确位置（${mode.name}）',
      (tester) async {
        final library = TransitionLibrary()..readingMode = mode;
        if (mode == ReadingMode.scroll) {
          for (final id in ['2', '3']) {
            library.contents[id] = ChapterContent([
              Paragraph(id == '2' ? '第二章正文' : '第三章正文'),
              for (var i = 0; i < 40; i++) Paragraph('章节$id段落$i'),
            ]);
          }
        }
        await open(tester, library, chapter: 1);
        if (mode == ReadingMode.scroll) {
          final view = tester.widget<SingleChildScrollView>(
            find.byType(SingleChildScrollView),
          );
          view.controller!.jumpTo(0);
          await settle(tester);
        }
        expect(enabledCalls.where((enabled) => enabled), isEmpty);
        for (final key in [
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowUp,
        ]) {
          await tester.sendKeyEvent(key);
          await settle(tester);
          expect(readingChapter(tester), 0);
          expect(find.textContaining('上一章结尾标记').hitTestable(), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await settle(tester);
          expect(readingChapter(tester), 1);
        }
        if (mode == ReadingMode.scroll) {
          final view = tester.widget<SingleChildScrollView>(
            find.byType(SingleChildScrollView),
          );
          view.controller!.jumpTo(view.controller!.position.maxScrollExtent);
        } else {
          await tester.tap(find.text('　　第二章正文'));
        }
        await settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await settle(tester);
        expect(readingChapter(tester), 2);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets('目录、设置和后台暂停音量键，返回阅读后恢复', (tester) async {
    final library = TransitionLibrary()..readingMode = ReadingMode.paged;
    await open(tester, library, chapter: 1);
    for (final tooltip in ['目录', '阅读设置']) {
      await showReadingControls(tester);
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      expect(enabledCalls.last, isFalse);
      await volume(tester, 1);
      expect(library.requests, ['2']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(library.requests, ['2']);
      Navigator.of(tester.element(find.byType(ReaderPage))).pop();
      await settle(tester);
      expect(enabledCalls.last, isTrue);
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(enabledCalls.last, isFalse);
    await volume(tester, 1);
    expect(library.requests, ['2', '2']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(enabledCalls.last, isTrue);
    await volume(tester, 1);
    expect(readingChapter(tester), 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('关闭音量键翻页后仍可使用方向键', (tester) async {
    final library = TransitionLibrary()..readingMode = ReadingMode.paged;
    await open(tester, library, chapter: 1);
    library.volumeKeyPaging = false;
    await library.save();
    await tester.pump();
    expect(enabledCalls.last, isFalse);
    await volume(tester, 1);
    expect(readingChapter(tester), 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(readingChapter(tester), 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('音量键开关仅 Android 显示，恢复默认重新启用', (tester) async {
    final library = TransitionLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReadingSettings(library: library),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('reading-volume-keys'));
      if (platform == TargetPlatform.windows) {
        expect(toggle, findsNothing);
      } else {
        expect(toggle, findsOneWidget);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(library.volumeKeyPaging, isFalse);
        await tester.ensureVisible(find.text('恢复默认阅读设置'));
        await tester.tap(find.text('恢复默认阅读设置'));
        await tester.pumpAndSettle();
        expect(library.volumeKeyPaging, isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    debugDefaultTargetPlatformOverride = null;
  });

  test('音量键设置持久化，旧书库默认启用', () async {
    final root = await Directory.systemTemp.createTemp('unr-reading-keys-');
    addTearDown(() => root.delete(recursive: true));
    final api = SfacgApi();
    addTearDown(api.close);
    final source = SfacgSource(api);
    final library = await Library.open(source, directory: root);
    addTearDown(library.dispose);
    expect(library.volumeKeyPaging, isTrue);
    library.volumeKeyPaging = false;
    await library.save();
    final reopened = await Library.open(source, directory: root);
    addTearDown(reopened.dispose);
    expect(reopened.volumeKeyPaging, isFalse);
    await File(
      '${root.path}/index.json',
    ).writeAsString(jsonEncode({'books': []}));
    final legacy = await Library.open(source, directory: root);
    addTearDown(legacy.dispose);
    expect(legacy.volumeKeyPaging, isTrue);
  });
}
