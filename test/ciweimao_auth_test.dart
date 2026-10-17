import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_auth.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/ciweimao/ciweimao_session.dart';
import 'package:unr/ui/account_login_method.dart';
import 'package:unr/ui/ciweimao_account.dart';

CiweimaoCredentials credentials({String id = '106', bool guest = false}) =>
    CiweimaoCredentials(
      account: 'synthetic-account',
      token: 'synthetic-token-1234',
      readerId: id,
      guest: guest,
    );
Map<String, Object> reader({String id = '106'}) => {
  'account': 'synthetic-account',
  'reader_id': id,
  'reader_name': '合成读者',
  'is_bind': 1,
};
http.Response ok(Object data, {int code = 100000}) => http.Response(
  CiweimaoCrypto.encrypt(jsonEncode({'code': code, 'data': data})),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('密码使用官方 RSA，校验新会话完成前不替换旧账号', () async {
    var calls = 0;
    final old = credentials(id: '102');
    late CiweimaoApi api;
    api = CiweimaoApi(
      client: MockClient((r) async {
        calls++;
        expect(api.credentials, same(old));
        if (r.url.path == '/signup/use_geetest') {
          expect(r.bodyFields['login_name'], '合成账号');
          expect(r.bodyFields['passwd'], isNull);
          return ok({'need_use_geetest': '0'});
        }
        if (r.url.path == '/signup/login') {
          expect(r.bodyFields['login_name'], '合成账号');
          expect(base64Decode(r.bodyFields['passwd']!), hasLength(256));
          expect(base64Decode(r.bodyFields['sign']!), hasLength(256));
          expect(r.body, isNot(contains('plaintext-password')));
          return ok({
            'reader_info': reader(),
            'login_token': 'synthetic-token-1234',
          });
        }
        expect(r.url.path, '/reader/get_my_info');
        expect(r.url.host, 'app1.hbooker.com');
        return ok({'reader_info': reader()});
      }),
    )..restoreSession(old);
    addTearDown(api.close);
    final candidate = await CiweimaoAuth(
      api,
    ).passwordLogin(' 合成账号 ', 'plaintext-password');
    expect(candidate.readerId, '106');
    expect(api.credentials, same(old));
    expect(calls, 3);
    await api.saveSession(candidate);
    expect(api.hasSession, isTrue);
  });
  test('密码登录先查询验证方式，按 APK 用途 5 发送并提交 ver_code 与 to_code', () async {
    final paths = <String>[];
    final original = credentials(id: '102');
    final now = DateTime(2026, 10, 17);
    final api = CiweimaoApi(
      clock: () => now,
      client: MockClient((r) async {
        paths.add(r.url.path);
        final fields = r.bodyFields;
        switch (r.url.path) {
          case '/signup/use_geetest':
            expect(fields['login_name'], 'synthetic@example.invalid');
            return ok({'need_use_geetest': '2', 'code_len': '6'});
          case '/signup/send_verify_code':
            expect(fields['login_name'], 'synthetic@example.invalid');
            expect(fields['verify_type'], '5');
            expect(fields['phone_num'], '');
            expect(fields['timestamp'], '${now.millisecondsSinceEpoch}');
            expect(fields['hashvalue'], matches(RegExp(r'^[a-f0-9]{32}$')));
            return ok({'to_code': 'synthetic-password-verification'});
          case '/signup/login':
            expect(fields['ver_code'], '123456');
            expect(fields['to_code'], 'synthetic-password-verification');
            expect(base64Decode(fields['passwd']!), hasLength(256));
            return ok({
              'reader_info': reader(),
              'login_token': 'synthetic-token-1234',
            });
          default:
            expect(r.url.path, '/reader/get_my_info');
            return ok({'reader_info': reader()});
        }
      }),
    )..restoreSession(original);
    addTearDown(api.close);
    final auth = CiweimaoAuth(api);
    await expectLater(
      auth.passwordLogin(' synthetic@example.invalid ', 'password'),
      throwsA(isA<SourceException>().having((e) => e.code, 'code', 210000)),
    );
    expect(paths, ['/signup/use_geetest']);
    expect(auth.passwordCodeLength, 6);
    await Future.wait([
      auth.sendPasswordCode('synthetic@example.invalid'),
      expectLater(
        auth.sendPasswordCode('synthetic@example.invalid'),
        throwsA(isA<SourceException>()),
      ),
    ]);
    expect(auth.passwordResendSeconds, 60);
    await expectLater(
      auth.passwordLogin('synthetic@example.invalid', 'password', code: '1234'),
      throwsA(isA<SourceException>()),
    );
    final candidate = await auth.passwordLogin(
      'synthetic@example.invalid',
      'password',
      code: ' 123456 ',
    );
    expect(candidate.readerId, '106');
    expect(api.credentials, same(original));
    expect(paths, [
      '/signup/use_geetest',
      '/signup/send_verify_code',
      '/signup/login',
      '/reader/get_my_info',
    ]);
  });
  test('密码验证码不得跨账号、跨会话或过期使用，切换为免验证账号不携带旧凭据', () async {
    var now = DateTime(2026, 10, 17), logins = 0;
    final api = CiweimaoApi(
      clock: () => now,
      client: MockClient((r) async {
        if (r.url.path == '/signup/use_geetest') {
          return ok(
            r.bodyFields['login_name'] == 'other'
                ? {'need_use_geetest': '0'}
                : {'need_use_geetest': '2', 'code_len': 4},
          );
        }
        if (r.url.path == '/signup/send_verify_code') {
          return ok({'to_code': 'synthetic-verification'});
        }
        if (r.url.path == '/signup/login') {
          logins++;
          expect(r.bodyFields['login_name'], 'other');
          expect(r.bodyFields['to_code'], isNull);
          expect(r.bodyFields['ver_code'], isNull);
          return ok({
            'reader_info': reader(),
            'login_token': 'synthetic-token-1234',
          });
        }
        return ok({'reader_info': reader()});
      }),
    )..restoreSession(credentials(guest: true));
    addTearDown(api.close);
    final auth = CiweimaoAuth(api);
    Future<void> prepare() async {
      await expectLater(
        auth.passwordLogin('synthetic', 'password'),
        throwsA(isA<SourceException>()),
      );
      await auth.sendPasswordCode('synthetic');
    }

    await prepare();
    await expectLater(
      auth.sendPasswordCode('other'),
      throwsA(isA<SourceException>()),
    );
    now = now.add(const Duration(minutes: 6));
    await expectLater(
      auth.passwordLogin('synthetic', 'password', code: '1234'),
      throwsA(isA<SourceException>()),
    );
    expect(logins, 0);
    await auth.sendPasswordCode('synthetic');
    api.restoreSession(credentials(id: '107', guest: true));
    await expectLater(
      auth.sendPasswordCode('synthetic'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      auth.passwordLogin('synthetic', 'password', code: '1234'),
      throwsA(isA<SourceException>()),
    );
    expect(logins, 0);
    await auth.passwordLogin('other', 'password');
    expect(logins, 1);
    expect(auth.passwordCodeLength, isNull);
  });
  test('密码验证码发送失败或缺少 to_code 不重发，保留冷却且不提交登录', () async {
    for (final timeout in [true, false]) {
      var sends = 0, logins = 0;
      final api = CiweimaoApi(
        client: MockClient((r) async {
          if (r.url.path == '/signup/use_geetest') {
            return ok({'need_use_geetest': '2', 'code_len': '4'});
          }
          if (r.url.path == '/signup/send_verify_code') {
            sends++;
            if (timeout) throw TimeoutException('synthetic');
            return ok({});
          }
          logins++;
          return ok({});
        }),
      )..restoreSession(credentials(guest: true));
      addTearDown(api.close);
      final auth = CiweimaoAuth(api);
      await expectLater(
        auth.passwordLogin('synthetic', 'password'),
        throwsA(isA<SourceException>()),
      );
      await expectLater(
        auth.sendPasswordCode('synthetic'),
        throwsA(isA<SourceException>()),
      );
      await expectLater(
        auth.sendPasswordCode('synthetic'),
        throwsA(isA<SourceException>()),
      );
      await expectLater(
        auth.passwordLogin('synthetic', 'password', code: '1234'),
        throwsA(isA<SourceException>()),
      );
      expect(auth.passwordResendSeconds, greaterThan(0));
      expect(sends, 1);
      expect(logins, 0);
    }
  });
  test('取消登录使迟到的密码预检与验证码响应失效', () async {
    for (final cancelSend in [false, true]) {
      final delayed = Completer<http.Response>();
      final started = Completer<void>();
      final api = CiweimaoApi(
        client: MockClient((r) async {
          if (cancelSend && r.url.path == '/signup/use_geetest') {
            return ok({'need_use_geetest': '2', 'code_len': 4});
          }
          started.complete();
          return delayed.future;
        }),
      )..restoreSession(credentials(guest: true));
      addTearDown(api.close);
      final auth = CiweimaoAuth(api);
      if (cancelSend) {
        await expectLater(
          auth.passwordLogin('synthetic', 'password'),
          throwsA(isA<SourceException>()),
        );
      }
      final pending = cancelSend
          ? auth.sendPasswordCode('synthetic')
          : auth.passwordLogin('synthetic', 'password');
      final checked = expectLater(pending, throwsA(isA<SourceException>()));
      await started.future;
      auth.clear();
      delayed.complete(
        ok(
          cancelSend
              ? {'to_code': 'synthetic-verification'}
              : {'need_use_geetest': '2', 'code_len': 4},
        ),
      );
      await checked;
      expect(auth.passwordCodeLength, isNull);
      expect(api.hasSession, isFalse);
    }
  });
  test('极验及未知验证方式不得直接发送密码登录', () async {
    for (final data in [
      {'need_use_geetest': '1'},
      {'need_use_geetest': 'unexpected'},
      {'need_use_geetest': '2', 'code_len': '0'},
      <String, String>{},
    ]) {
      var calls = 0;
      final api = CiweimaoApi(
        client: MockClient((r) async {
          calls++;
          expect(r.url.path, '/signup/use_geetest');
          return ok(data);
        }),
      )..restoreSession(credentials(guest: true));
      addTearDown(api.close);
      await expectLater(
        CiweimaoAuth(api).passwordLogin('synthetic', 'password'),
        throwsA(isA<SourceException>()),
      );
      expect(calls, 1);
    }
  });
  test('短信请求与 APK 的地区号、用途及校验一致，手机号切换与过期拒绝登录', () async {
    var now = DateTime(2026, 10, 17), sends = 0, logins = 0;
    final api = CiweimaoApi(
      clock: () => now,
      client: MockClient((r) async {
        if (r.url.path == '/signup/send_verify_code') {
          sends++;
          expect(r.bodyFields['login_name'], '86-13800000000');
          expect(r.bodyFields['verify_type'], '6');
          expect(r.bodyFields['phone_num'], '');
          expect(r.bodyFields['hashvalue'], hasLength(32));
          return ok({});
        }
        if (r.url.path == '/signup/login_v2') {
          logins++;
          expect(r.bodyFields['phone_num'], '86-13800000000');
          expect(r.bodyFields['ver_code'], '123456');
          expect(r.bodyFields['uuid'], apiInstallation);
          return ok({
            'reader_info': reader(),
            'login_token': 'synthetic-token-1234',
          });
        }
        return ok({'reader_info': reader()});
      }),
      installation: apiInstallation,
    )..restoreSession(credentials(guest: true));
    addTearDown(api.close);
    final auth = CiweimaoAuth(api);
    await auth.sendCode('+8613800000000');
    expect(auth.resendSeconds, 60);
    await expectLater(
      auth.sendCode('13800000000'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      auth.verifyCode('13900000000', '123456'),
      throwsA(isA<SourceException>()),
    );
    final result = await auth.verifyCode('13800000000', '123456');
    expect(result.readerId, '106');
    now = now.add(const Duration(minutes: 6));
    await expectLater(
      auth.verifyCode('13800000000', '123456'),
      throwsA(isA<SourceException>()),
    );
    expect(sends, 1);
    expect(logins, 1);
  });
  test('短信超时不重发，冷却期保留且不允许将未确认发送作为登录凭据', () async {
    var count = 0;
    final api = CiweimaoApi(
      client: MockClient((_) async {
        count++;
        throw TimeoutException('synthetic');
      }),
    )..restoreSession(credentials(guest: true));
    addTearDown(api.close);
    final auth = CiweimaoAuth(api);
    await expectLater(
      auth.sendCode('13800000000'),
      throwsA(isA<SourceException>()),
    );
    expect(auth.resendSeconds, greaterThan(0));
    await expectLater(
      auth.sendCode('13800000000'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      auth.verifyCode('13800000000', '123456'),
      throwsA(isA<SourceException>()),
    );
    expect(count, 1);
  });
  test('App 会话导入校验账号归属，失败或取消保留原会话', () async {
    var mismatch = true;
    final response = Completer<http.Response>();
    final api = CiweimaoApi(
      client: MockClient(
        (_) async =>
            mismatch ? ok({'reader_info': reader(id: '999')}) : response.future,
      ),
    )..restoreSession(credentials());
    addTearDown(api.close);
    final original = api.credentials;
    final auth = CiweimaoAuth(api);
    final input = jsonEncode(credentials().toJson());
    await expectLater(
      auth.importSession(input),
      throwsA(isA<SourceException>()),
    );
    expect(api.credentials, same(original));
    mismatch = false;
    final pending = auth.importSession(input);
    final checked = expectLater(pending, throwsA(isA<SourceException>()));
    auth.clear();
    response.complete(ok({'reader_info': reader()}));
    await checked;
    expect(api.credentials, same(original));
    for (final value in ['account=web-cookie', '[]', '{}']) {
      await expectLater(
        auth.importSession(value),
        throwsA(isA<SourceException>()),
      );
    }
  });
  test('登录状态独立持久化，退出保留设备身份和其他书源数据', () async {
    FlutterSecureStorage.setMockInitialValues({
      'unr.sfacg.session.v1': 'preserved',
    });
    final api = await CiweimaoSession.open();
    addTearDown(api.close);
    await api.saveSession(credentials());
    final restored = await CiweimaoSession.open();
    addTearDown(restored.close);
    expect(restored.credentials!.account, api.credentials!.account);
    expect(restored.installation, api.installation);
    await CiweimaoSession.logout(restored);
    expect(restored.hasSession, isFalse);
    final again = await CiweimaoSession.open();
    addTearDown(again.close);
    expect(again.installation, api.installation);
    expect(again.credentials, isNull);
    expect(
      await const FlutterSecureStorage().read(key: 'unr.sfacg.session.v1'),
      'preserved',
    );
  });
  test('损坏会话不会阻止启动，游客建立也不覆盖原始存储', () async {
    for (final raw in ['{broken', '[]', '{"installation":false}']) {
      FlutterSecureStorage.setMockInitialValues({CiweimaoSession.key: raw});
      final api = await CiweimaoSession.open();
      expect(api.hasSession, isFalse);
      expect(api.sessionNotice, contains('原存储已保留'));
      await api.saveSession(credentials(guest: true));
      expect(
        await const FlutterSecureStorage().read(key: CiweimaoSession.key),
        raw,
      );
      await api.saveSession(credentials());
      expect(api.sessionNotice, isNull);
      expect(
        await const FlutterSecureStorage().read(key: CiweimaoSession.key),
        isNot(raw),
      );
      api.close();
    }
  });
  for (final size in [const Size(390, 844), const Size(1400, 900)]) {
    testWidgets('密码登录安全验证码在 $size 和双倍文字下可发送、输入并完成登录', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var sends = 0;
      final api = CiweimaoApi(
        client: MockClient((r) async {
          switch (r.url.path) {
            case '/signup/use_geetest':
              return ok({'need_use_geetest': '2', 'code_len': '4'});
            case '/signup/send_verify_code':
              sends++;
              expect(r.bodyFields['verify_type'], '5');
              return ok({'to_code': 'synthetic-verification'});
            case '/signup/login':
              expect(r.bodyFields['ver_code'], '1234');
              expect(r.bodyFields['to_code'], 'synthetic-verification');
              return ok({
                'reader_info': reader(),
                'login_token': 'synthetic-token-1234',
              });
            default:
              return ok({'reader_info': reader()});
          }
        }),
      )..restoreSession(credentials(guest: true));
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CiweimaoAccountPage(
            api: api,
            method: AccountLoginMethod.password,
          ),
        ),
      );
      await tester.enterText(
        find.byType(TextField).at(0),
        'synthetic@example.invalid',
      );
      await tester.enterText(find.byType(TextField).at(1), 'password');
      await tester.ensureVisible(find.text('登录刺猬猫'));
      await tester.tap(find.text('登录刺猬猫'));
      await tester.pumpAndSettle();
      expect(sends, 0);
      expect(find.text('当前账号需要 4 位登录验证码'), findsOneWidget);
      await tester.ensureVisible(find.text('获取登录验证码'));
      await tester.tap(find.text('获取登录验证码'));
      await tester.pumpAndSettle();
      expect(sends, 1);
      expect(find.text('验证码已发送，请查看邮箱'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField).at(2));
      await tester.enterText(find.byType(TextField).at(2), '1234');
      await tester.ensureVisible(find.text('登录刺猬猫'));
      await tester.tap(find.text('登录刺猬猫'));
      await tester.pumpAndSettle();
      expect(api.hasSession, isTrue);
      expect(find.text('刺猬猫登录成功，会话已保存在本机安全存储中'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    for (final method in AccountLoginMethod.values) {
      testWidgets('账号表单在 $size、两倍文字缩放下可使用：${method.label}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = CiweimaoApi();
        addTearDown(api.close);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: CiweimaoAccountPage(api: api, method: method),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.textContaining('网页登录'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets('离开登录页后迟到响应不保存账号', (tester) async {
    final response = Completer<http.Response>();
    final api = CiweimaoApi(
      client: MockClient(
        (r) async => r.url.path == '/signup/use_geetest'
            ? ok({'need_use_geetest': '0'})
            : response.future,
      ),
    )..restoreSession(credentials(guest: true));
    addTearDown(api.close);
    var saves = 0;
    api.onSessionChanged = () async {
      saves++;
    };
    await tester.pumpWidget(
      MaterialApp(
        home: CiweimaoAccountPage(
          api: api,
          method: AccountLoginMethod.password,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).at(0), 'synthetic');
    await tester.enterText(find.byType(TextField).at(1), 'synthetic-password');
    await tester.tap(find.text('登录刺猬猫'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    response.complete(
      ok({'reader_info': reader(), 'login_token': 'synthetic-token-1234'}),
    );
    await tester.pump();
    expect(saves, 0);
    expect(api.hasSession, isFalse);
    expect(tester.takeException(), isNull);
  });
}

const apiInstallation = '12345678-1234-4321-8765-123456789abc';
