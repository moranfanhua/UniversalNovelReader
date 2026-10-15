import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/app_log.dart';
import 'package:unr/ui/logs.dart';

class RetryLog extends AppLog {
  var fail = true;
  @override
  Future<LogSnapshot> snapshot() async {
    if (fail) throw StateError('synthetic-secret');
    return super.snapshot();
  }
}

class LargeLog extends AppLog {
  final contents =
      'oldest-record\n${List.filled(1500, 'diagnostic event with a bounded preview and a complete export').join('\n')}\nnewest-record';
  @override
  Future<LogSnapshot> snapshot() async =>
      LogSnapshot(contents, storageUnavailable: false);
}

void main() {
  for (final width in [390.0, 1200.0]) {
    testWidgets('日志在宽度 $width 与双倍文字下可查看、刷新、导出及清空', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final log = AppLog()..record(LogLevel.error, 'test.first');
      String? exported;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
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
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.textContaining('test.first'), findsOneWidget);
      expect(find.textContaining('日志存储不可用').first, findsOneWidget);
      log.record(LogLevel.info, 'test.second');
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      expect(find.textContaining('test.second'), findsOneWidget);
      await tester.tap(find.text('导出日志'));
      await tester.pumpAndSettle();
      expect(exported, contains('test.second'));
      expect(find.text('日志已导出'), findsOneWidget);
      await tester.tap(find.text('清空日志'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('test.first'), findsOneWidget);
      await tester.tap(find.text('清空日志'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(find.textContaining('test.first'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('导出期间防止重复操作，取消不提示成功，失败可重试', (tester) async {
    final pending = Completer<bool>();
    final log = AppLog()..record(LogLevel.info, 'test.export');
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
    await tester.tap(find.text('导出日志'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '导出日志'))
          .onPressed,
      isNull,
    );
    expect(calls, 1);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('日志已导出'), findsNothing);
    await tester.tap(find.text('导出日志'));
    await tester.pumpAndSettle();
    expect(find.text('日志操作失败，请重试。'), findsOneWidget);
    expect(find.textContaining('synthetic-secret'), findsNothing);
    await tester.tap(find.text('导出日志'));
    await tester.pumpAndSettle();
    expect(find.text('日志已导出'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('读取失败可以重试，离开页面后导出结束不会更新已销毁状态', (tester) async {
    final log = RetryLog();
    final pending = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: LogsPage(log: log, export: (_) => pending.future),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('日志操作失败，请重试。'), findsOneWidget);
    log.fail = false;
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出日志'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('大量日志限制预览长度，导出仍包含全部记录', (tester) async {
    final log = LargeLog();
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
    final text = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(text.length, lessThan(66 * 1024));
    expect(text, isNot(contains('oldest-record')));
    expect(text, contains('newest-record'));
    await tester.tap(find.text('导出日志'));
    await tester.pumpAndSettle();
    expect(exported, log.contents);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小屏横向和放大文字可滚动操作，不溢出', (tester) async {
    tester.view.physicalSize = const Size(640, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: LogsPage(log: AppLog()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('清空日志'));
    expect(tester.takeException(), isNull);
  });
}
