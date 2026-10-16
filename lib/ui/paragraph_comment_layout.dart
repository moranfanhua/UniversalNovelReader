import 'dart:math' as math;
import 'package:flutter/painting.dart';
import '../domain/reading_preferences.dart';

/// Shared by pagination and rendering so badges never change measured wrapping.
class ParagraphCommentLayout {
  static const extent = 28.0;
  static const edge = 2.0;
  static const gap = 4.0;

  static double textWidth(
    double width,
    double rightInset,
    bool comments,
    ParagraphCommentPlacement placement,
  ) => math.max(
    1,
    width -
        (comments && placement == ParagraphCommentPlacement.right
            ? math.max(rightInset, extent + edge + gap)
            : rightInset),
  );

  static Offset offset(
    TextPainter painter,
    double width,
    ParagraphCommentPlacement placement,
  ) {
    final line = painter.computeLineMetrics().last;
    final top = math.max(
      0.0,
      line.baseline + (line.descent - line.ascent - extent) / 2,
    );
    final right = math.max(0.0, width - extent - edge);
    if (placement == ParagraphCommentPlacement.right) return Offset(right, top);
    final left = line.left + line.width + gap;
    // A full last line gets a badge line; existing text keeps its wrapping.
    return left <= right ? Offset(left, top) : Offset(0, painter.height);
  }
}
