import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/account.dart';
import 'helpers/viewport.dart';

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('账号页可以主动处理安全验证，宽度 $width 与两倍文字', (tester) async {
      setTestViewport(tester, Size(width, 1000));
      final release = Completer<void>();
      var prompts = 0, submissions = 0;
      final api = SfacgApi(
        client: MockClient((request) async {
          Object data = {
            'accountId': 42,
            'expand': {
              'accountException': {'banStatus': 6},
            },
          };
          if (request.url.path.endsWith('/aid')) data = 'aid';
          if (request.url.queryParameters.containsKey('captcha_ticket')) {
            submissions++;
            data = {
              'accountId': 42,
              'expand': {'accountException': null},
            };
          }
          return http.Response(
            jsonEncode({
              'status': {'httpCode': 200},
              'data': data,
            }),
            200,
          );
        }),
      )..setCookie('.SFCommunity=community; session_APP=session');
      addTearDown(api.close);
      final library = Library(Directory.systemTemp, SfacgSource(api));
      addTearDown(library.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: AccountPage(
              library: library,
              verificationSolver: <T>(challenge) async {
                prompts++;
                await release.future;
                return challenge.parseResult({
                  'ret': 0,
                  'ticket': 'ticket',
                  'randstr': 'random',
                });
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('处理安全验证'));
      await tester.pump();
      expect(find.text('账号密码登录'), findsNothing);
      await tester.tap(find.text('处理安全验证'));
      await tester.pump();
      expect(prompts, 1);
      release.complete();
      await tester.pumpAndSettle();
      expect(submissions, 1);
      expect(find.text('安全验证已通过，可返回原页面重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('账号页销毁后丢弃迟到的验证结果', (tester) async {
    final release = Completer<void>();
    var submissions = 0;
    final api = SfacgApi(
      client: MockClient((request) async {
        if (request.url.queryParameters.containsKey('captcha_ticket')) {
          submissions++;
        }
        return http.Response(
          jsonEncode({
            'status': {'httpCode': 200},
            'data': request.url.path.endsWith('/aid')
                ? 'aid'
                : {
                    'accountId': 42,
                    'expand': {
                      'accountException': {'banStatus': 6},
                    },
                  },
          }),
          200,
        );
      }),
    )..setCookie('.SFCommunity=community; session_APP=session');
    addTearDown(api.close);
    final library = Library(Directory.systemTemp, SfacgSource(api));
    addTearDown(library.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPage(
            library: library,
            verificationSolver: <T>(challenge) async {
              await release.future;
              return challenge.parseResult({
                'ret': 0,
                'ticket': 'ticket',
                'randstr': 'random',
              });
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('处理安全验证'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    release.complete();
    await tester.pumpAndSettle();
    expect(submissions, 0);
    expect(api.cookies['session_APP'], 'session');
    expect(tester.takeException(), isNull);
  });
}
