import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/app_log.dart';

// Layout and filtering reference: Bugaoshan's log viewer (AGPL-3.0).
class LogEntry {
  const LogEntry({
    required this.index,
    required this.event,
    required this.level,
    required this.raw,
    this.time,
    this.errorType,
    this.httpStatus,
    this.code,
    this.errorCode,
    this.elapsedMs,
    this.stack = const [],
  });

  final int index;
  final String event, raw;
  final LogLevel level;
  final DateTime? time;
  final String? errorType;
  final int? httpStatus, code, errorCode, elapsedMs;
  final List<String> stack;

  String get module {
    final parts = event.split('.');
    return (parts.first == 'http' || parts.first == 'session') &&
            parts.length > 1
        ? parts.take(2).join('.')
        : parts.first;
  }

  bool get authentication =>
      event.startsWith('session.') ||
      event.startsWith('ciweimao.auth_') ||
      event.startsWith('fanqie.auth_') ||
      event == 'http.fanqie.auth';

  String get message =>
      const {
        'app.starting': '正在启动应用',
        'app.started': '应用启动完成',
        'app.start_failed': '应用启动失败',
        'app.flutter_error': '界面发生异常',
        'app.unhandled_error': '发生未捕获异常',
        'http.sfacg': '菠萝包请求完成',
        'http.fanqie': '番茄请求完成',
        'http.fanqie.app': '番茄 App 请求完成',
        'http.fanqie.auth': '番茄认证请求完成',
        'http.ciweimao': '刺猬猫请求完成',
        'ciweimao.response_invalid': '刺猬猫响应解析失败',
        'ciweimao.request_rejected': '刺猬猫请求被拒绝',
        'ciweimao.auth_response_invalid': '刺猬猫认证响应解析失败',
        'ciweimao.auth_rejected': '刺猬猫认证未通过',
        'sfacg.response_invalid': '菠萝包响应解析失败',
        'sfacg.request_rejected': '菠萝包请求被拒绝',
        'fanqie.response_invalid': '番茄响应解析失败',
        'fanqie.request_rejected': '番茄请求被拒绝',
        'fanqie.auth_response_invalid': '番茄认证响应解析失败',
        'fanqie.auth_rejected': '番茄认证未通过',
        'session.sfacg.restore_failed': '菠萝包会话恢复失败',
        'session.sfacg.save_failed': '菠萝包会话保存失败',
        'session.fanqie.restore_failed': '番茄会话恢复失败',
        'session.fanqie.device_restore_failed': '番茄设备信息恢复失败',
        'session.fanqie.save_failed': '番茄会话保存失败',
        'session.ciweimao.restore_failed': '刺猬猫会话恢复失败',
        'session.ciweimao.save_failed': '刺猬猫会话保存失败',
        'storage.write_failed': '本地文件写入失败',
        'reader.chapter_failed': '章节读取失败',
        'reader.image_failed': '图片读取失败',
        'search.source_failed': '书源搜索失败',
        'search.failed': '搜索失败',
        'book.open_failed': '作品打开失败',
        'book.refresh_failed': '作品刷新失败',
        'bookshelf.update_failed': '书架作品自动更新失败',
        'import.failed': '小说导入失败',
        'export.failed': '小说导出失败',
        'log.operation_failed': '日志操作失败',
      }[event] ??
      event;

  String get displayMessage {
    if (!event.startsWith('http.')) return message;
    if (errorType != null) return message.replaceFirst('完成', '失败');
    if (httpStatus != null && httpStatus! >= 400) {
      return message.replaceFirst('完成', '未成功');
    }
    return message;
  }

  String get formattedTime {
    final value = time?.toLocal();
    if (value == null) return '时间未知';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}:${two(value.second)}.'
        '${value.millisecond.toString().padLeft(3, '0')}';
  }
}

String logModuleName(String module) =>
    const {
      'app': '应用',
      'http.sfacg': '菠萝包网络',
      'http.fanqie': '番茄网络',
      'http.ciweimao': '刺猬猫网络',
      'sfacg': '菠萝包',
      'fanqie': '番茄',
      'ciweimao': '刺猬猫',
      'session.sfacg': '菠萝包会话',
      'session.fanqie': '番茄会话',
      'session.ciweimao': '刺猬猫会话',
      'storage': '本地存储',
      'reader': '阅读器',
      'search': '搜索',
      'book': '作品',
      'import': '导入',
      'export': '导出',
      'log': '日志',
    }[module] ??
    module;

String logLevelName(LogLevel level) => switch (level) {
  LogLevel.info => '信息',
  LogLevel.warning => '警告',
  LogLevel.error => '错误',
};

({List<LogEntry> entries, int unreadable}) parseLogEntries(String text) {
  final entries = <LogEntry>[];
  var unreadable = 0;
  for (final line in const LineSplitter().convert(text)) {
    if (!line.trimLeft().startsWith('{')) continue;
    try {
      final data = jsonDecode(line) as Map<String, dynamic>;
      final event = data['event'];
      final level = LogLevel.values
          .where((l) => l.name == data['level'])
          .firstOrNull;
      if (event is! String || level == null) {
        unreadable++;
        continue;
      }
      entries.add(
        LogEntry(
          index: entries.length,
          event: event,
          level: level,
          raw: line,
          time: data['time'] is String ? DateTime.tryParse(data['time']) : null,
          errorType: data['errorType'] is String ? data['errorType'] : null,
          httpStatus: data['httpStatus'] is int ? data['httpStatus'] : null,
          code: data['code'] is int ? data['code'] : null,
          errorCode: data['errorCode'] is int ? data['errorCode'] : null,
          elapsedMs: data['elapsedMs'] is int ? data['elapsedMs'] : null,
          stack: data['stack'] is List
              ? (data['stack'] as List).whereType<String>().toList()
              : const [],
        ),
      );
    } on FormatException {
      unreadable++;
    } on TypeError {
      unreadable++;
    }
  }
  return (entries: entries, unreadable: unreadable);
}

class LogEntryTile extends StatelessWidget {
  const LogEntryTile({super.key, required this.entry, required this.onCopy});
  final LogEntry entry;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (background, foreground) = switch (entry.level) {
      LogLevel.info => (scheme.primaryContainer, scheme.onPrimaryContainer),
      LogLevel.warning => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      LogLevel.error => (scheme.errorContainer, scheme.onErrorContainer),
    };
    final textStyle = theme.textTheme.bodySmall?.copyWith(color: foreground);
    return Material(
      color: background,
      child: InkWell(
        onLongPress: onCopy,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: DefaultTextStyle.merge(
            style: textStyle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      entry.formattedTime,
                      style: textStyle?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      logLevelName(entry.level),
                      style: textStyle?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(logModuleName(entry.module)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  entry.displayMessage,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: foreground,
                  ),
                ),
                if (entry.errorType != null) ...[
                  const SizedBox(height: 4),
                  Text('异常：${entry.errorType}'),
                ],
                if (entry.httpStatus != null ||
                    entry.code != null ||
                    entry.errorCode != null ||
                    entry.elapsedMs != null) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      if (entry.httpStatus != null)
                        Text('HTTP ${entry.httpStatus}'),
                      if (entry.code != null) Text('状态码 ${entry.code}'),
                      if (entry.errorCode != null)
                        Text('错误码 ${entry.errorCode}'),
                      if (entry.elapsedMs != null)
                        Text('耗时 ${entry.elapsedMs} ms'),
                    ],
                  ),
                ],
                if (entry.stack.isNotEmpty)
                  Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      key: PageStorageKey(
                        'log-stack-${entry.time}-${entry.event}-${entry.index}',
                      ),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 4),
                      visualDensity: VisualDensity.compact,
                      iconColor: foreground,
                      collapsedIconColor: foreground,
                      title: Text('错误堆栈', style: textStyle),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            entry.stack.join('\n'),
                            style: textStyle?.copyWith(fontFamily: 'monospace'),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
