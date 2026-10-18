import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../domain/reading_preferences.dart';
import 'reading_layout.dart';
import 'text_pagination.dart';
import 'reading_text_layout.dart';
import 'reading_heading.dart';

class ChapterPageLayout {
  ChapterPageLayout(
    BuildContext context,
    Size viewport, {
    required double fontSize,
    required double horizontalMargin,
    required double verticalMargin,
    required double lineHeight,
    required this.comments,
    this.commentPlacement = ParagraphCommentPlacement.right,
    String? fontFamily,
    double footerHeight = 0,
    bool paged = true,
  }) {
    columns = paged ? ReadingLayout.columns(viewport.width) : 1;
    commentRightInset = horizontalMargin;
    canvasWidth = ReadingLayout.canvasWidth(viewport.width, paged: paged);
    // Each page owns its right margin so edge badges remain inside hit bounds.
    // Keep the existing central gap when the margins already fit within it.
    gutter = columns == 2
        ? (ReadingLayout.gutter - horizontalMargin * 2).clamp(
            0.0,
            double.infinity,
          )
        : 0;
    width = ((canvasWidth - gutter) / columns - horizontalMargin * 2).clamp(
      1.0,
      double.infinity,
    );
    textLayout = ReadingTextLayout.of(
      context,
      style: Theme.of(context).textTheme.bodyLarge!.copyWith(
        fontSize: fontSize,
        fontFamily: fontFamily,
        height: lineHeight,
      ),
    );
    style = textLayout.style;
    headingStyle = Theme.of(context).textTheme.headlineSmall!;
    scaler = MediaQuery.textScalerOf(context);
    direction = Directionality.of(context);
    locale = Localizations.maybeLocaleOf(context);
    final sample = TextPainter(
      text: TextSpan(text: '国', style: style),
      textScaler: scaler,
      textDirection: direction,
      locale: locale,
    )..layout(maxWidth: width);
    minimum = sample.height + 18;
    sample.dispose();
    margin = verticalMargin.clamp(
      0.0,
      ((viewport.height - footerHeight - minimum) / 2).clamp(
        0.0,
        verticalMargin,
      ),
    );
    height = (viewport.height - footerHeight - margin * 2).clamp(
      1.0,
      double.infinity,
    );
  }

  final bool comments;
  final ParagraphCommentPlacement commentPlacement;
  late final int columns;
  late final double canvasWidth, width, height, margin, minimum, gutter;
  late final double commentRightInset;
  late final TextStyle style, headingStyle;
  late final ReadingTextLayout textLayout;
  late final TextScaler scaler;
  late final TextDirection direction;
  late final Locale? locale;
  Object get signature => (
    columns,
    width,
    height,
    style,
    headingStyle,
    scaler,
    direction,
    locale,
    comments,
    commentPlacement,
    commentRightInset,
    textLayout.signature,
  );

  double headingSpace(String title, {bool titleComments = false}) {
    final heading = ReadingHeading.measure(
      text: title,
      style: headingStyle,
      width: width + commentRightInset,
      rightInset: commentRightInset,
      scaler: scaler,
      direction: direction,
      placement: commentPlacement,
      comments: comments && titleComments,
      maxLines: 2,
      locale: locale,
    );
    final space = (heading.height + 24).clamp(
      0.0,
      (height - minimum).clamp(0.0, double.infinity),
    );
    return space;
  }

  List<List<PageFragment>> paginate(
    ChapterContent content,
    String title, {
    bool titleComments = false,
  }) => TextPagination.paginate(
    content.paragraphs,
    width: width,
    height: height,
    style: style,
    scaler: scaler,
    direction: direction,
    locale: locale,
    comments: comments,
    commentPlacement: commentPlacement,
    commentRightInset: commentRightInset,
    headingSpace: headingSpace(title, titleComments: titleComments),
    textLayout: textLayout,
  );
}
