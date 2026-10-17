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
    expect(calls, 2);
    await api.saveSession(candidate);
    expect(api.hasSession, isTrue);
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
    final api = CiweimaoApi(client: MockClient((_) => response.future))
      ..restoreSession(credentials(guest: true));
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
