import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../domain/reading_preferences.dart';

/// Paints a stationary sheet inside a PageView whose translation is cancelled
/// by the caller. Only painting changes; text, images and comments stay live.
class PageTurnEffect extends SingleChildRenderObjectWidget {
  const PageTurnEffect({
    super.key,
    required this.position,
    required this.animation,
    required this.paperColor,
    required super.child,
    this.reverse = false,
  });

  final double position;
  final PageTurnAnimation animation;
  final Color paperColor;
  final bool reverse;

  @override
  RenderPageTurnEffect createRenderObject(BuildContext context) =>
      RenderPageTurnEffect(position, animation, paperColor, reverse);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderPageTurnEffect renderObject,
  ) => renderObject.update(position, animation, paperColor, reverse);
}

class RenderPageTurnEffect extends RenderProxyBox {
  RenderPageTurnEffect(
    this.position,
    this.animation,
    this.paperColor,
    this.reverse,
  );

  double position;
  PageTurnAnimation animation;
  Color paperColor;
  bool reverse;

  void update(
    double value,
    PageTurnAnimation effect,
    Color color,
    bool reversed,
  ) {
    if (position == value &&
        animation == effect &&
        paperColor == color &&
        reverse == reversed) {
      return;
    }
    position = value;
    animation = effect;
    paperColor = color;
    reverse = reversed;
    markNeedsPaint();
  }

  Path _physical(Path path) => reverse
      ? path.transform(
          (Matrix4.translationValues(
            size.width,
            0,
            0,
          )..scaleByDouble(-1, 1, 1, 1)).storage,
        )
      : path;

  void _sheet(PaintingContext context, Offset offset) {
    context.canvas.drawRect(offset & size, Paint()..color = paperColor);
    super.paint(context, offset);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (animation == PageTurnAnimation.none) {
      if (position > -.5 && position <= .5) _sheet(context, offset);
      return;
    }
    if (position.abs() < .000001 || animation == PageTurnAnimation.slide) {
      _sheet(context, offset);
      return;
    }
    if (position <= -1 || position >= 1 || size.isEmpty) return;

    // Both neighbours derive the same fold from their relative position.
    // Reversing a drag simply unrolls the same sheet, including cancellation.
    final outgoing = position < 0;
    final progress = outgoing ? -position : 1 - position;
    final seam = size.width * (1 - progress);
    final curl = math.sin(progress * math.pi) * size.width * .18;
    final bend = curl * .18;
    final edge = seam + curl;
    final front = Path()
      ..lineTo(seam, 0)
      ..quadraticBezierTo(seam + bend * 2, size.height / 2, seam, size.height)
      ..lineTo(0, size.height)
      ..close();
    final revealed = Path()
      ..moveTo(edge, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(edge, size.height)
      ..quadraticBezierTo(edge + bend * 2, size.height / 2, edge, 0)
      ..close();

    context.pushClipPath(
      needsCompositing,
      offset,
      Offset.zero & size,
      _physical(outgoing ? front : revealed),
      (context, offset) {
        _sheet(context, offset);
        if (!outgoing) {
          final shadow = math.min(24.0, curl);
          final rect = Rect.fromLTWH(edge, 0, shadow + bend, size.height);
          final physicalRect = reverse
              ? Rect.fromLTRB(
                  size.width - rect.right,
                  rect.top,
                  size.width - rect.left,
                  rect.bottom,
                )
              : rect;
          context.canvas.drawRect(
            physicalRect.shift(offset),
            Paint()
              ..shader = LinearGradient(
                begin: reverse ? Alignment.centerRight : Alignment.centerLeft,
                end: reverse ? Alignment.centerLeft : Alignment.centerRight,
                colors: [
                  Colors.black.withValues(alpha: .24),
                  Colors.transparent,
                ],
              ).createShader(physicalRect.shift(offset)),
          );
        }
      },
    );
    if (!outgoing || curl < .001) return;

    final back = Path()
      ..moveTo(seam, 0)
      ..lineTo(edge, 0)
      ..quadraticBezierTo(edge + bend * 2, size.height / 2, edge, size.height)
      ..lineTo(seam, size.height)
      ..quadraticBezierTo(seam + bend * 2, size.height / 2, seam, 0)
      ..close();
    final backColor = Color.lerp(paperColor, Colors.grey, .14)!;
    final foldRect = reverse
        ? Rect.fromLTRB(
            size.width - edge - bend,
            0,
            size.width - seam,
            size.height,
          )
        : Rect.fromLTRB(seam, 0, edge + bend, size.height);
    context.canvas.drawPath(
      _physical(back).shift(offset),
      Paint()
        ..shader = LinearGradient(
          begin: reverse ? Alignment.centerRight : Alignment.centerLeft,
          end: reverse ? Alignment.centerLeft : Alignment.centerRight,
          colors: [
            Color.lerp(backColor, Colors.black, .18)!,
            Color.lerp(backColor, Colors.white, .18)!,
            backColor,
          ],
          stops: const [0, .45, 1],
        ).createShader(foldRect.shift(offset)),
    );
  }
}
