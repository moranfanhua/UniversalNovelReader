import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'fanqie_api.dart';
import '../../data/app_log.dart';

class FanqieSession {
  static const _key = 'unr.fanqie.session.v1';
  static const _deviceKey = 'unr.fanqie.device.v1';
  static const _storage = FlutterSecureStorage();

  static Future<FanqieApi> open({
    FlutterSecureStorage storage = _storage,
  }) async {
    final api = FanqieApi();
    try {
      final cookie = await storage.read(key: _key);
      if (cookie != null) api.setCookie(cookie);
    } catch (error, stack) {
      AppLog.instance.record(
        LogLevel.warning,
        'session.fanqie.restore_failed',
        error: error,
        stackTrace: stack,
      );
      api.sessionNotice = '无法恢复本机番茄会话，请重新导入。已缓存章节仍可阅读。';
    }
    try {
      final device = await storage.read(key: _deviceKey);
      if (device != null) {
        api.app.restore(jsonDecode(device) as Map<String, dynamic>);
      }
    } catch (error, stack) {
      AppLog.instance.record(
        LogLevel.warning,
        'session.fanqie.device_restore_failed',
        error: error,
        stackTrace: stack,
      );
      api.sessionNotice ??= '无法恢复番茄本机设备，将在下次联网时重新注册。已缓存章节仍可阅读。';
    }
    api.onSessionChanged = () async {
      try {
        if (api.hasSession) {
          await storage.write(key: _key, value: api.cookie);
        } else {
          await storage.delete(key: _key);
        }
        if (api.app.deviceId.isNotEmpty) {
          await storage.write(
            key: _deviceKey,
            value: jsonEncode(api.app.toJson()),
          );
        }
        api.sessionNotice = null;
      } catch (error, stack) {
        AppLog.instance.record(
          LogLevel.error,
          'session.fanqie.save_failed',
          error: error,
          stackTrace: stack,
        );
        api.sessionNotice = '无法写入本机安全存储，重启后需重新导入番茄会话。';
      }
    };
    return api;
  }

  static Future<void> logout(FanqieApi api) async {
    await _storage.delete(key: _key);
    api.clearSession();
    api.sessionNotice = null;
  }
}
