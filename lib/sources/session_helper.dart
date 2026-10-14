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
  static Future<Map<String, dynamic>> prepare() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('prepare') ?? {},
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
  static Future<String?> openLogin(String source, {bool vpn = false}) =>
      _channel.invokeMethod<String>('openLogin', {
        'source': source,
        'vpn': vpn,
      });
}
