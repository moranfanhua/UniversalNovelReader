import 'package:flutter/painting.dart';
import '../domain/models.dart';
import '../domain/reading_preferences.dart';
import 'paragraph_comment_layout.dart';
import 'reading_text_layout.dart';

class PageFragment {
  const PageFragment(
    this.paragraph,
    this.offset,
    this.text,
    this.height, {
    this.image = false,
    this.endsParagraph = true,
  });
  final int paragraph, offset;
  final String text;
  final double height;
  final bool image;
  final bool endsParagraph;
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
    ParagraphCommentPlacement commentPlacement =
        ParagraphCommentPlacement.right,
    double commentRightInset = 22,
    Locale? locale,
    int? anchorParagraph,
    int anchorOffset = 0,
    ReadingTextLayout? textLayout,
  }) {
    final layout =
        textLayout ??
        ReadingTextLayout(
          style: style,
          scaler: scaler,
          direction: direction,
          locale: locale,
        );
    final pages = <List<PageFragment>>[[]];
    var used = headingSpace;
    void next() {
      pages.add([]);
      used = 0;
    }

    for (var index = 0; index < paragraphs.length; index++) {
      final paragraph = paragraphs[index];
      final badge = comments && paragraph.remoteIndex != null;
      final paragraphWidth = width + commentRightInset;
      final textWidth = ParagraphCommentLayout.textWidth(
        paragraphWidth,
        commentRightInset,
        badge,
        commentPlacement,
      );
      if (paragraph.image != null) {
        if (used > 0) next();
        final imageHeight = (height - 18).clamp(1.0, height);
        pages.last.add(PageFragment(index, 0, '', imageHeight, image: true));
        used = height;
        continue;
      }
      final text = '　　${paragraph.text}';
      final painter = layout.measure(text, textWidth);
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
      int? anchorBreak;
      if (index == anchorParagraph && (index > 0 || anchorOffset > 0)) {
        anchorBreak = 0;
        final target = (anchorOffset + 2).clamp(0, text.length);
        for (final end in ends) {
          if (end > target) break;
          anchorBreak = end;
        }
      }
      var start = 0, line = 0;
      while (start < text.length) {
        if (start == anchorBreak && used > 0) {
          next();
          continue;
        }
        final room = height - used - 18;
        if (room < painter.preferredLineHeight) {
          if (used > 0) {
            next();
            continue;
          }
        }
        var best = line;
        var bestHeight = 0.0;
        for (var candidate = line; candidate < ends.length; candidate++) {
          if (anchorBreak != null &&
              start < anchorBreak &&
              ends[candidate] > anchorBreak) {
            break;
          }
          final fragment = text.substring(start, ends[candidate]);
          final measure = layout.measure(fragment, textWidth);
          final hasBadge =
              badge &&
              (commentPlacement == ParagraphCommentPlacement.right ||
                  ends[candidate] == text.length);
          final measured = hasBadge
              ? measure.height.clamp(
                  ParagraphCommentLayout.offset(
                        measure,
                        paragraphWidth,
                        commentPlacement,
                      ).dy +
                      ParagraphCommentLayout.extent,
                  double.infinity,
                )
              : measure.height;
          measure.dispose();
          if (measured > room && candidate > line) break;
          best = candidate;
          bestHeight = measured;
          if (measured > room) break;
        }
        if (bestHeight > room && used > 0) {
          next();
          continue;
        }
        final end = ends[best];
        pages.last.add(
          PageFragment(
            index,
            (start - 2).clamp(0, paragraph.text.length),
            text.substring(start, end),
            bestHeight,
            endsParagraph: end == text.length,
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
