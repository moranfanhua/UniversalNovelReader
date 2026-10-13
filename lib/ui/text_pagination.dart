import 'package:flutter/painting.dart';
import '../domain/models.dart';

class PageFragment {
  const PageFragment(
    this.paragraph,
    this.offset,
    this.text,
    this.height, {
    this.image = false,
  });
  final int paragraph, offset;
  final String text;
  final double height;
  final bool image;
}

class TextPagination {
  static List<List<PageFragment>> paginate(
    List<Paragraph> paragraphs, {
    required double width,
    required double height,
    required TextStyle style,
    required TextScaler scaler,
    required TextDirection direction,
    double headingSpace = 0,
    bool comments = false,
    Locale? locale,
  }) {
    final pages = <List<PageFragment>>[[]];
    var used = headingSpace;
    void next() {
      pages.add([]);
      used = 0;
    }

    for (var index = 0; index < paragraphs.length; index++) {
      final paragraph = paragraphs[index];
      final badge = comments && paragraph.remoteIndex != null;
      if (paragraph.image != null) {
        if (used > 0) next();
        final imageHeight = (height - 18).clamp(1.0, height);
        pages.last.add(PageFragment(index, 0, '', imageHeight, image: true));
        used = height;
        continue;
      }
      final text = '　　${paragraph.text}';
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textScaler: scaler,
        textDirection: direction,
        locale: locale,
      )..layout(maxWidth: (width - (badge ? 56 : 0)).clamp(1.0, width));
      final ends = <int>[];
      for (final line in painter.computeLineMetrics()) {
        final position = painter.getPositionForOffset(
          Offset(line.left, line.baseline - line.ascent / 2),
        );
        var end = painter.getLineBoundary(position).end;
        if (end < text.length && text.codeUnitAt(end) == 10) end++;
        if (ends.isEmpty || end > ends.last) ends.add(end);
      }
      if (ends.isEmpty || ends.last != text.length) ends.add(text.length);
      var start = 0, line = 0;
      while (start < text.length) {
        final room = height - used - 18;
        if (room < painter.preferredLineHeight || (badge && room < 40)) {
          if (used > 0) {
            next();
            continue;
          }
        }
        var best = line;
        var bestHeight = 0.0;
        for (var candidate = line; candidate < ends.length; candidate++) {
          final fragment = text.substring(start, ends[candidate]);
          final measure = TextPainter(
            text: TextSpan(text: fragment, style: style),
            textScaler: scaler,
            textDirection: direction,
            locale: locale,
          )..layout(maxWidth: (width - (badge ? 56 : 0)).clamp(1.0, width));
          final measured = badge
              ? measure.height.clamp(40.0, double.infinity)
              : measure.height;
          measure.dispose();
          if (measured > room && candidate > line) break;
          best = candidate;
          bestHeight = measured;
          if (measured > room) break;
        }
        final end = ends[best];
        pages.last.add(
          PageFragment(
            index,
            (start - 2).clamp(0, paragraph.text.length),
            text.substring(start, end),
            bestHeight,
          ),
        );
        used += bestHeight + 18;
        start = end;
        line = best + 1;
        if (start < text.length) next();
      }
      painter.dispose();
    }
    if (pages.length > 1 && pages.last.isEmpty) pages.removeLast();
    return pages;
  }
}
