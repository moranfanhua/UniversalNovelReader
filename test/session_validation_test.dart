import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_auth.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/session_validation.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/account.dart';
import 'package:unr/ui/account_session_check.dart';
import 'package:unr/ui/ciweimao_account.dart';
import 'package:unr/ui/fanqie_account.dart';
import 'package:unr/ui/qidian_account.dart';
import 'helpers/viewport.dart';

http.Response json(Object data, {int status = 200}) =>
    http.Response(jsonEncode(data), status);

CiweimaoCredentials catSession() => CiweimaoCredentials(
  account: 'synthetic-account',
  token: 'synthetic-token-1234',
  readerId: '42',
);

QidianCredentials qidianSession() => QidianCredentials(
  userId: '42',
  ywGuid: '43',
  ywKey: 'synthetic-key',
  token: 'synthetic-token',
);

void main() {
  test('菠萝包独立探测 App 会话，匿名与明确拒绝判失效，清除 Cookie 不写回', () async {
    var status = 200;
    Object data = {'accountId': 42};
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.url.host, 'api.sfacg.com');
        expect(request.url.path, '/user');
        expect(request.headers['sfsecurity'], contains('sign='));
        expect(request.headers['Cookie'], contains('session_APP=original'));
        return http.Response(
          jsonEncode({
            'status': {'httpCode': status},
            'data': data,
          }),
          status,
          headers: {'set-cookie': 'session_APP=; Path=/'},
        );
      }),
    )..setCookie('.SFCommunity=original; session_APP=original');
    addTearDown(api.close);
    var saves = 0;
    api.onSessionChanged = () async => saves++;
    // Even a successful /user response cannot validate a cleared App Cookie.
    await expectLater(
      api.checkSession(),
      throwsA(isA<SessionExpiredException>()),
    );
    expect(api.hasSession, isTrue);
    data = {'accountId': 0};
    await expectLater(
      api.checkSession(),
      throwsA(isA<SessionExpiredException>()),
    );
    status = 401;
    await expectLater(
      api.checkSession(),
      throwsA(isA<SessionExpiredException>()),
    );
    expect(api.cookies['session_APP'], 'original');
    expect(saves, 0);
  });

  test('番茄 Passport 失效与频率限制、响应变化分开，保持原会话和设备', () async {
    Object document = {
      'message': 'success',
      'data': {'user_id': '42'},
    };
    final api = FanqieApi(
      client: MockClient((request) async {
        expect(request.url.host, 'security.snssdk.com');
        expect(request.url.path, '/passport/account/info/v2/');
        expect(request.headers['Cookie'], 'sessionid=original');
        expect(request.headers['x-argus'], isNotEmpty);
        expect(request.url.queryParameters['device_id'], '1234567890');
        return json(document);
      }),
    )..setCookie('sessionid=original');
    api.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});
    addTearDown(api.close);
    var saves = 0;
    api.onSessionChanged = () async => saves++;
    await api.checkSession();
    for (final data in [
      {'name': 'session_expired', 'error_code': 8},
      {'error_name': 'session_expired', 'error_code': 8},
    ]) {
      document = {'message': 'error', 'data': data};
      await expectLater(
        api.checkSession(),
        throwsA(isA<SessionExpiredException>()),
      );
    }
    for (final data in [
      {
        'message': 'error',
        'data': {'error_code': 7},
      },
      {'message': 'success', 'data': <String, Object>{}},
    ]) {
      document = data;
      await expectLater(
        api.checkSession(),
        throwsA(
          isA<SourceException>().having(
            (e) => e is SessionExpiredException,
            'expired',
            isFalse,
          ),
        ),
      );
    }
    expect(api.cookie, 'sessionid=original');
    expect(api.app.deviceId, '1234567890');
    expect(saves, 0);
  });

  test('起点读取 APK 账号接口检测当前 Token，不重新登录或替换凭据', () async {
    var code = 0, status = 200;
    Object? user = {'UserId': 42};
    final session = qidianSession();
    final api = QidianApi(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.host, 'druidv6.if.qidian.com');
        expect(request.url.path, '/argus/api/v3/user/getaccountpage');
        expect(
          request.headers['Cookie'],
          contains('cmfuToken=synthetic-token'),
        );
        expect(request.headers['QDSign'], isNotEmpty);
        if (status == 401) return http.Response('', 401);
        return json({
          'Result': code,
          'Data': {'UserBasicInfo': user},
        });
      }),
    )..credentials = session;
    addTearDown(api.close);
    var saves = 0;
    api.onSessionChanged = () async => saves++;
    await api.checkSession();
    for (final anonymous in [
      null,
      {'UserId': 0},
    ]) {
      user = anonymous;
      await expectLater(
        api.checkSession(),
        throwsA(isA<SessionExpiredException>()),
      );
    }
    user = {'UserId': 42};
    code = -2;
    await expectLater(
      api.checkSession(),
      throwsA(isA<SessionExpiredException>()),
    );
    code = 0;
    status = 401;
    await expectLater(
      api.checkSession(),
      throwsA(isA<SessionExpiredException>()),
    );
    expect(api.credentials, same(session));
    expect(saves, 0);
  });

  test('刺猬猫沿用 App 加签及加密账号校验，失效不清除原会话', () async {
    var code = 100000;
    final session = catSession();
    final api = CiweimaoApi(
      client: MockClient((request) async {
        expect(request.url.host, 'app1.happybooker.cn');
        expect(request.url.path, '/reader/get_my_info');
        expect(request.bodyFields['account'], session.account);
        expect(request.bodyFields['login_token'], session.token);
        expect(request.bodyFields['reader_id'], session.readerId);
        expect(request.bodyFields['p'], isNotEmpty);
        return http.Response(
          CiweimaoCrypto.encrypt(
            jsonEncode({
              'code': code,
              'data': {
                'reader_info': {'reader_id': '42', 'account': session.account},
              },
            }),
          ),
          200,
        );
      }),
    )..restoreSession(session);
    addTearDown(api.close);
    var saves = 0;
    api.onSessionChanged = () async => saves++;
    final auth = CiweimaoAuth(api);
    await auth.checkSession();
    for (final expired in [200100, 200001]) {
      code = expired;
      await expectLater(
        auth.checkSession(),
        throwsA(isA<SessionExpiredException>()),
      );
    }
    code = 310002;
    await expectLater(
      auth.checkSession(),
      throwsA(
        isA<SourceException>().having(
          (e) => e is SessionExpiredException,
          'expired',
          isFalse,
        ),
      ),
    );
    expect(api.credentials, same(session));
    expect(saves, 0);
  });

  for (final source in ['sfacg', 'fanqie', 'qidian', 'ciweimao']) {
    for (final size in [const Size(320, 800), const Size(1400, 900)]) {
      testWidgets('$source $size 双倍文字下自动检测、断网重试和失效提示', (tester) async {
        setTestViewport(tester, size);
        var requests = 0, online = false, expired = false;
        final client = MockClient((request) async {
          requests++;
          if (!online) throw http.ClientException('synthetic offline');
          if (expired) {
            return switch (source) {
              'sfacg' => json({
                'status': {'httpCode': 401},
              }, status: 401),
              'fanqie' => json({
                'message': 'error',
                'data': {'name': 'session_expired'},
              }),
              'qidian' => json({'Result': -2}),
              _ => http.Response(
                CiweimaoCrypto.encrypt(jsonEncode({'code': 200100})),
                200,
              ),
            };
          }
          return switch (source) {
            'sfacg' => json({
              'status': {'httpCode': 200},
              'data': {'accountId': 42},
            }),
            'fanqie' => json({
              'message': 'success',
              'data': {'user_id': '42'},
            }),
            'qidian' => json({
              'Result': 0,
              'Data': {
                'UserBasicInfo': {'UserId': 42},
              },
            }),
            _ => http.Response(
              CiweimaoCrypto.encrypt(
                jsonEncode({
                  'code': 100000,
                  'data': {
                    'reader_info': {
                      'reader_id': '42',
                      'account': 'synthetic-account',
                    },
                  },
                }),
              ),
              200,
            ),
          };
        });
        final sf = SfacgApi(client: client);
        final fq = FanqieApi(client: client);
        fq.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});
        final qd = QidianApi(client: client);
        final cat = CiweimaoApi(client: client);
        addTearDown(client.close);
        Widget page() => switch (source) {
          'sfacg' => Scaffold(
            body: AccountPage(
              library: Library(Directory.systemTemp, SfacgSource(sf)),
            ),
          ),
          'fanqie' => FanqieAccountPage(api: fq),
          'qidian' => QidianAccountPage(api: qd),
          _ => CiweimaoAccountPage(api: cat),
        };
        Widget app() => MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: page(),
        );
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        expect(requests, 0);
        expect(find.text('检测会话'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        sf.setCookie('.SFCommunity=original; session_APP=original');
        fq.setCookie('sessionid=original');
        qd.credentials = qidianSession();
        cat.restoreSession(catSession());
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        expect(requests, 1);
        expect(find.textContaining('暂时无法确认会话状态'), findsOneWidget);
        expect(find.text('会话已失效，请重新登录'), findsNothing);
        online = true;
        await tester.tap(find.text('检测会话'));
        await tester.pumpAndSettle();
        expect(requests, 2);
        expect(find.text('上次检测：会话有效'), findsOneWidget);
        expired = true;
        await tester.tap(find.text('检测会话'));
        await tester.pumpAndSettle();
        expect(requests, 3);
        expect(find.text('会话已失效，请重新登录'), findsOneWidget);
        expect(
          sf.hasSession && fq.hasSession && qd.hasSession && cat.hasSession,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('重复检测不并发，切换账号与销毁后迟到结果不覆盖当前状态', (tester) async {
    Object? session = Object();
    final pending = <Completer<void>>[];
    Widget page() => MaterialApp(
      home: Scaffold(
        body: AccountSessionCheck(
          session: session,
          currentSession: () => session,
          validate: () {
            final result = Completer<void>();
            pending.add(result);
            return result.future;
          },
        ),
      ),
    );
    await tester.pumpWidget(page());
    expect(pending, hasLength(1));
    await tester.tap(find.text('检测会话'));
    expect(pending, hasLength(1));
    session = Object();
    await tester.pumpWidget(page());
    expect(pending, hasLength(2));
    pending[1].complete();
    await tester.pumpAndSettle();
    expect(find.text('上次检测：会话有效'), findsOneWidget);
    pending[0].completeError(const SessionExpiredException('expired'));
    await tester.pumpAndSettle();
    expect(find.text('上次检测：会话有效'), findsOneWidget);
    await tester.tap(find.text('检测会话'));
    await tester.pumpWidget(const SizedBox.shrink());
    pending[2].complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
