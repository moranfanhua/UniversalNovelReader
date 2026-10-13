import 'dart:math' as math;

class ReadingLayout {
  static const singleWidth = 1080.0;
  static const spreadWidth = 1760.0;
  static const spreadBreakpoint = 1200.0;
  static const gutter = 48.0;

  static int columns(double viewportWidth) =>
      viewportWidth >= spreadBreakpoint ? 2 : 1;

  static double canvasWidth(double viewportWidth, {bool paged = false}) =>
      math.min(
        viewportWidth,
        paged && columns(viewportWidth) == 2 ? spreadWidth : singleWidth,
      );
}
