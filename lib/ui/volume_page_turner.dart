import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Android consumes volume keys only while the reader is the foreground route.
class VolumePageTurner extends StatefulWidget {
  const VolumePageTurner({
    super.key,
    required this.enabled,
    required this.onTurn,
    required this.child,
  });
  final bool enabled;
  final ValueChanged<int> onTurn;
  final Widget child;
  @override
  State<VolumePageTurner> createState() => _VolumePageTurnerState();
}

class _VolumePageTurnerState extends State<VolumePageTurner>
    with WidgetsBindingObserver {
  static const channel = MethodChannel('unr/reader_volume_keys');
  bool active = false, current = false;
  late bool foreground;
  late final bool supported;

  @override
  void initState() {
    super.initState();
    supported = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (supported) {
      WidgetsBinding.instance.addObserver(this);
      channel.setMethodCallHandler((call) async {
        if (call.method == 'turnPage' &&
            active &&
            (call.arguments == -1 || call.arguments == 1)) {
          widget.onTurn(call.arguments as int);
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    current = ModalRoute.isCurrentOf(context) == true;
    _sync();
  }

  @override
  void didUpdateWidget(VolumePageTurner oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final next = supported && widget.enabled && current && foreground;
    if (active == next) return;
    active = next;
    unawaited(_setEnabled(next));
  }

  Future<void> _setEnabled(bool enabled) async {
    try {
      await channel.invokeMethod<void>('setEnabled', enabled);
    } on MissingPluginException {
      // The Android host is absent in widget tests and older running binaries.
    }
  }

  @override
  void dispose() {
    if (supported) {
      active = false;
      channel.setMethodCallHandler(null);
      unawaited(_setEnabled(false));
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
