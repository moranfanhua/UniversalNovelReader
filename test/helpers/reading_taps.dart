import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/ui/reading_tap_zones.dart';

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
