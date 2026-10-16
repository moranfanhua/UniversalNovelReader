import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_auth.dart';
import 'package:unr/sources/qidian/qidian_session.dart';
import 'package:unr/ui/qidian_account.dart';

http.Response sdk(Map<String, Object> data) =>
    http.Response(jsonEncode({'code': 0, 'data': data}), 200);
http.Response login({int id = 10}) => http.Response(
  jsonEncode({
    'Result': 0,
    'Data': {
      'UserId': id,
      'LoginResult': {'CmfuToken': 'synthetic-token'},
    },
  }),
  200,
);
QidianCredentials saved() => QidianCredentials(
  userId: '10',
  ywGuid: '20',
  ywKey: 'synthetic-key',
  token: 'synthetic-token',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('短信发送、验证码登录、App 会话交换依次执行且不提前替换旧会话', () async {
    var calls = 0;
    final api = QidianApi(
      client: MockClient((r) async {
        calls++;
        expect(r.method, 'POST');
        expect(r.followRedirects, isFalse);
        if (r.url.host == 'ptlogin.yuewen.com') {
          expect(r.headers['Cookie'], isNull);
          expect(r.bodyFields['appid'], '12');
          expect(r.bodyFields['areaid'], '30');
          expect(r.bodyFields['signature'], isNotEmpty);
          expect(r.bodyFields['phone'], '13800000000');
          if (r.url.path == '/sdk/sendphonecode') {
            expect(r.bodyFields['type'], '1');
            expect(r.bodyFields['needRegister'], '1');
            return sdk({'sessionKey': 'synthetic-sms-key'});
          }
          expect(r.url.path, '/sdk/phonecodelogin');
          expect(r.bodyFields['phonekey'], 'synthetic-sms-key');
          expect(r.bodyFields['phonecode'], '123456');
          return sdk({'ywGuid': 30, 'ywKey': 'new-synthetic-key'});
        }
        expect(r.url.host, 'druidv6.if.qidian.com');
        expect(r.url.path, '/argus/api/v2/user/login');
        expect(r.bodyFields['ywguid'], '30');
        expect(r.bodyFields['ywkey'], 'new-synthetic-key');
        expect(r.headers['Cookie'], isNull);
        return login();
      }),
    );
    addTearDown(api.close);
    final old = saved();
    api.credentials = old;
    final auth = QidianAuth(api);
    await auth.sendCode('+8613800000000');
    expect(auth.resendSeconds, 60);
    await expectLater(
      auth.sendCode('13800000000'),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 1);
    final candidate = await auth.verifyCode('13800000000', '123456');
    expect(identical(api.credentials, old), isTrue);
    expect(candidate.ywGuid, '30');
    expect(candidate.userId, '10');
    var persisted = 0;
    api.onSessionChanged = () async => persisted++;
    await api.saveSession(candidate);
    expect(api.credentials, candidate);
    expect(persisted, 1);
    expect(calls, 3);
  });

  test('切换手机号、过期验证码、无验证码或销毁认证会话不触发登录请求', () async {
    var now = DateTime(2026);
    var count = 0;
    final api = QidianApi(
      clock: () => now,
      client: MockClient((_) async {
        count++;
        return sdk({'sessionKey': 'synthetic'});
      }),
    );
    addTearDown(api.close);
    final auth = QidianAuth(api);
    await auth.sendCode('13800000000');
    await expectLater(
      auth.verifyCode('13900000000', '123456'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      auth.verifyCode('13800000000', ''),
      throwsA(isA<SourceException>()),
    );
    now = now.add(const Duration(minutes: 6));
    await expectLater(
      auth.verifyCode('13800000000', '123456'),
      throwsA(isA<SourceException>()),
    );
    await auth.sendCode('13800000000');
    auth.clear();
    await expectLater(
      auth.verifyCode('13800000000', '123456'),
      throwsA(isA<SourceException>()),
    );
    expect(count, 2);
  });

  test('短信结果不确定不自动重发；风控验证码不会被当作发送成功', () async {
    var count = 0;
    final api = QidianApi(
      client: MockClient((_) async {
        count++;
        throw TimeoutException('synthetic');
      }),
    );
    addTearDown(api.close);
    final auth = QidianAuth(api);
    await expectLater(
      auth.sendCode('13800000000'),
      throwsA(isA<TimeoutException>()),
    );
    await expectLater(
      auth.sendCode('13800000000'),
      throwsA(isA<SourceException>()),
    );
    expect(count, 1);
    final riskApi = QidianApi(
      client: MockClient(
        (_) async => sdk({'nextAction': 11, 'sessionKey': 'risk'}),
      ),
    );
    addTearDown(riskApi.close);
    final risk = QidianAuth(riskApi);
    await expectLater(
      risk.sendCode('13800000000'),
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          'risk',
          contains('安全验证'),
        ),
      ),
    );
    await expectLater(
      risk.verifyCode('13800000000', '123456'),
      throwsA(isA<SourceException>()),
    );
  });

  test('登录失败保留原会话；App 验证未完成不能返回成功', () async {
    final api = QidianApi(
      client: MockClient((r) async {
        if (r.url.path == '/sdk/sendphonecode') {
          return sdk({'sessionKey': 'synthetic'});
        }
        if (r.url.path == '/sdk/phonecodelogin') {
          return sdk({'ywGuid': 30, 'ywKey': 'candidate'});
        }
        return http.Response('{"Result":-2}', 200);
      }),
    );
    addTearDown(api.close);
    final old = saved();
    api.credentials = old;
    final auth = QidianAuth(api);
    await auth.sendCode('13800000000');
    await expectLater(
      auth.verifyCode('13800000000', '123456'),
      throwsA(isA<SourceException>()),
    );
    expect(api.credentials, old);
  });

  test('起点会话恢复失败不改写旧存储，也不影响其他平台', () async {
    FlutterSecureStorage.setMockInitialValues({
      QidianSession.key: 'corrupt original',
      'unr.fanqie.session.v1': 'preserved',
    });
    final api = await QidianSession.open();
    addTearDown(api.close);
    expect(api.hasSession, isFalse);
    expect(api.sessionNotice, contains('原存储已保留'));
    const storage = FlutterSecureStorage();
    expect(await storage.read(key: QidianSession.key), 'corrupt original');
    await api.saveSession(saved());
    final restored = await QidianSession.open();
    addTearDown(restored.close);
    expect(restored.device, api.device);
    expect(restored.credentials!.ywGuid, '20');
    await QidianSession.logout(restored);
    final loggedOut = await QidianSession.open();
    addTearDown(loggedOut.close);
    expect(loggedOut.hasSession, isFalse);
    expect(loggedOut.device, api.device);
    expect(await storage.read(key: 'unr.fanqie.session.v1'), 'preserved');
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('手机号登录页面适配宽度 $width 与两倍文字', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = QidianApi(
        client: MockClient((_) async => sdk({'sessionKey': 'synthetic'})),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: QidianAccountPage(api: api),
        ),
      );
      expect(find.text('获取验证码'), findsOneWidget);
      expect(find.text('账号密码登录'), findsNothing);
      await tester.enterText(find.byType(TextField).first, '13800000000');
      await tester.ensureVisible(find.text('获取验证码'));
      await tester.tap(find.text('获取验证码'));
      await tester.pump();
      expect(find.text('60 秒后重新获取'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('离开登录页后到达的登录结果不会替换或保存会话', (tester) async {
    final pending = Completer<http.Response>();
    var saves = 0;
    final api = QidianApi(
      client: MockClient((r) async {
        if (r.url.path == '/sdk/sendphonecode') {
          return sdk({'sessionKey': 'synthetic'});
        }
        if (r.url.path == '/sdk/phonecodelogin') {
          return sdk({'ywGuid': 30, 'ywKey': 'candidate'});
        }
        return pending.future;
      }),
    );
    addTearDown(api.close);
    api.onSessionChanged = () async {
      saves++;
    };
    await tester.pumpWidget(MaterialApp(home: QidianAccountPage(api: api)));
    await tester.enterText(find.byType(TextField).first, '13800000000');
    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.text('登录起点读书'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(login());
    await tester.pump();
    expect(api.hasSession, isFalse);
    expect(saves, 0);
    expect(tester.takeException(), isNull);
  });
}
