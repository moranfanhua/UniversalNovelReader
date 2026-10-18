import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:unr/ui/top_dropdown_button.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/app_log.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/ui/log_entry.dart';
import 'package:unr/ui/logs.dart';

class RetryLog extends AppLog {
  var fail = true;
  var reads = 0;
  @override
  Future<LogSnapshot> snapshot() async {
    reads++;
    if (fail) throw StateError('synthetic-secret');
    return super.snapshot();
  }
}

class FixtureLog extends AppLog {
  FixtureLog(this.contents);
  final String contents;
  @override
  Future<LogSnapshot> snapshot() async =>
      LogSnapshot(contents, storageUnavailable: false);
}

Future<void> action(WidgetTester tester, String title) async {
  final button = find.byTooltip(title);
  if (button.evaluate().isNotEmpty) {
    await tester.tap(button);
  } else {
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
  }
  await tester.pumpAndSettle();
}

void configure(WidgetTester tester, {Size size = const Size(1200, 1000)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
}

void main() {
  test('刺猬猫认证错误使用中文名称，进入认证筛选并显示业务错误码', () {
    final result = parseLogEntries(
      jsonEncode({
        'event': 'ciweimao.auth_rejected',
        'level': 'warning',
        'httpStatus': 200,
        'code': 210000,
      }),
    );
    final entry = result.entries.single;
    expect(entry.authentication, isTrue);
    expect(entry.displayMessage, '刺猬猫认证未通过');
    expect(entry.code, 210000);
    expect(logModuleName(entry.module), '刺猬猫');
  });
  for (final width in [390.0, 1200.0]) {
    testWidgets('日志在宽度 $width 和双倍文字下逐条显示、自动更新、导出和清空', (tester) async {
      configure(tester, size: Size(width, 1000));
      final log = AppLog()..record(LogLevel.error, 'test.first');
      String? exported;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: LogsPage(
            log: log,
            export: (bytes) async {
              exported = utf8.decode(bytes);
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('运行日志'), findsOneWidget);
      expect(find.byType(LogEntryTile), findsOneWidget);
      expect(find.text('test.first'), findsOneWidget);
      expect(find.textContaining('日志存储不可用'), findsOneWidget);
      log.record(LogLevel.info, 'test.second');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<LogEntryTile>(find.byType(LogEntryTile))
            .first
            .entry
            .event,
        'test.second',
      );
      await action(tester, '导出日志');
      expect(exported, contains('test.second'));
      expect(find.text('日志已导出'), findsOneWidget);
      await action(tester, '清空日志');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('test.first'), findsOneWidget);
      await action(tester, '清空日志');
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(find.text('暂无运行日志'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('分类、级别、模块筛选可组合，错误与堆栈分开显示', (tester) async {
    configure(tester);
    final log = AppLog()
      ..record(LogLevel.info, 'app.started')
      ..record(LogLevel.warning, 'session.fanqie.restore_failed')
      ..record(
        LogLevel.error,
        'reader.chapter_failed',
        error: const SourceException(
          'synthetic-secret',
          code: 401,
          errorCode: 507,
        ),
        stackTrace: StackTrace.fromString(
          '#0 f (package:unr/ui/reader.dart:42:7)',
        ),
        httpStatus: 200,
        elapsedMilliseconds: 25,
      );
    await tester.pumpWidget(MaterialApp(home: LogsPage(log: log)));
    await tester.pumpAndSettle();
    expect(find.text('章节读取失败'), findsOneWidget);
    expect(find.text('异常：SourceException'), findsOneWidget);
    expect(find.text('HTTP 200'), findsOneWidget);
    expect(find.text('状态码 401'), findsOneWidget);
    expect(find.text('错误码 507'), findsOneWidget);
    expect(find.text('耗时 25 ms'), findsOneWidget);
    expect(find.textContaining('package:unr/'), findsNothing);
    expect(find.textContaining('synthetic-secret'), findsNothing);
    await tester.tap(find.text('业务错误'));
    await tester.pumpAndSettle();
    expect(find.text('应用启动完成'), findsNothing);
    expect(find.text('番茄会话恢复失败'), findsNothing);
    await tester.tap(find.text('错误堆栈'));
    await tester.pumpAndSettle();
    expect(find.text('package:unr/ui/reader.dart:42:7'), findsOneWidget);
    await tester.tap(find.text('认证日志'));
    await tester.pumpAndSettle();
    expect(find.text('番茄会话恢复失败'), findsOneWidget);
    expect(find.text('章节读取失败'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('log-level-warning')));
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的日志'), findsOneWidget);
    await tester.tap(find.text('重置筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('log-module-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读器（1）').last);
    await tester.pumpAndSettle();
    expect(find.byType(LogEntryTile), findsOneWidget);
    expect(find.text('章节读取失败'), findsOneWidget);
    for (final level in LogLevel.values) {
      await tester.tap(find.byKey(ValueKey('log-level-${level.name}')));
      await tester.pumpAndSettle();
    }
    expect(find.text('没有符合条件的日志'), findsOneWidget);
    await tester.tap(find.text('重置筛选'));
    await tester.pumpAndSettle();
    expect(find.byType(LogEntryTile), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选不影响复制全部及导出，长按可复制单条', (tester) async {
    configure(tester);
    String? clipboard, exported;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final log = AppLog()
      ..record(LogLevel.info, 'app.started')
      ..record(LogLevel.error, 'reader.chapter_failed');
    await tester.pumpWidget(
      MaterialApp(
        home: LogsPage(
          log: log,
          export: (bytes) async {
            exported = utf8.decode(bytes);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('业务错误'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('章节读取失败'));
    await tester.pumpAndSettle();
    expect(clipboard, contains('reader.chapter_failed'));
    expect(clipboard, isNot(contains('app.started')));
    await action(tester, '复制全部');
    expect(clipboard, contains('app.started'));
    expect(clipboard, contains('reader.chapter_failed'));
    await action(tester, '导出日志');
    expect(exported, contains('app.started'));
    expect(exported, contains('reader.chapter_failed'));
  });

  testWidgets('模块条数实时更新，清空后失效的模块筛选自动重置', (tester) async {
    configure(tester);
    final log = AppLog()..record(LogLevel.error, 'reader.chapter_failed');
    await tester.pumpWidget(MaterialApp(home: LogsPage(log: log)));
    await tester.pumpAndSettle();
    tester
        .widget<TopDropdownButton<String>>(
          find.byKey(const ValueKey('log-module-filter')),
        )
        .onChanged!('reader');
    await tester.pumpAndSettle();
    log.record(LogLevel.warning, 'storage.write_failed');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    final dropdown = tester.widget<TopDropdownButton<String>>(
      find.byKey(const ValueKey('log-module-filter')),
    );
    expect(dropdown.items.any((item) => item.value == 'storage'), isTrue);
    await log.clear();
    log.record(LogLevel.info, 'app.started');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('应用启动完成'), findsOneWidget);
    expect(
      tester
          .widget<TopDropdownButton<String>>(
            find.byKey(const ValueKey('log-module-filter')),
          )
          .value,
      '',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出期间防重复操作，取消不提示成功，失败可重试', (tester) async {
    configure(tester);
    final pending = Completer<bool>();
    final log = AppLog()..record(LogLevel.info, 'app.started');
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LogsPage(
          log: log,
          export: (_) {
            calls++;
            if (calls == 1) return pending.future;
            if (calls == 2) throw StateError('synthetic-secret');
            return Future.value(true);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('导出日志'));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.save_alt))
          .onPressed,
      isNull,
    );
    expect(calls, 1);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('日志已导出'), findsNothing);
    await action(tester, '导出日志');
    expect(find.text('日志操作失败，请重试。'), findsOneWidget);
    expect(find.textContaining('synthetic-secret'), findsNothing);
    await action(tester, '导出日志');
    expect(find.text('日志已导出'), findsOneWidget);
  });

  testWidgets('读取失败不触发循环重试，手动重试后可离开正在导出的页面', (tester) async {
    configure(tester);
    final log = RetryLog();
    final pending = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: LogsPage(log: log, export: (_) => pending.future),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('日志操作失败，请重试。'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    final reads = log.reads;
    await tester.pump(const Duration(seconds: 2));
    expect(log.reads, reads);
    log.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('导出日志'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('大量日志按需构建列表，导出包含全部记录与损坏行', (tester) async {
    configure(tester);
    final contents =
        '${List.generate(2000, (i) => jsonEncode({'event': 'test.entry_$i', 'level': 'info', 'time': DateTime.utc(2026, 10, 15).add(Duration(seconds: i)).toIso8601String()})).join('\n')}\n{broken';
    final log = FixtureLog(contents);
    String? exported;
    await tester.pumpWidget(
      MaterialApp(
        home: LogsPage(
          log: log,
          export: (bytes) async {
            exported = utf8.decode(bytes);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('显示 2000 / 2000 条'), findsOneWidget);
    expect(find.text('test.entry_1999'), findsOneWidget);
    expect(find.text('test.entry_0'), findsNothing);
    expect(find.text('1 条记录无法解析，导出仍包含原始记录。'), findsOneWidget);
    expect(find.byType(LogEntryTile).evaluate().length, lessThan(30));
    await action(tester, '导出日志');
    expect(exported, contents);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小屏横向和放大文字可滚动筛选，说明位于更多操作', (tester) async {
    configure(tester, size: const Size(640, 320));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: LogsPage(log: AppLog()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('log-module-filter')));
    await action(tester, '日志说明');
    expect(find.textContaining('日志仅保存在本机'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
