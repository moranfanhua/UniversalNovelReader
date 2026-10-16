import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Layout inputs shared by paragraph measurement, selection and pagination.
class ReadingTextLayout {
  const ReadingTextLayout({
    required this.style,
    required this.scaler,
    required this.direction,
    this.align = TextAlign.start,
    this.widthBasis = TextWidthBasis.parent,
    this.heightBehavior,
    this.locale,
  });

  factory ReadingTextLayout.of(
    BuildContext context, {
    required TextStyle style,
    TextScaler? scaler,
  }) {
    final defaults = DefaultTextStyle.of(context);
    final inherited = style.inherit ? defaults.style.merge(style) : style;
    return ReadingTextLayout(
      style: inherited.copyWith(
        inherit: false,
        fontWeight: MediaQuery.boldTextOf(context)
            ? FontWeight.bold
            : inherited.fontWeight,
        height: MediaQuery.maybeLineHeightScaleFactorOverrideOf(context),
        letterSpacing: MediaQuery.maybeLetterSpacingOverrideOf(context),
        wordSpacing: MediaQuery.maybeWordSpacingOverrideOf(context),
      ),
      scaler: scaler ?? MediaQuery.textScalerOf(context),
      direction: Directionality.of(context),
      align: defaults.textAlign ?? TextAlign.start,
      widthBasis: defaults.textWidthBasis,
      heightBehavior:
          defaults.textHeightBehavior ??
          DefaultTextHeightBehavior.maybeOf(context),
    );
  }

  final TextStyle style;
  final TextScaler scaler;
  final TextDirection direction;
  final TextAlign align;
  final TextWidthBasis widthBasis;
  final TextHeightBehavior? heightBehavior;
  final Locale? locale;
  StrutStyle get strut => StrutStyle.fromTextStyle(style);

  // Flutter RenderEditable reserves a 1px gap plus SelectableText's cursor.
  static const cursorWidth = 2.0;
  static const caretMargin = 1.0 + cursorWidth;

  Object get signature =>
      (style, scaler, direction, align, widthBasis, heightBehavior, locale);

  TextPainter measure(String text, double width) {
    final available = math.max(0.0, width - caretMargin);
    return TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: scaler,
      textDirection: direction,
      textAlign: align,
      textWidthBasis: widthBasis,
      textHeightBehavior: heightBehavior,
      strutStyle: strut,
      locale: locale,
    )..layout(minWidth: available, maxWidth: available);
  }

  Widget selectable(String text) => SelectableText(
    text,
    style: style,
    textScaler: scaler,
    textDirection: direction,
    textAlign: align,
    textWidthBasis: widthBasis,
    textHeightBehavior: heightBehavior,
    strutStyle: strut,
    cursorWidth: cursorWidth,
  );
}
