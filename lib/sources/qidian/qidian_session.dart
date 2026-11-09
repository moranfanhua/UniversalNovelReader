import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/app_log.dart';
import 'qidian_api.dart';
import 'qidian_native.dart';

class QidianSession {
  static const key = 'unr.qidian.session.v1';

  static Future<QidianApi> open({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) async {
    final security = NativeQidianSecurity();
    QidianApi? api;
    var firstOpen = false;
    try {
      final saved = await storage.read(key: key);
      firstOpen = saved == null;
      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        api = QidianApi(device: data['device'] as String, security: security);
        if (data['credentials'] is Map) {
          api.credentials = QidianCredentials.fromJson(
            Map<String, dynamic>.from(data['credentials']),
          );
        }
      }
    } catch (error, stack) {
      AppLog.instance.record(
        LogLevel.warning,
        'session.qidian.restore_failed',
        error: error,
        stackTrace: stack,
      );
      api ??= QidianApi(security: security);
      api.sessionNotice = '无法恢复起点会话，原存储已保留，请重新登录。已缓存章节仍可阅读。';
    }
    final result = api ?? QidianApi(security: security);
    result.onSessionChanged = () async {
      try {
        await storage.write(
          key: key,
          value: jsonEncode({
            'device': result.device,
            'credentials': result.credentials?.toJson(),
          }),
        );
        result.sessionNotice = null;
      } catch (error, stack) {
        AppLog.instance.record(
          LogLevel.error,
          'session.qidian.save_failed',
          error: error,
          stackTrace: stack,
        );
        result.sessionNotice = '无法写入本机安全存储，重启后需要重新登录起点。';
      }
    };
    // Anonymous reads need the same local identity after a restart too. Never
    // overwrite a saved session that could not be restored.
    if (firstOpen) await result.onSessionChanged!();
    return result;
  }

  static Future<void> logout(
    QidianApi api, {
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) async {
    await storage.write(key: key, value: jsonEncode({'device': api.device}));
    api.credentials = null;
    api.sessionNotice = null;
  }
}
