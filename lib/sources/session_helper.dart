import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SessionHelper {
  static const _channel = MethodChannel('unr/session_helper');
  static const _events = EventChannel('unr/session_helper/events');
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static Stream<Map<String, dynamic>> get events => _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));
  static Future<Map<String, dynamic>> prepare(String source) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('prepare', {
              'source': source,
            }) ??
            {},
      );
  static Future<Map<String, dynamic>> start(String source) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('start', {
              'source': source,
            }) ??
            {},
      );
  static Future<String?> installCertificate() =>
      _channel.invokeMethod<String>('installCertificate');
  static Future<void> certificateSettings() =>
      _channel.invokeMethod<void>('certificateSettings');
  static Future<void> stop() => _channel.invokeMethod<void>('stop');
  static Future<void> openApp(String source) =>
      _channel.invokeMethod<void>('openApp', {'source': source});
  static Future<String?> captureResult(String source) =>
      _channel.invokeMethod<String>('captureResult', {'source': source});
  static Future<String?> openLogin(String source) => _channel
      .invokeMethod<String>('openLogin', {'source': source, 'vpn': false});
}
