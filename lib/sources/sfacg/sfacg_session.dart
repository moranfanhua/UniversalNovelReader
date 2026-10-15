import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'sfacg_api.dart';
import '../../data/app_log.dart';

class SfacgSession {
  static const _key = 'unr.sfacg.session.v1';
  static const _storage = FlutterSecureStorage();
  static Future<SfacgApi> open({
    FlutterSecureStorage storage = _storage,
  }) async {
    late SfacgApi api;
    var migrated = false;
    try {
      final value = await storage.read(key: _key);
      final json = value == null
          ? <String, dynamic>{}
          : jsonDecode(value) as Map<String, dynamic>;
      final savedDevice = json['device'] as String?;
      final savedAgent = json['appUserAgent'] as String?;
      // Upgrade only the reader-generated legacy UNR profile. Captured App
      // request profiles must keep their original device identity.
      migrated =
          savedDevice != null &&
          json['website'] != true &&
          savedAgent == null &&
          json['protocolProfile'] == null;
      api = SfacgApi(
        device: migrated ? null : savedDevice,
        nonce: json['nonce'],
        appUserAgent: savedAgent,
      );
      try {
        if (json['cookie'] != null) {
          api.setCookie(
            json['cookie'] as String,
            website: json['website'] == true,
          );
          if (api.websiteSession) {
            api.sessionNotice = '已停止使用旧网页会话，请使用账号密码登录或导入 App 会话。原会话数据已保留。';
          }
        }
      } catch (_) {
        api.close();
        rethrow;
      }
    } catch (error, stack) {
      AppLog.instance.record(
        LogLevel.warning,
        'session.sfacg.restore_failed',
        error: error,
        stackTrace: stack,
      );
      // Account restoration must not prevent reading the independent book cache.
      // Keep the stored value intact until the user logs in or logs out.
      api = SfacgApi()..sessionNotice = '无法恢复本机菠萝包会话，请重新登录。本地书库仍可使用。';
    }
    api.onSessionChanged = () async {
      if (!api.hasSession && !api.websiteSession) {
        await storage.delete(key: _key);
        return;
      }
      try {
        await storage.write(
          key: _key,
          value: jsonEncode({
            'device': api.device,
            'nonce': api.nonce,
            if (api.websiteSession) 'website': true,
            'protocolProfile': SfacgApi.protocolProfile,
            if (api.appUserAgent != null) 'appUserAgent': api.appUserAgent,
            'cookie': api.cookies.entries
                .map((e) => '${e.key}=${e.value}')
                .join('; '),
          }),
        );
        api.sessionNotice = null;
      } catch (error, stack) {
        AppLog.instance.record(
          LogLevel.error,
          'session.sfacg.save_failed',
          error: error,
          stackTrace: stack,
        );
        api.sessionNotice = '登录成功，但无法写入本机安全存储。本次会话有效，重启后需重新登录。';
      }
    };
    if (migrated && api.hasSession) await api.onSessionChanged!();
    return api;
  }

  static Future<void> logout(SfacgApi api) async {
    api.cookies.clear();
    api.websiteSession = false;
    await _storage.delete(key: _key);
    api.sessionNotice = null;
  }
}
