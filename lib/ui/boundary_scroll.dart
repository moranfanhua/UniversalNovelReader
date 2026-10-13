import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Advances only on user input past a scroll boundary, never on layout changes
/// or a ballistic animation that happens to reach the end of a chapter.
class BoundaryScroll extends StatefulWidget {
  const BoundaryScroll({
    super.key,
    required this.child,
    required this.axis,
    this.onPrevious,
    this.onNext,
  });
  final Widget child;
  final Axis axis;
  final VoidCallback? onPrevious, onNext;
  @override
  State<BoundaryScroll> createState() => _BoundaryScrollState();
}

class _BoundaryScrollState extends State<BoundaryScroll> {
  double distance = 0;
  bool pan = false, fired = false;
  ScrollMetrics? metrics;

  bool _scroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != widget.axis) {
      return false;
    }
    metrics = notification.metrics;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      distance = 0;
      fired = false;
    }
    if (notification is ScrollEndNotification) {
      distance = 0;
      fired = false;
    }
    if (notification is! OverscrollNotification ||
        fired ||
        (notification.dragDetails == null && !pan)) {
      return false;
    }
    final delta = notification.overscroll;
    if (delta == 0) return false;
    if (distance * delta < 0) distance = 0;
    distance += delta;
    if (distance.abs() < 48) return false;
    final action = delta < 0 ? widget.onPrevious : widget.onNext;
    if (action != null) {
      fired = true;
      action();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent) return;
      final current = metrics;
      if (current == null) return;
      final delta = widget.axis == Axis.vertical
          ? event.scrollDelta.dy
          : event.scrollDelta.dx;
      final action = delta < 0 && current.extentBefore <= 0.5
          ? widget.onPrevious
          : delta > 0 && current.extentAfter <= 0.5
          ? widget.onNext
          : null;
      if (action != null) {
        // Inner scrollables get first refusal; consume only an otherwise
        // unhandled wheel event at this viewport's boundary.
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {
          if (mounted) action();
        });
      }
    },
    onPointerPanZoomStart: (_) {
      pan = true;
      distance = 0;
      fired = false;
    },
    onPointerPanZoomEnd: (_) => pan = false,
    child: NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == widget.axis) {
          metrics = notification.metrics;
        }
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _scroll,
        child: widget.child,
      ),
    ),
  );
}
