import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/app_log.dart';
import 'ciweimao_api.dart';

class CiweimaoSession {
  static const key = 'unr.ciweimao.session.v1';
  static final _stores = Expando<_SessionStore>();

  static Future<CiweimaoApi> open({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) async {
    CiweimaoApi? api;
    var preserveOriginal = false;
    try {
      final raw = await storage.read(key: key);
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        api = CiweimaoApi(installation: data['installation'] as String);
        if (data['credentials'] != null) {
          api.restoreSession(
            CiweimaoCredentials.fromJson(
              Map<String, dynamic>.from(data['credentials'] as Map),
            ),
          );
        }
      }
    } catch (error, stack) {
      preserveOriginal = true;
      AppLog.instance.record(
        LogLevel.warning,
        'session.ciweimao.restore_failed',
        error: error,
        stackTrace: stack,
      );
      api ??= CiweimaoApi();
      api.sessionNotice = '无法恢复刺猬猫会话，原存储已保留。请重新登录，已缓存章节仍可阅读。';
    }
    final result = api ?? CiweimaoApi();
    final store = _SessionStore(storage, result);
    _stores[result] = store;
    result.onSessionChanged = () async {
      if (preserveOriginal && result.credentials?.guest == true) return;
      try {
        await store.write(result.credentials);
        preserveOriginal = false;
        result.sessionNotice = null;
      } catch (error, stack) {
        AppLog.instance.record(
          LogLevel.error,
          'session.ciweimao.save_failed',
          error: error,
          stackTrace: stack,
        );
        result.sessionNotice = '无法写入本机安全存储，当前会话仍可使用，重启后需要重新登录刺猬猫。';
      }
    };
    return result;
  }

  static Future<void> logout(
    CiweimaoApi api, {
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) async {
    final generation = api.sessionGeneration;
    final store = _stores[api] ?? _SessionStore(storage, api);
    await store.write(null);
    api.checkSession(generation);
    api.restoreSession(null);
    api.sessionNotice = null;
  }
}

class _SessionStore {
  _SessionStore(this.storage, this.api);
  final FlutterSecureStorage storage;
  final CiweimaoApi api;
  Future<void> _tail = Future.value();

  Future<void> write(CiweimaoCredentials? credentials) {
    final value = jsonEncode({
      'installation': api.installation,
      'credentials': credentials?.toJson(),
    });
    final result = _tail.then(
      (_) => storage.write(key: CiweimaoSession.key, value: value),
    );
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
