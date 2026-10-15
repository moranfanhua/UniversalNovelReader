import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// Preserve the framework/engine's reporting behavior after recording an error.
VoidCallback installErrorLogging(AppLog log) {
  final flutterHandler = FlutterError.onError;
  final platformHandler = PlatformDispatcher.instance.onError;
  FlutterError.onError = (details) {
    log.record(
      LogLevel.error,
      'app.flutter_error',
      error: details.exception,
      stackTrace: details.stack,
    );
    if (flutterHandler != null) {
      flutterHandler(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.record(
      LogLevel.error,
      'app.unhandled_error',
      error: error,
      stackTrace: stack,
    );
    return platformHandler?.call(error, stack) ?? false;
  };
  return () {
    FlutterError.onError = flutterHandler;
    PlatformDispatcher.instance.onError = platformHandler;
  };
}
