import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/ui/reading_tap_zones.dart';
import 'package:unr/ui/reader.dart';
import 'package:unr/ui/paged_chapter.dart';

Future<void> showReadingControls(WidgetTester tester) async {
  if (find.byTooltip('阅读设置').evaluate().isEmpty) {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
  }
}

int readingChapter(WidgetTester tester) =>
    (tester.state(find.byType(ReaderPage)) as dynamic).chapter as int;

PagedChapterState readingPager(WidgetTester tester) =>
    tester.state<PagedChapterState>(find.byType(PagedChapter));

Future<void> tapReadingSide(WidgetTester tester, int delta) async {
  final bounds = tester.getRect(find.byType(ReadingTapZones).hitTestable());
  await tester.tapAt(
    Offset(
      bounds.left + bounds.width * (delta < 0 ? .1 : .9),
      bounds.top + bounds.height * .85,
    ),
  );
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
}
