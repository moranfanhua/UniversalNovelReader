import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/app_log.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/domain/server_error_message.dart';

void main() {
  test('保留服务端说明，异常原文仍不进入日志', () async {
    final log = AppLog();
    final message = ServerErrorMessage.parse('没有访问接口的权限，请更新 App 后重试');
    log.record(
      LogLevel.warning,
      'sfacg.request_rejected',
      serverMessage: message,
      error: const SourceException(
        'synthetic-private-exception',
        code: 401,
        errorCode: 507,
      ),
      httpStatus: 200,
    );
    final snapshot = await log.snapshot();
    final record =
        jsonDecode(
              snapshot.text.split('\n').singleWhere((s) => s.startsWith('{')),
            )
            as Map;
    expect(record['serverMessage'], '没有访问接口的权限，请更新 App 后重试');
    expect(record['code'], 401);
    expect(record['errorCode'], 507);
    expect(record['httpStatus'], 200);
    expect(snapshot.text, isNot(contains('synthetic-private')));
    expect(message!.appendTo('章节读取失败'), contains('服务端：没有访问接口的权限'));
  });

  test('移除已知请求和会话值、编码回显、字段、联系方式、地址和未知长票据', () {
    const password = '私人密码/%';
    const content = '这是用户发送的评论';
    final encoded = Uri.encodeComponent(Uri.encodeComponent(password));
    final message = ServerErrorMessage.parse(
      '接口权限不足；$encoded；${base64Encode(utf8.encode(password))}；$content；'
      'Cookie: sessionid=short；密码：短密码；Bearer: short；ticket=short；'
      '13800138000 123456 user@example.com https://private.invalid/?k=secret；'
      'abcdefghijklmnopqrstuvwxy12345；请稍后重试',
      secrets: [
        {
          'password': password,
          'nested': [content],
        },
      ],
    )!.text;
    expect(message, contains('接口权限不足'));
    expect(message, contains('请稍后重试'));
    for (final secret in [
      password,
      encoded,
      base64Encode(utf8.encode(password)),
      content,
      'short',
      '短密码',
      '13800138000',
      '123456',
      'user@example.com',
      'private.invalid',
      'abcdefghijklmnopqrstuvwxy12345',
    ]) {
      expect(message, isNot(contains(secret)), reason: secret);
    }
  });

  test('缺失、非文本、完整 JSON 或网页不作为说明写入，长消息有界且先脱敏后截断', () {
    for (final value in [
      null,
      '',
      '  ',
      123,
      {},
      [],
      '{"token":"secret"}',
      '["正文"]',
      '<html>private</html>',
      '长' * 2049,
    ]) {
      expect(ServerErrorMessage.parse(value), isNull);
    }
    final text = ServerErrorMessage.parse(
      '${'错误😀' * 49}private-password${'后文' * 50}',
      secrets: ['private-password'],
    )!.text;
    expect(text.runes.length, lessThanOrEqualTo(160));
    expect(text, isNot(contains('private')));
    expect(text.endsWith('…'), isTrue);
    expect(utf8.decode(utf8.encode(text)), text);
  });

  test('服务端新返回的账号和票据也要隐藏，不能仅依赖请求中的旧值', () {
    final text = ServerErrorMessage.parse(
      '账号暂不可用；新账号；短票据；新昵称；新正文',
      responseData: {
        'data': {
          'account': '新账号',
          'login_token': '短票据',
          'reader_info': {'name': '新昵称'},
          'content': '新正文',
        },
      },
    )!.text;
    expect(text, contains('账号暂不可用'));
    for (final secret in ['新账号', '短票据', '新昵称', '新正文']) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('服务端说明与超长堆栈同时存在时仍遵守日志单条大小上限', () async {
    final log = AppLog(maxFileBytes: 1024);
    log.record(
      LogLevel.error,
      'test.${'a' * 90}',
      error: const SourceException('', code: 999999999, errorCode: 999999999),
      serverMessage: ServerErrorMessage.parse('😀' * 200),
      stackTrace: StackTrace.fromString(
        List.generate(
          16,
          (i) => '#$i f (package:unr/${'long/' * 20}file.dart:123:456)',
        ).join('\n'),
      ),
    );
    final snapshot = await log.snapshot();
    final line = snapshot.text
        .split('\n')
        .singleWhere((s) => s.startsWith('{'));
    expect(utf8.encode('$line\n').length, lessThanOrEqualTo(1024));
    expect(jsonDecode(line)['serverMessage'], isNotEmpty);
  });
}
