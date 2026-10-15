import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/app_log.dart';
import 'package:unr/data/error_logging.dart';
import 'package:unr/domain/models.dart';

List<Map<String, dynamic>> entries(String text) => text
    .split('\n')
    .where((line) => line.startsWith('{'))
    .map((line) => jsonDecode(line) as Map<String, dynamic>)
    .toList();

void main() {
  late Directory root;
  late AppLog log;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('unr-log-test-');
    log = AppLog(maxFileBytes: 1024);
    await log.initialize(directory: root);
  });
  tearDown(() async {
    await log.flush();
    await root.delete(recursive: true);
  });

  test('保存安全字段、错误码和代码位置，拒绝异常原文与任意文本', () async {
    const secrets =
        'Cookie: sessionid=synthetic-cookie; password=synthetic-password '
        '手机号=13800138000; code=123456; 小说正文; https://private.invalid/?token=synthetic-token';
    log.record(
      LogLevel.error,
      'test.failed',
      error: const SourceException(secrets, code: 401, errorCode: 507),
      stackTrace: StackTrace.fromString(
        '#0 privateFunction ($secrets)\n'
        '#1 privateFunction (package:unr/ui/reader.dart:42:7)\n'
        '#2 privateFunction (file:///C:/Users/private-user/book.txt:1:1)\n'
        '#3 privateFunction (dart:async/future_impl.dart:10:2)',
      ),
      httpStatus: 200,
      elapsedMilliseconds: 25,
    );
    log.record(LogLevel.info, secrets);
    final snapshot = await log.snapshot();
    final data = entries(snapshot.text).single;
    expect(data['event'], 'test.failed');
    expect(data['level'], 'error');
    expect(data['code'], 401);
    expect(data['errorCode'], 507);
    expect(data['httpStatus'], 200);
    expect(data['elapsedMs'], 25);
    expect(data['errorType'], 'SourceException');
    expect(data['stack'], [
      'package:unr/ui/reader.dart:42:7',
      'dart:async/future_impl.dart:10:2',
    ]);
    final fileText = await File('${root.path}/unr.0.jsonl').readAsString();
    for (final text in [snapshot.text, fileText]) {
      for (final secret in [
        'synthetic-',
        '13800138000',
        '123456',
        '小说正文',
        'private.invalid',
        'private-user',
        'privateFunction',
      ]) {
        expect(text, isNot(contains(secret)));
      }
    }
    expect(snapshot.storageUnavailable, isFalse);
  });

  test('并发记录有序写入、按大小轮换，重开后保留最近日志', () async {
    for (var batch = 0; batch < 4; batch++) {
      for (var i = batch * 20; i < (batch + 1) * 20; i++) {
        log.record(LogLevel.info, 'test.record_$i');
      }
      await log.flush();
    }
    final files = await root
        .list()
        .where((entity) => entity.path.endsWith('.jsonl'))
        .cast<File>()
        .toList();
    expect(files.length, 3);
    for (final file in files) {
      expect(await file.length(), lessThanOrEqualTo(1024));
      for (final line in await file.readAsLines()) {
        expect(jsonDecode(line), isA<Map>());
      }
    }
    final reopened = AppLog(maxFileBytes: 1024);
    await reopened.initialize(directory: root);
    final saved = entries((await reopened.snapshot()).text);
    final ids = saved
        .map((entry) => int.parse((entry['event'] as String).split('_').last))
        .toList();
    expect(ids.last, 79);
    expect(ids.first, greaterThan(0));
    expect(ids, orderedEquals(ids.toList()..sort()));
    expect(ids.toSet().length, ids.length);
  });

  test('超长堆栈仍保持有效 JSON 和单文件上限', () async {
    log.record(
      LogLevel.error,
      'test.large_stack',
      stackTrace: StackTrace.fromString(
        List.generate(
          50,
          (i) => '#$i (package:unr/${'long_path/' * 100}reader.dart:100:100)',
        ).join('\n'),
      ),
    );
    await log.flush();
    expect(
      await File('${root.path}/unr.0.jsonl').length(),
      lessThanOrEqualTo(1024),
    );
    expect(
      entries((await log.snapshot()).text).single['event'],
      'test.large_stack',
    );
  });

  test('清空仅删除日志，清空后发生的事件继续保留', () async {
    final unrelated = File('${root.path}/index.json');
    await unrelated.writeAsString('library-preserved');
    log.record(LogLevel.info, 'test.before');
    final clearing = log.clear();
    log.record(LogLevel.info, 'test.after');
    await clearing;
    final snapshot = await log.snapshot();
    expect(entries(snapshot.text).map((e) => e['event']), ['test.after']);
    expect(await unrelated.readAsString(), 'library-preserved');
  });

  test('写入失败降级到内存，原操作结果和异常保持不变，存储可恢复', () async {
    final blocker = File('${root.path}/blocked');
    await blocker.writeAsString('block');
    final unavailable = AppLog();
    await unavailable.initialize(directory: Directory('${blocker.path}/logs'));
    expect(await unavailable.capture('test.success', () async => 42), 42);
    final failure = StateError('synthetic-password');
    await expectLater(
      unavailable.capture('test.failed', () async => throw failure),
      throwsA(same(failure)),
    );
    final fallback = await unavailable.snapshot();
    expect(fallback.storageUnavailable, isTrue);
    expect(fallback.text, contains('test.failed'));
    expect(fallback.text, isNot(contains('synthetic-password')));
    await expectLater(unavailable.clear(), throwsA(isA<FileSystemException>()));
    expect((await unavailable.snapshot()).text, contains('test.failed'));
    await blocker.delete();
    unavailable.record(LogLevel.info, 'test.recovered');
    final recovered = await unavailable.snapshot();
    expect(recovered.storageUnavailable, isFalse);
    expect(recovered.text, contains('test.recovered'));
  });

  test('繁忙时限制写入队列和内存记录，并告知丢弃数量', () async {
    for (var i = 0; i < 260; i++) {
      log.record(LogLevel.info, 'test.busy_$i');
    }
    expect((await log.snapshot()).text, contains('60 条记录未写入文件'));
    final memory = AppLog();
    for (var i = 0; i < 260; i++) {
      memory.record(LogLevel.info, 'test.memory_$i');
    }
    final saved = entries((await memory.snapshot()).text);
    expect(saved.length, 200);
    expect(saved.first['event'], 'test.memory_60');
    final clearing = memory.clear();
    memory.record(LogLevel.info, 'test.after_clear');
    await clearing;
    expect(
      entries((await memory.snapshot()).text).single['event'],
      'test.after_clear',
    );
  });

  test('记录 Flutter 和未捕获异常，同时保留原处理器行为', () async {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    });
    var flutterCalls = 0, platformCalls = 0;
    FlutterError.onError = (_) => flutterCalls++;
    PlatformDispatcher.instance.onError = (_, _) {
      platformCalls++;
      return false;
    };
    final uninstall = installErrorLogging(log);
    final failure = StateError('synthetic-secret');
    FlutterError.onError!(
      FlutterErrorDetails(exception: failure, stack: StackTrace.current),
    );
    expect(
      PlatformDispatcher.instance.onError!(failure, StackTrace.current),
      isFalse,
    );
    expect(flutterCalls, 1);
    expect(platformCalls, 1);
    uninstall();
    final snapshot = await log.snapshot();
    expect(entries(snapshot.text).map((e) => e['event']), [
      'app.flutter_error',
      'app.unhandled_error',
    ]);
    expect(snapshot.text, isNot(contains('synthetic-secret')));
  });
}
