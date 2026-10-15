import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

enum LogLevel { info, warning, error }

class LogSnapshot {
  const LogSnapshot(this.text, {required this.storageUnavailable});
  final String text;
  final bool storageUnavailable;
}

/// Local diagnostics use fixed event names and numeric metadata only. Never pass
/// account data, URLs, book contents or exception messages to the log.
class AppLog {
  AppLog({this.maxFileBytes = 512 * 1024, this.maxFiles = 3})
    : assert(maxFileBytes >= 1024),
      assert(maxFiles > 0);

  static final instance = AppLog();
  final _changes = ValueNotifier<int>(0);
  Listenable get changes => _changes;
  final int maxFileBytes, maxFiles;
  final _recent = Queue<({int id, String line})>();
  Directory? _directory;
  Future<void>? _operations;
  int _pendingWrites = 0, _dropped = 0, _sequence = 0;
  bool _storageUnavailable = true;
  static const _queueLimit = 200;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final previous = _operations;
    final next = previous == null
        ? Future<T>.sync(action)
        : previous.then((_) => action());
    late final Future<void> tail;
    void finished() {
      if (identical(_operations, tail)) _operations = null;
    }

    tail = next.then<void>(
      (_) => finished(),
      onError: (Object _, StackTrace _) => finished(),
    );
    _operations = tail;
    return next;
  }

  Future<void> initialize({Directory? directory}) => _serialize(() async {
    try {
      _directory =
          directory ??
          Directory('${(await getApplicationSupportDirectory()).path}/logs');
      await _directory!.create(recursive: true);
      _storageUnavailable = false;
    } catch (_) {
      // Logging failures must never prevent startup or cached reading.
      _storageUnavailable = true;
    }
  });

  void record(
    LogLevel level,
    String event, {
    Object? error,
    StackTrace? stackTrace,
    int? httpStatus,
    int? elapsedMilliseconds,
  }) {
    // Refuse arbitrary text instead of trying to redact every possible secret.
    if (!RegExp(r'^[a-z][a-z0-9_.-]{0,95}$').hasMatch(event)) return;
    final locations = stackTrace == null
        ? <String>[]
        : RegExp(
            r'(?:package:[a-zA-Z0-9_]+/[a-zA-Z0-9_./-]+\.dart|dart:[a-zA-Z0-9_./-]+)(?::\d+){0,2}',
          ).allMatches('$stackTrace').take(16).map((m) => m[0]!).toList();
    final errorType = '${error.runtimeType}'.replaceAll(
      RegExp(r'[^a-zA-Z0-9_<>?, ]'),
      '',
    );
    final data = <String, Object>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'level': level.name,
      'event': event,
      if (error != null)
        'errorType': errorType.substring(0, errorType.length.clamp(0, 80)),
      if (error is SourceException) 'code': error.code,
      if (error is SourceException && error.errorCode != null)
        'errorCode': error.errorCode!,
      'httpStatus': ?httpStatus,
      'elapsedMs': ?elapsedMilliseconds,
      if (locations.isNotEmpty) 'stack': locations,
    };
    var line = '${jsonEncode(data)}\n';
    while (utf8.encode(line).length > maxFileBytes && locations.isNotEmpty) {
      locations.removeLast();
      line = '${jsonEncode(data)}\n';
    }
    _recent.add((id: ++_sequence, line: line));
    if (_recent.length > _queueLimit) _recent.removeFirst();
    _changes.value++;
    if (_directory == null) return;
    if (_pendingWrites >= _queueLimit) {
      _dropped++;
      return;
    }
    _pendingWrites++;
    unawaited(
      _serialize(() async {
        try {
          await _append(line);
          _storageUnavailable = false;
        } catch (_) {
          _storageUnavailable = true;
        } finally {
          _pendingWrites--;
        }
      }),
    );
  }

  File _file(int index) => File('${_directory!.path}/unr.$index.jsonl');

  Future<void> _append(String line) async {
    await _directory!.create(recursive: true);
    final current = _file(0);
    final size = await current.exists() ? await current.length() : 0;
    if (size + utf8.encode(line).length > maxFileBytes) {
      final oldest = _file(maxFiles - 1);
      if (await oldest.exists()) await oldest.delete();
      for (var i = maxFiles - 2; i >= 0; i--) {
        final file = _file(i);
        if (await file.exists()) await file.rename(_file(i + 1).path);
      }
    }
    await current.writeAsString(line, mode: FileMode.append, flush: true);
  }

  Future<void> flush() => _operations ?? Future<void>.value();

  Future<T> capture<T>(String event, Future<T> Function() action) async {
    try {
      return await action();
    } catch (error, stack) {
      record(LogLevel.error, event, error: error, stackTrace: stack);
      rethrow;
    }
  }

  Future<LogSnapshot> snapshot() => _serialize(() async {
    final parts = <String>[];
    if (_directory != null) {
      try {
        await _directory!.create(recursive: true);
        for (var i = maxFiles - 1; i >= 0; i--) {
          final file = _file(i);
          if (await file.exists()) {
            // Bound reads too, even if an old or damaged file is oversized.
            final handle = await file.open();
            try {
              parts.add(
                utf8.decode(
                  await handle.read(maxFileBytes),
                  allowMalformed: true,
                ),
              );
            } finally {
              await handle.close();
            }
          }
        }
      } catch (_) {
        _storageUnavailable = true;
      }
    }
    final contents = _storageUnavailable
        ? _recent.map((entry) => entry.line).join()
        : parts.join();
    return LogSnapshot(
      'UNR 诊断日志\n'
      '版本：${const String.fromEnvironment('APP_VERSION', defaultValue: '开发版')}\n'
      '平台：${Platform.operatingSystem} · ${kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug'}\n'
      '仅含固定事件、状态码、耗时、异常类型与代码位置。\n'
      '${_storageUnavailable ? '日志存储不可用，以下仅为本次运行的最近记录。\n' : ''}'
      '${_dropped > 0 ? '写入繁忙，$_dropped 条记录未写入文件。\n' : ''}'
      '\n$contents',
      storageUnavailable: _storageUnavailable,
    );
  });

  Future<void> clear() {
    final cutoff = _sequence;
    return _serialize(() async {
      // Keep memory if deletion fails, so the user can retry or export it.
      if (_directory != null) {
        await _directory!.create(recursive: true);
        for (var i = 0; i < maxFiles; i++) {
          final file = _file(i);
          if (await file.exists()) await file.delete();
        }
      }
      _recent.removeWhere((entry) => entry.id <= cutoff);
      _dropped = 0;
      _changes.value++;
    });
  }
}
