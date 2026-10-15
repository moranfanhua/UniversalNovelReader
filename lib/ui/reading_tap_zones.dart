import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Observes taps without entering the selection/scroll gesture arena.
class ReadingTapZones extends StatefulWidget {
  const ReadingTapZones({
    super.key,
    required this.onTurn,
    required this.child,
    this.revision,
    this.onCenterTap,
  });
  final ValueChanged<int> onTurn;
  final Widget child;
  final Object? revision;
  final VoidCallback? onCenterTap;
  @override
  State<ReadingTapZones> createState() => _ReadingTapZonesState();
}

class _ReadingTapZonesState extends State<ReadingTapZones>
    with WidgetsBindingObserver {
  final pointers = <int>{}, excluded = <int>{};
  PointerDownEvent? down;
  Offset? pendingPosition;
  Timer? longPress, pendingTap;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.isCurrentOf(context) == false) _cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancel();
  }

  void _cancel() {
    down = null;
    longPress?.cancel();
    pendingTap?.cancel();
    pendingPosition = null;
  }

  @override
  void didUpdateWidget(ReadingTapZones oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _cancel();
  }

  void _down(PointerDownEvent event) {
    pointers.add(event.pointer);
    final doubleTap =
        pendingTap?.isActive == true &&
        pendingPosition != null &&
        (event.position - pendingPosition!).distance <= kDoubleTapSlop;
    _cancel();
    if (pointers.length != 1 ||
        excluded.contains(event.pointer) ||
        event.buttons != kPrimaryButton ||
        doubleTap) {
      return;
    }
    down = event;
    longPress = Timer(kLongPressTimeout, () => down = null);
  }

  void _move(PointerMoveEvent event) {
    final start = down;
    if (start != null &&
        (event.position - start.position).distance > kTouchSlop) {
      _cancel();
    }
  }

  void _up(PointerUpEvent event) {
    pointers.remove(event.pointer);
    final blocked = excluded.remove(event.pointer);
    final start = down;
    down = null;
    longPress?.cancel();
    if (blocked ||
        start?.pointer != event.pointer ||
        pointers.isNotEmpty ||
        (event.position - start!.position).distance > kTouchSlop) {
      return;
    }
    final box = context.findRenderObject() as RenderBox;
    final delta = event.localPosition.dx < box.size.width / 2 ? -1 : 1;
    final center =
        widget.onCenterTap != null &&
        event.localPosition.dx >= box.size.width / 3 &&
        event.localPosition.dx <= box.size.width * 2 / 3 &&
        event.localPosition.dy >= box.size.height / 3 &&
        event.localPosition.dy <= box.size.height * 2 / 3;
    pendingPosition = event.position;
    // Wait for a possible double tap so selecting text cannot also turn a page.
    pendingTap = Timer(kDoubleTapTimeout, () {
      pendingPosition = null;
      if (mounted && ModalRoute.isCurrentOf(context) != false) {
        if (center) {
          widget.onCenterTap?.call();
        } else {
          widget.onTurn(delta);
        }
      }
    });
  }

  @override
  void dispose() {
    _cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ReadingTapScope(
    state: this,
    child: Semantics(
      container: true,
      explicitChildNodes: true,
      label: '阅读区域',
      hint: widget.onCenterTap == null
          ? '点击左侧向前翻页，右侧向后翻页'
          : '点击中央切换阅读菜单，左侧向前翻页，右侧向后翻页',
      onDecrease: () => widget.onTurn(-1),
      onIncrease: () => widget.onTurn(1),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: (event) {
          pointers.remove(event.pointer);
          excluded.remove(event.pointer);
          _cancel();
        },
        child: widget.child,
      ),
    ),
  );
}

class _ReadingTapScope extends InheritedWidget {
  const _ReadingTapScope({required this.state, required super.child});
  final _ReadingTapZonesState state;
  @override
  bool updateShouldNotify(_ReadingTapScope oldWidget) => false;
}

/// Interactive content retains its own pointer action instead of paging.
class ExcludeReadingTap extends StatelessWidget {
  const ExcludeReadingTap({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) => context
        .getInheritedWidgetOfExactType<_ReadingTapScope>()
        ?.state
        .excluded
        .add(event.pointer),
    child: child,
  );
}
