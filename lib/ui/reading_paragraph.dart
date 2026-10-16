import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../domain/reading_preferences.dart';
import 'paragraph_comment_layout.dart';
import 'reading_tap_zones.dart';

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
      final scaler = textScaler ?? MediaQuery.textScalerOf(context);
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
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textScaler: scaler,
        textDirection: Directionality.of(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout(maxWidth: textWidth);
      final offset = comment == null
          ? null
          : ParagraphCommentLayout.offset(painter, width, placement);
      final textHeight = painter.height;
      final height = math.max(
        painter.height,
        offset == null ? 0.0 : offset.dy + ParagraphCommentLayout.extent,
      );
      painter.dispose();
      return SizedBox(
        width: width,
        height: height,
        child: Stack(
          children: [
            SizedBox(
              width: textWidth,
              height: textHeight,
              child: SelectableText(text, style: style, textScaler: scaler),
            ),
            if (offset != null)
              Positioned(
                left: offset.dx,
                top: offset.dy,
                child: ExcludeReadingTap(child: comment!),
              ),
          ],
        ),
      );
    },
  );
}
