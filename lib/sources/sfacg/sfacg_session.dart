import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'sfacg_api.dart';

class SfacgSession {
  static const _key = 'unr.sfacg.session.v1';
  static const _storage = FlutterSecureStorage();
  static Future<SfacgApi> open({
    FlutterSecureStorage storage = _storage,
  }) async {
    late SfacgApi api;
    try {
      final value = await storage.read(key: _key);
      final json = value == null
          ? <String, dynamic>{}
          : jsonDecode(value) as Map<String, dynamic>;
      api = SfacgApi(device: json['device'], nonce: json['nonce']);
      try {
        if (json['cookie'] != null) api.setCookie(json['cookie'] as String);
      } catch (_) {
        api.close();
        rethrow;
      }
    } catch (_) {
      // Account restoration must not prevent reading the independent book cache.
      // Keep the stored value intact until the user logs in or logs out.
      api = SfacgApi()..sessionNotice = '无法恢复本机菠萝包会话，请重新登录。本地书库仍可使用。';
    }
    api.onSessionChanged = () async {
      if (!api.hasSession) {
        await storage.delete(key: _key);
        return;
      }
      try {
        await storage.write(
          key: _key,
          value: jsonEncode({
            'device': api.device,
            'nonce': api.nonce,
            'cookie': api.cookies.entries
                .map((e) => '${e.key}=${e.value}')
                .join('; '),
          }),
        );
        api.sessionNotice = null;
      } catch (_) {
        api.sessionNotice = '登录成功，但无法写入本机安全存储。本次会话有效，重启后需重新登录。';
      }
    };
    return api;
  }

  static Future<void> logout(SfacgApi api) async {
    api.cookies.clear();
    await _storage.delete(key: _key);
    api.sessionNotice = null;
  }
}
