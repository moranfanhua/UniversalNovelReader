import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'fanqie_api.dart';

class FanqieSession {
  static const _key = 'unr.fanqie.session.v1';
  static const _storage = FlutterSecureStorage();

  static Future<FanqieApi> open({
    FlutterSecureStorage storage = _storage,
  }) async {
    final api = FanqieApi();
    try {
      final cookie = await storage.read(key: _key);
      if (cookie != null) api.setCookie(cookie);
    } catch (_) {
      api.sessionNotice = '无法恢复本机番茄会话，请重新导入。已缓存章节仍可阅读。';
    }
    api.onSessionChanged = () async {
      try {
        if (api.hasSession) {
          await storage.write(key: _key, value: api.cookie);
        } else {
          await storage.delete(key: _key);
        }
        api.sessionNotice = null;
      } catch (_) {
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
