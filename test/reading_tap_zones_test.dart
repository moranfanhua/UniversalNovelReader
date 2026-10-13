import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/ui/reader.dart';
import 'package:unr/ui/reading_tap_zones.dart';
import 'chapter_transition_test.dart' show TransitionLibrary, transitionBook;
import 'helpers/reading_taps.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
  }

  Future<void> mount(
    WidgetTester tester,
    List<int> turns, {
    VoidCallback? button,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReadingTapZones(
            onTurn: turns.add,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SelectableText(
                  '这段正文可点击翻页，也可选取文字',
                  style: TextStyle(fontSize: 24),
                ),
                const Expanded(child: SizedBox.expand()),
                if (button != null)
                  ExcludeReadingTap(
                    child: TextButton(
                      onPressed: button,
                      child: const Text('互动操作'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('正文和留白的左右半边均可点击翻页', (tester) async {
    final turns = <int>[];
    await mount(tester, turns);
    final text = tester.getRect(find.byType(SelectableText));
    await tester.tapAt(text.topLeft + const Offset(30, 15));
    await settle(tester);
    expect(turns, [-1]);
    await tapReadingSide(tester, 1);
    await tester.pumpAndSettle();
    expect(turns, [-1, 1]);
    await tapReadingSide(tester, -1);
    await tester.pumpAndSettle();
    expect(turns, [-1, 1, -1]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长按、双击、拖动、多指及鼠标右键均不误触翻页', (tester) async {
    final turns = <int>[];
    await mount(tester, turns);
    await tester.longPress(find.byType(SelectableText));
    await settle(tester);
    expect(turns, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, turns);
    final text = tester.getRect(find.byType(SelectableText));
    final position = text.topLeft + const Offset(30, 15);
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(position);
    await settle(tester);
    expect(turns, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, turns);
    final area = tester.getRect(find.byType(ReadingTapZones));
    await tester.dragFrom(area.center, const Offset(-200, 0));
    await settle(tester);
    final first = await tester.startGesture(area.center, pointer: 10);
    final second = await tester.startGesture(
      area.center + const Offset(50, 0),
      pointer: 11,
    );
    await first.up();
    await second.up();
    await settle(tester);
    final right = await tester.startGesture(
      area.center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await right.up();
    await settle(tester);
    expect(turns, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('交互控件正常执行点击，不同时触发翻页', (tester) async {
    final turns = <int>[];
    var actions = 0;
    await mount(tester, turns, button: () => actions++);
    await tester.tap(find.text('互动操作'));
    await settle(tester);
    expect(actions, 1);
    expect(turns, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点击后打开面板会取消等待中的翻页', (tester) async {
    final turns = <int>[];
    await mount(tester, turns);
    final context = tester.element(find.byType(ReadingTapZones));
    final area = tester.getRect(find.byType(ReadingTapZones));
    await tester.tapAt(area.centerRight - const Offset(20, 0));
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => const SizedBox(height: 100, child: Text('面板')),
    );
    await settle(tester);
    expect(turns, isEmpty);
    Navigator.of(context).pop();
    await settle(tester);
    expect(turns, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mode in ReadingMode.values) {
    testWidgets(
      mode == ReadingMode.scroll ? '滚动模式点击两侧不会翻页或切章' : '移除翻页按钮后两侧点击仍可衔接章节',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final library = TransitionLibrary()..readingMode = mode;
        addTearDown(library.dispose);
        addTearDown(library.source.api.close);
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(
              library: library,
              book: transitionBook,
              initialChapter: 1,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextButton, '上一页'), findsNothing);
        expect(find.widgetWithText(TextButton, '下一页'), findsNothing);
        if (mode == ReadingMode.scroll) {
          expect(find.byType(ReadingTapZones), findsNothing);
          final view = find.byType(SingleChildScrollView);
          final controller = tester
              .widget<SingleChildScrollView>(view)
              .controller!;
          final offset = controller.offset;
          final bounds = tester.getRect(view);
          for (final x in [bounds.left + 5, bounds.right - 5]) {
            await tester.tapAt(Offset(x, bounds.center.dy));
            await settle(tester);
          }
          expect(controller.offset, offset);
          expect(library.requests, ['2']);
          expect(find.text('2 / 3'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          return;
        }
        await tapReadingSide(tester, 1);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('3 / 3'), findsOneWidget);
        await tapReadingSide(tester, -1);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('2 / 3'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
