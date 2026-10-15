import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/app_log.dart';
import 'qidian_api.dart';

class QidianSession {
  static const key = 'unr.qidian.session.v1';

  static Future<QidianApi> open({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) async {
    QidianApi? api;
    try {
      final saved = await storage.read(key: key);
      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        api = QidianApi(device: data['device'] as String);
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
      api ??= QidianApi();
      api.sessionNotice = '无法恢复起点会话，原存储已保留，请重新登录。已缓存章节仍可阅读。';
    }
    final result = api ?? QidianApi();
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
