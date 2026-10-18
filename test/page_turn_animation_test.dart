import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/domain/reading_preferences.dart';
import 'package:unr/ui/paged_chapter.dart';

void main() {
  Future<GlobalKey> mount(
    WidgetTester tester,
    PageTurnAnimation animation, {
    bool disableAnimations = false,
    TextDirection direction = TextDirection.ltr,
  }) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: RepaintBoundary(
                key: capture,
                child: PagedChapter(
                  content: const ChapterContent([
                    Paragraph('', image: 'red'),
                    Paragraph('', image: 'blue'),
                    Paragraph('', image: 'green'),
                  ]),
                  title: '翻页动画测试',
                  fontSize: 20,
                  initialParagraph: 0,
                  initialOffset: 0,
                  comments: false,
                  showPageIndicator: false,
                  pageTurnAnimation: animation,
                  onPosition: (_, _, _) {},
                  imageBuilder: (url) => SizedBox.expand(
                    child: ColoredBox(
                      color: switch (url) {
                        'red' => Colors.red,
                        'blue' => Colors.blue,
                        _ => Colors.green,
                      },
                    ),
                  ),
                  commentBuilder: (_) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return capture;
  }

  Future<Uint8List> pixels(WidgetTester tester, GlobalKey capture) async {
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;
  }

  int colorAt(Uint8List data, int x, int y) {
    final offset = (y * 360 + x) * 4;
    return Color.fromARGB(
      data[offset + 3],
      data[offset],
      data[offset + 1],
      data[offset + 2],
    ).toARGB32();
  }

  PagedChapterState pager(WidgetTester tester) =>
      tester.state<PagedChapterState>(find.byType(PagedChapter));

  testWidgets('无动画拖动时整页静止并直接切换，点击翻页无需等待动画', (tester) async {
    final capture = await mount(tester, PageTurnAnimation.none);
    final initial = await pixels(tester, capture);
    expect(colorAt(initial, 60, 200), Colors.red.toARGB32());
    final gesture = await tester.startGesture(const Offset(300, 300));
    await gesture.moveBy(const Offset(-90, 0));
    await tester.pump();
    expect(await pixels(tester, capture), orderedEquals(initial));
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();
    final changed = await pixels(tester, capture);
    expect(colorAt(changed, 60, 200), Colors.blue.toARGB32());
    expect(colorAt(changed, 300, 200), Colors.blue.toARGB32());
    await gesture.up();
    await tester.pumpAndSettle();
    final state = pager(tester);
    final before = state.page;
    await state.turnPage(1);
    await tester.pump();
    expect(state.page, before + 1);
    expect(state.controller!.position.isScrollingNotifier.value, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final direction in TextDirection.values) {
    testWidgets('仿真翻页保留两侧正文并显示纸张背面，反向拖动可取消（${direction.name}）', (tester) async {
      final capture = await mount(
        tester,
        PageTurnAnimation.simulation,
        direction: direction,
      );
      final state = pager(tester);
      final before = state.page;
      final initial = await pixels(tester, capture);
      final rtl = direction == TextDirection.rtl;
      final gesture = await tester.startGesture(Offset(rtl ? 60 : 300, 300));
      await gesture.moveBy(Offset(rtl ? 170 : -170, 0));
      await tester.pump();
      final turning = await pixels(tester, capture);
      expect(colorAt(turning, rtl ? 300 : 60, 200), Colors.red.toARGB32());
      expect(colorAt(turning, rtl ? 50 : 310, 200), Colors.blue.toARGB32());
      final fold = colorAt(turning, rtl ? 110 : 250, 200);
      expect(fold, isNot(Colors.red.toARGB32()));
      expect(fold, isNot(Colors.blue.toARGB32()));
      await gesture.moveBy(Offset(rtl ? -150 : 150, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(state.page, before);
      expect(await pixels(tester, capture), orderedEquals(initial));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(state.page, before + 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(state.page, before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('系统关闭动画时仿真翻页也直接切页', (tester) async {
    await mount(tester, PageTurnAnimation.simulation, disableAnimations: true);
    final state = pager(tester);
    final before = state.page;
    await state.turnPage(1);
    await tester.pump();
    expect(state.page, before + 1);
    expect(state.controller!.position.isScrollingNotifier.value, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
