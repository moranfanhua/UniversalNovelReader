import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../domain/reading_preferences.dart';
import 'paragraph_comment_layout.dart';
import 'reading_tap_zones.dart';
import 'reading_text_layout.dart';

class ReadingParagraph extends StatelessWidget {
  const ReadingParagraph({
    super.key,
    required this.style,
    required this.rightInset,
    required this.placement,
    this.text = '',
    this.image,
    this.comment,
    this.textScaler,
  });
  final String text;
  final TextStyle style;
  final double rightInset;
  final ParagraphCommentPlacement placement;
  final Widget? image, comment;
  final TextScaler? textScaler;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final layout = ReadingTextLayout.of(
        context,
        style: style,
        scaler: textScaler,
      );
      final textWidth = ParagraphCommentLayout.textWidth(
        width,
        rightInset,
        comment != null,
        placement,
      );
      if (image != null) {
        return SizedBox(
          width: width,
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(right: width - textWidth),
                child: image!,
              ),
              if (comment != null)
                Positioned(
                  right: ParagraphCommentLayout.edge,
                  bottom: 0,
                  child: ExcludeReadingTap(child: comment!),
                ),
            ],
          ),
        );
      }
      final body = SizedBox(width: textWidth, child: layout.selectable(text));
      if (comment == null) {
        return Padding(
          padding: EdgeInsets.only(right: width - textWidth),
          child: body,
        );
      }
      final painter = layout.measure(text, textWidth);
      final offset = ParagraphCommentLayout.offset(painter, width, placement);
      final height = math.max(
        painter.height,
        offset.dy + ParagraphCommentLayout.extent,
      );
      painter.dispose();
      return SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Stack(
            children: [
              body,
              Positioned(
                left: offset.dx,
                top: offset.dy,
                child: ExcludeReadingTap(child: comment!),
              ),
            ],
          ),
        ),
      );
    },
  );
}
