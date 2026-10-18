import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../domain/reading_preferences.dart';
import 'paragraph_comment_layout.dart';
import 'reading_tap_zones.dart';

/// Title layout shared with pagination, including space for its comment badge.
class ReadingHeading extends StatelessWidget {
  const ReadingHeading({
    super.key,
    required this.text,
    required this.style,
    required this.rightInset,
    required this.placement,
    this.comment,
    this.maxLines,
  });
  final String text;
  final TextStyle style;
  final double rightInset;
  final ParagraphCommentPlacement placement;
  final Widget? comment;
  final int? maxLines;

  static ({double width, double height, Offset? badge}) measure({
    required String text,
    required TextStyle style,
    required double width,
    required double rightInset,
    required TextScaler scaler,
    required TextDirection direction,
    required ParagraphCommentPlacement placement,
    required bool comments,
    Locale? locale,
    int? maxLines,
  }) {
    final textWidth = ParagraphCommentLayout.textWidth(
      width,
      rightInset,
      comments,
      placement,
    );
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: scaler,
      textDirection: direction,
      locale: locale,
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
    )..layout(maxWidth: textWidth);
    final badge = comments
        ? ParagraphCommentLayout.offset(painter, width, placement)
        : null;
    final height = math.max(
      painter.height,
      badge == null ? 0.0 : badge.dy + ParagraphCommentLayout.extent,
    );
    painter.dispose();
    return (width: textWidth, height: height, badge: badge);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final layout = measure(
        text: text,
        style: style,
        width: constraints.maxWidth,
        rightInset: rightInset,
        scaler: MediaQuery.textScalerOf(context),
        direction: Directionality.of(context),
        locale: Localizations.maybeLocaleOf(context),
        placement: placement,
        comments: comment != null,
        maxLines: maxLines,
      );
      return SizedBox(
        width: constraints.maxWidth,
        height: layout.height,
        child: Stack(
          children: [
            SizedBox(
              width: layout.width,
              child: Text(
                text,
                style: style,
                maxLines: maxLines,
                overflow: maxLines == null
                    ? TextOverflow.clip
                    : TextOverflow.ellipsis,
              ),
            ),
            if (comment != null)
              Positioned(
                left: layout.badge!.dx,
                top: layout.badge!.dy,
                child: ExcludeReadingTap(child: comment!),
              ),
          ],
        ),
      );
    },
  );
}
