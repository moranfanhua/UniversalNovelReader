import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/models.dart';
import '../novel_source.dart';
import 'qidian_device_profile.dart';
import 'qidian_scripts.dart';

/// Supplies the App's complete request context. Values must never be logged.
abstract interface class QidianRequestSecurity {
  QidianDeviceProfile? get deviceProfile;
  Future<Map<String, String>> headers(
    Map<String, String> params, {
    required String device,
    required Map<String, String> session,
  });
  Future<void> pause();
  void close();
}

typedef QidianNativeDispatch =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> input);

class NativeQidianSecurity implements QidianRequestSecurity {
  NativeQidianSecurity({
    QidianNativeDispatch? dispatch,
    Future<String> Function()? directory,
    this.allowRegistration = true,
    this.prepareScripts,
  }) : _dispatch = dispatch ?? _platformDispatch,
       _directory = directory ?? _privateDirectory;

  @override
  QidianDeviceProfile? get deviceProfile =>
      Platform.isWindows ? QidianDeviceProfile.windows : null;

  final bool allowRegistration;
  final Future<void> Function()? prepareScripts;
  QidianSigningScripts? _scripts;
  final QidianNativeDispatch _dispatch;
  final Future<String> Function() _directory;
  Future<String>? _handle;
  Future<void>? _ready;
  DateTime? _retryAfter;
  bool _closed = false;

  static Future<String> _privateDirectory() async =>
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}qidian-provider-v1';

  Future<String> _open(String device) => _handle ??= () async {
    if (_closed) throw const SourceException('起点请求已取消');
    final reply = await _dispatch({
      'op': 'create',
      'privacyAgreed': true,
      'allowNetwork': allowRegistration,
      'directory': await _directory(),
      'session': {'deviceId': device},
    });
    final handle = reply['handle'];
    if (reply['ok'] != true || handle is! String || handle.isEmpty) {
      throw const SourceException('起点本机安全参数初始化失败，请稍后重试');
    }
    if (_closed) {
      await _dispatch({'op': 'close', 'handle': handle});
      throw const SourceException('起点请求已取消');
    }
    return handle;
  }();

  Future<void> _ensure(String handle) => _ready ??= () async {
    final retryAfter = _retryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      throw const SourceException('起点安全参数暂不可用，请稍后手动重试');
    }
    try {
      if (prepareScripts != null) {
        await prepareScripts!();
      } else {
        final scripts = _scripts ??= QidianSigningScripts(
          dispatch: _dispatch,
          allowNetwork: allowRegistration,
        );
        await scripts.prepare(handle);
      }
      if (_closed) throw const SourceException('起点请求已取消');
      final reply = await _dispatch({'op': 'ensure', 'handle': handle});
      if (reply['serviceCode'] == -4403) {
        throw const SourceAccessRestrictedException(
          '起点提示当前网络环境风险较高，请稍后重试',
          code: -4403,
        );
      }
      if (reply['ok'] != true || reply['ready'] != true) {
        throw const SourceException('起点安全参数暂不可用，请稍后手动重试');
      }
      _retryAfter = null;
    } catch (_) {
      _retryAfter = DateTime.now().add(const Duration(minutes: 3));
      rethrow;
    }
  }();

  @override
  Future<Map<String, String>> headers(
    Map<String, String> params, {
    required String device,
    required Map<String, String> session,
  }) async {
    try {
      final retryAfter = _retryAfter;
      if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
        throw const SourceException('起点安全参数暂不可用，请稍后手动重试');
      }
      final String handle;
      try {
        handle = await _open(device);
      } catch (_) {
        _handle = null;
        _retryAfter = DateTime.now().add(const Duration(minutes: 3));
        rethrow;
      }
      try {
        await _ensure(handle);
      } catch (_) {
        _ready = null;
        rethrow;
      }
      if (_closed) throw const SourceException('起点请求已取消');
      final reply = await _dispatch({
        'op': 'headers',
        'handle': handle,
        'params': params,
        'session': session,
      });
      if (_closed) throw const SourceException('起点请求已取消');
      final values = reply['headers'];
      if (reply['ok'] != true ||
          values is! Map ||
          !const [
            'QDSign',
            'borgus',
            'cecelia',
            'tstamp',
            'QDInfo',
            'User-Agent',
            'Cookie',
            'gorgon',
            'ibex',
          ].every(
            (key) =>
                values[key] is String && (values[key] as String).isNotEmpty,
          )) {
        throw const SourceException('起点安全参数生成失败，请稍后重试');
      }
      return Map<String, String>.from(values);
    } on SourceException {
      rethrow;
    } catch (_) {
      // Native exceptions can contain platform data; never expose their text.
      throw const SourceException('起点本机安全参数不可用，请稍后重试');
    }
  }

  @override
  Future<void> pause() async {
    final opening = _handle;
    if (opening == null || _closed) return;
    final handle = await opening;
    await _dispatch({'op': 'pause', 'handle': handle});
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _scripts?.close();
    final opening = _handle;
    if (opening != null) {
      unawaited(
        opening
            .then((handle) async {
              await _dispatch({'op': 'close', 'handle': handle});
            })
            .catchError((Object _) {}),
      );
    }
  }
}

const _channel = MethodChannel('unr/qidian_native');
Future<Map<String, dynamic>> _platformDispatch(
  Map<String, dynamic> input,
) async {
  if (Platform.isAndroid) {
    final raw = await _channel.invokeMethod<String>(
      'dispatch',
      jsonEncode(input),
    );
    return Map<String, dynamic>.from(jsonDecode(raw ?? '') as Map);
  }
  if (Platform.isWindows) return Isolate.run(() => _windowsDispatch(input));
  throw const SourceException('当前平台尚未实现起点本机安全参数');
}

// Buffers are allocated/freed by the same DLL; no extra native dependency.
Map<String, dynamic> _windowsDispatch(Map<String, dynamic> input) {
  final library = DynamicLibrary.open('unr_qidian.dll');
  final allocate = library
      .lookupFunction<
        Pointer<Uint8> Function(Uint64),
        Pointer<Uint8> Function(int)
      >('unr_qidian_allocate');
  final free = library
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('unr_qidian_free');
  final dispatch = library
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Uint8>, Uint64),
        Pointer<Uint8> Function(Pointer<Uint8>, int)
      >('unr_qidian_dispatch');
  final bytes = utf8.encode(jsonEncode(input));
  final pointer = allocate(bytes.length);
  if (pointer == nullptr) throw StateError('Native buffer unavailable');
  Pointer<Uint8> output = nullptr;
  try {
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    output = dispatch(pointer, bytes.length);
    if (output == nullptr) throw StateError('Native result unavailable');
    var length = 0;
    while (length < 2 * 1024 * 1024 && output[length] != 0) {
      length++;
    }
    if (length == 2 * 1024 * 1024) throw StateError('Native result too large');
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(output.asTypedList(length))) as Map,
    );
  } finally {
    if (output != nullptr) free(output);
    free(pointer);
  }
}
