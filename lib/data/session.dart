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
    final api = SfacgApi(device: json['device']);
    if (json['cookie'] is String) api.setCookie(json['cookie']);
    api.onSessionChanged = () async {
      if (!api.hasSession) {
        await _storage.delete(key: _key);
        return;
      }
      await _storage.write(
        key: _key,
        value: jsonEncode({
          'device': api.device,
          'cookie': api.cookies.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; '),
        }),
      );
    };
    return api;
  }

  static Future<void> logout(SfacgApi api) async {
    api.cookies.clear();
    await _storage.delete(key: _key);
  }
}
