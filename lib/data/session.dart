import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../sources/sfacg_api.dart';

class SfacgSession {
  static const _key = 'unr.sfacg.session.v1';
  static const _storage = FlutterSecureStorage();
  static Future<SfacgApi> open() async {
    final value = await _storage.read(key: _key);
    final json = value == null
        ? <String, dynamic>{}
        : jsonDecode(value) as Map<String, dynamic>;
    final api = SfacgApi(device: json['device'], nonce: json['nonce']);
    if (json['cookie'] is String) api.setCookie(json['cookie']);
    api.onSessionChanged = () async {
      if (!api.hasSession) {
        await _storage.delete(key: _key);
        return;
      }
      try {
        await _storage.write(
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
  }
}
