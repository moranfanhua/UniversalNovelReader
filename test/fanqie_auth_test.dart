import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_auth.dart';
import 'package:unr/ui/fanqie_account.dart';

String unmix(String value) => utf8.decode([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16) ^ 5,
]);

void registered(FanqieApi api) =>
    api.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});

http.Response success({String? cookie, Map<String, Object> data = const {}}) =>
    http.Response(
      jsonEncode({'message': 'success', 'data': data}),
      200,
      headers: cookie == null ? {} : {'set-cookie': cookie},
    );

void main() {
  test('App 校验接受编码账号 ID，官网仍要求数字 ID；匿名和错误形状不通过', () async {
    Object? id;
    final api = FanqieApi(
      client: MockClient((request) async {
        final appRequest = request.url.host != 'fanqienovel.com';
        expect(
          request.url.path,
          appRequest ? '/reading/user/info/v/' : '/api/reader/user/info',
        );
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {'user_id': id},
          }),
          200,
        );
      }),
    )..setCookie('sessionid=synthetic');
    registered(api);
    addTearDown(api.close);
    for (final valid in ['encoded-user-Q7==', 'encoded/user+Q7=', '42', 42]) {
      id = valid;
      await api.validateSession(appSession: true);
    }
    for (final invalid in [
      null,
      '',
      '0',
      0,
      '-1',
      -1,
      false,
      'null',
      'guest',
      <String, Object>{},
      ['42'],
      'bad\r\nvalue',
    ]) {
      id = invalid;
      await expectLater(
        api.validateSession(appSession: true),
        throwsA(isA<SourceException>()),
      );
    }
    id = 'encoded-user-Q7==';
    await expectLater(api.validateSession(), throwsA(isA<SourceException>()));
    id = '42';
    await api.validateSession();
  });

  test('验证码请求按官方 SDK 混淆参数，不携带现有账号 Cookie 或自动重试', () async {
    final paths = <String>[];
    final api = FanqieApi(
      client: MockClient((request) async {
        paths.add(request.url.path);
        expect(request.url.host, 'security.snssdk.com');
        expect(request.method, 'POST');
        expect(request.followRedirects, isFalse);
        expect(request.url.queryParameters['device_id'], '1234567890');
        expect(request.headers['Cookie'], isNot(contains('old-account')));
        expect(request.body, isNot(contains('13800138000')));
        final fields = Uri.splitQueryString(request.body);
        expect(fields['mix_mode'], '1');
        expect(unmix(fields['mobile']!), '+8613800138000');
        if (paths.length == 1) {
          expect(unmix(fields['type']!), '24');
          return success(
            data: {'retry_time': 45},
            cookie: 'passport_csrf_token=csrf; Path=/; Secure',
          );
        }
        expect(unmix(fields['code']!), '123456');
        expect(request.headers['x-tt-passport-csrf-token'], 'csrf');
        return success(
          cookie:
              'sessionid=synthetic; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT, tracking_id=ignored; Path=/',
        );
      }),
    )..setCookie('sessionid=old-account');
    registered(api);
    addTearDown(api.close);
    final auth = FanqieAuth(api.client, api.app);
    expect(await auth.sendCode('13800138000'), 45);
    final cookie = await auth.verifyCode('+86 13800138000', '123456');
    expect(cookie, contains('sessionid=synthetic'));
    expect(cookie, isNot(contains('tracking_id')));
    expect(api.cookie, 'sessionid=old-account');
    expect(paths, [
      '/passport/mobile/send_code/v1/',
      '/passport/mobile/sms_login/',
    ]);
    auth.clear();
  });

  test('风控错误不回显手机号或验证码，不自动重试和覆盖现有会话', () async {
    var calls = 0;
    final api = FanqieApi(
      client: MockClient((_) async {
        calls++;
        return http.Response(
          jsonEncode({
            'message': 'error',
            'data': {
              'error_code': 7,
              'description': '13800138000 123456 private',
            },
          }),
          200,
        );
      }),
    )..setCookie('sessionid=old-account');
    registered(api);
    addTearDown(api.close);
    final auth = FanqieAuth(api.client, api.app);
    try {
      await auth.sendCode('13800138000');
      fail('必须拒绝认证限制响应');
    } on SourceException catch (error) {
      expect(error.code, 7);
      expect(error.message, isNot(contains('13800138000')));
      expect(error.message, isNot(contains('123456')));
    }
    expect(calls, 1);
    expect(api.cookie, 'sessionid=old-account');
    auth.clear();
  });

  test('无效输入不联网；登录成功但缺少会话仍拒绝保存', () async {
    var calls = 0;
    final api = FanqieApi(
      client: MockClient((_) async {
        calls++;
        return success();
      }),
    );
    registered(api);
    addTearDown(api.close);
    final auth = FanqieAuth(api.client, api.app);
    await expectLater(
      auth.sendCode('invalid'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      auth.verifyCode('13800138000', 'bad'),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 0);
    await expectLater(
      auth.verifyCode('13800138000', '123456'),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 1);
    expect(api.hasSession, isFalse);
    auth.clear();
  });

  testWidgets('选择手机号验证码登录，发送由点击触发，验证账号成功后才替换旧会话', (tester) async {
    var calls = 0, saves = 0;
    var valid = false;
    final api = FanqieApi(
      client: MockClient((request) async {
        calls++;
        if (request.url.host == 'security.snssdk.com') {
          return request.url.path.contains('send_code')
              ? success()
              : success(cookie: 'sessionid=new-account; Path=/; HttpOnly');
        }
        expect(
          request.url.path,
          isIn(['/reading/user/info/v/', '/api/reader/user/info']),
        );
        expect(request.headers['Cookie'], contains('sessionid=new-account'));
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': valid && request.url.host == 'fanqienovel.com'
                ? {'id': '42'}
                : {},
          }),
          200,
        );
      }),
    )..setCookie('sessionid=old-account');
    registered(api);
    addTearDown(api.close);
    api.onSessionChanged = () async {
      saves++;
    };
    await tester.pumpWidget(MaterialApp(home: FanqieAccountPage(api: api)));
    await tester.tap(find.text('手机号验证码登录'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.enterText(
      find.widgetWithText(TextField, '手机号'),
      '13800138000',
    );
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('秒后重新获取'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '短信验证码'), '123456');
    await tester.tap(find.text('登录并保存会话'));
    await tester.pumpAndSettle();
    expect(api.cookie, 'sessionid=old-account');
    expect(saves, 0);
    expect(find.text('本次登录尚未完成会话验证'), findsOneWidget);
    expect(find.text('已保存番茄登录会话'), findsNothing);
    expect(find.text('重新验证登录会话'), findsOneWidget);
    final callsBeforeRetry = calls;
    valid = true;
    await tester.ensureVisible(find.text('重新验证登录会话'));
    await tester.tap(find.text('重新验证登录会话'));
    await tester.pumpAndSettle();
    expect(calls, callsBeforeRetry + 2);
    expect(api.cookie, contains('sessionid=new-account'));
    expect(saves, 1);
    expect(find.text('本次登录尚未完成会话验证'), findsNothing);
    expect(find.text('已保存番茄登录会话'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
