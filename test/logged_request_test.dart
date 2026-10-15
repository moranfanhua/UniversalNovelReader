import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/app_log.dart';
import 'package:unr/sources/logged_request.dart';

void main() {
  test('请求原样发送且只发送一次，日志不包含 URL、请求头或正文', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.url.queryParameters['token'], 'synthetic-query');
      expect(request.headers['Cookie'], 'sessionid=synthetic-cookie');
      expect(request.headers['Authorization'], 'Bearer synthetic-auth');
      expect(request.body, 'synthetic-password');
      return http.Response(
        'synthetic-response',
        401,
        headers: {'set-cookie': 'synthetic-response-cookie'},
      );
    });
    addTearDown(client.close);
    final log = AppLog();
    final request =
        http.Request(
            'POST',
            Uri.parse(
              'https://private.invalid/synthetic-path?token=synthetic-query',
            ),
          )
          ..headers.addAll({
            'Cookie': 'sessionid=synthetic-cookie',
            'Authorization': 'Bearer synthetic-auth',
          })
          ..body = 'synthetic-password';
    final response = await sendLoggedRequest(
      client,
      request,
      event: 'http.test',
      log: log,
    );
    expect(calls, 1);
    expect(response.statusCode, 401);
    expect(response.body, 'synthetic-response');
    final snapshot = await log.snapshot();
    expect(snapshot.text, contains('"httpStatus":401'));
    expect(snapshot.text, contains('"level":"warning"'));
    expect(snapshot.text, contains('"elapsedMs":'));
    expect(snapshot.text, isNot(contains('synthetic-')));
    expect(snapshot.text, isNot(contains('private.invalid')));
  });

  test('连接异常保持原异常且不自动重发', () async {
    final failure = http.ClientException(
      'synthetic-secret',
      Uri.parse('https://private.invalid/'),
    );
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      throw failure;
    });
    addTearDown(client.close);
    final log = AppLog();
    await expectLater(
      sendLoggedRequest(
        client,
        http.Request('POST', Uri.https('example.invalid')),
        event: 'http.test',
        log: log,
      ),
      throwsA(same(failure)),
    );
    expect(calls, 1);
    final snapshot = await log.snapshot();
    expect(snapshot.text, contains('ClientException'));
    expect(snapshot.text, isNot(contains('synthetic-secret')));
    expect(snapshot.text, isNot(contains('private.invalid')));
  });

  test('超时包含响应流读取，超时后不再补记成功或重发', () async {
    final body = StreamController<List<int>>();
    var calls = 0;
    final client = MockClient.streaming((_, _) async {
      calls++;
      return http.StreamedResponse(body.stream, 200);
    });
    addTearDown(client.close);
    final log = AppLog();
    await expectLater(
      sendLoggedRequest(
        client,
        http.Request('GET', Uri.https('example.invalid')),
        event: 'http.test',
        log: log,
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );
    body.add(utf8.encode('synthetic-body'));
    await body.close();
    expect(calls, 1);
    final snapshot = await log.snapshot();
    expect(snapshot.text, contains('TimeoutException'));
    expect(snapshot.text, isNot(contains('"httpStatus":200')));
    expect(snapshot.text, isNot(contains('synthetic-body')));
  });
}
