import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../domain/models.dart';
import '../novel_source.dart';

typedef FockRTDispatch =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> input);

/// Only API_SIGN files are downloaded. ANY_ABILITY files are never requested.
class QidianSigningScripts {
  QidianSigningScripts({
    required this.dispatch,
    this.allowNetwork = true,
    http.Client? client,
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _read = read ?? (() => _storage.read(key: _key)),
       _write = write ?? ((value) => _storage.write(key: _key, value: value)),
       _clock = clock ?? DateTime.now;

  static const _storage = FlutterSecureStorage();
  static const _key = 'unr.qidian.fockrt.v1';
  static const _maximum = 512 * 1024;
  final FockRTDispatch dispatch;
  final bool allowNetwork;
  final http.Client _client;
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  final DateTime Function() _clock;
  bool _closed = false;

  void _active() {
    if (_closed) throw const SourceException('起点请求已取消');
  }

  List<Map<String, dynamic>> _files(Object? value) {
    if (value == null) return [];
    if (value is! List || value.length > 8) throw const FormatException();
    final ids = <int>{};
    return [
      for (final item in value)
        if (item is Map &&
            item['id'] is int &&
            (item['id'] as int) > 0 &&
            (item['id'] as int) <= 0x7fffffffffffffff &&
            ids.add(item['id'] as int) &&
            item['st'] == 1 &&
            item['d'] is String &&
            (item['d'] as String).length <= _maximum &&
            base64Decode(item['d'] as String).isNotEmpty)
          {'id': item['id'], 'st': 1, 'd': item['d']}
        else
          throw const FormatException(),
    ];
  }

  Future<void> _install(String handle, List<Map<String, dynamic>> files) async {
    _active();
    final first = files.firstOrNull;
    final result = await dispatch({
      'op': 'script_install',
      'handle': handle,
      'id': first?['id'] ?? 0,
      'data': first?['d'] ?? '',
    });
    _active();
    if (result['ok'] != true) {
      throw const SourceException('起点远程签名脚本无法加载，请稍后重试');
    }
  }

  Future<void> prepare(String handle) async {
    try {
      final saved = await _read();
      _active();
      final state = saved == null
          ? <String, dynamic>{
              'version': 1,
              'uid': const Uuid().v4(),
              'attemptedAtMs': 0,
              'files': <Map<String, dynamic>>[],
            }
          : Map<String, dynamic>.from(jsonDecode(saved) as Map);
      final uid = state['uid'];
      if (state['version'] != 1 ||
          uid is! String ||
          !RegExp(
            r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$',
          ).hasMatch(uid) ||
          state['attemptedAtMs'] is! int ||
          (state['attemptedAtMs'] as int) < 0) {
        throw const FormatException();
      }
      final cached = _files(state['files']);
      final pending = state.containsKey('pendingFiles')
          ? _files(state['pendingFiles'])
          : null;
      if (saved == null) {
        await _write(jsonEncode(state));
        _active();
      }
      final now = _clock().millisecondsSinceEpoch;
      final last = state['attemptedAtMs'] as int;
      if (!allowNetwork || last > 0 && now - last < 180000) {
        await _install(handle, pending ?? cached);
        return;
      }
      final authorization = await dispatch({
        'op': 'script_auth',
        'handle': handle,
        'uid': uid,
        'timestamp': '${now ~/ 1000}',
      });
      _active();
      if (authorization['serviceCode'] == -4403) {
        throw const SourceAccessRestrictedException(
          '起点本机暂停期尚未结束，请稍后手动重试',
          code: -4403,
        );
      }
      final headers = authorization['headers'];
      if (authorization['ok'] != true || headers is! Map) {
        throw const SourceException('起点脚本更新参数暂不可用，请稍后重试');
      }
      // Persist the attempt before sending. Restarting cannot bypass backoff.
      state['attemptedAtMs'] = now;
      await _write(jsonEncode(state));
      _active();
      Object? document;
      try {
        final query = 't=1${cached.map((f) => '&cs%5B%5D=${f['id']}').join()}';
        final request =
            http.Request(
                'GET',
                Uri.https('fockrt.yuewen.com', '/files').replace(query: query),
              )
              ..followRedirects = false
              ..headers.addAll(Map<String, String>.from(headers));
        final response = await _client
            .send(request)
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200 ||
            (response.contentLength ?? 0) > _maximum) {
          unawaited(response.stream.listen(null).cancel());
        } else {
          final bytes = <int>[];
          await for (final chunk in response.stream.timeout(
            const Duration(seconds: 10),
          )) {
            bytes.addAll(chunk);
            if (bytes.length > _maximum) throw const FormatException();
          }
          document = jsonDecode(utf8.decode(bytes));
        }
      } on Exception {
        // Official flow keeps its cached script/default when an update fails.
      }
      _active();
      if (document is! Map || document['status'] != 0) {
        await _install(handle, pending ?? cached);
        return;
      }
      final files = _files(document['data']);
      // Never replace a known script with id 0 after a successful unsupported update.
      state['pendingFiles'] = files;
      await _write(jsonEncode(state));
      _active();
      await _install(handle, files);
      state['files'] = files;
      state.remove('pendingFiles');
      _active();
      await _write(jsonEncode(state));
    } on SourceException {
      rethrow;
    } catch (_) {
      throw const SourceException('起点签名脚本缓存或更新失败，请稍后重试');
    }
  }

  void close() {
    _closed = true;
    _client.close();
  }
}
