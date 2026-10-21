import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_session.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/account.dart';
import 'package:unr/ui/fanqie_account.dart';

http.Response sfResponse(Object data, {int status = 200}) => http.Response(
  jsonEncode({
    'status': {'httpCode': status},
    'data': data,
  }),
  status,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('菠萝包按官方 accountId 校验会话，拒绝匿名及无效账号且保留原会话', () async {
    Object? user;
    var saves = 0;
    final api = SfacgApi(client: MockClient((_) async => sfResponse(user!)))
      ..setCookie('.SFCommunity=original; session_APP=original-app');
    addTearDown(api.close);
    api.onSessionChanged = () async {
      saves++;
    };
    for (final invalid in [
      <String, Object>{},
      {'accountId': 0},
      {'accountId': -1},
      {'accountId': 'invalid'},
      {'accountId': 0, 'userId': 42},
    ]) {
      user = invalid;
      await expectLater(
        api.importCookie('.SFCommunity=candidate; session_APP=candidate-app'),
        throwsA(isA<SourceException>()),
      );
      expect(api.cookies['.SFCommunity'], 'original');
      expect(api.websiteSession, isFalse);
      expect(saves, 0);
    }
    for (final accountId in [42, '42']) {
      user = {'accountId': accountId};
      await api.importCookie(
        '.SFCommunity=candidate; session_APP=candidate-app',
      );
      expect(api.websiteSession, isFalse);
      expect(api.cookies, {
        '.SFCommunity': 'candidate',
        'session_APP': 'candidate-app',
      });
    }
    expect(saves, 2);
  });

  test('旧网页会话恢复后不可用于认证，退出清除；不完整 App 会话仍拒绝', () async {
    final api = await SfacgSession.open();
    addTearDown(api.close);
    api.setCookie('.SFCommunity=synthetic-web', website: true);
    await api.onSessionChanged!();
    final restored = await SfacgSession.open();
    addTearDown(restored.close);
    expect(restored.hasSession, isFalse);
    expect(restored.websiteSession, isTrue);
    expect(
      () => restored.setCookie('.SFCommunity=incomplete'),
      throwsA(isA<SourceException>()),
    );
    await SfacgSession.logout(restored);
    expect(restored.websiteSession, isFalse);
    expect(restored.hasSession, isFalse);
  });

  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });
  for (final (name, method, form, page) in [
    (
      '番茄账号页保留短信登录和会话导入，不再提供 VPN',
      '手机号验证码登录',
      '获取验证码',
      () {
        final api = FanqieApi();
        addTearDown(api.close);
        return FanqieAccountPage(api: api);
      },
    ),
    (
      '菠萝包账号页保留密码登录和会话导入，不再提供 VPN',
      '账号密码登录',
      '登录菠萝包',
      () {
        final api = SfacgApi();
        addTearDown(api.close);
        return Scaffold(
          body: AccountPage(
            library: Library(Directory.systemTemp, SfacgSource(api)),
          ),
        );
      },
    ),
  ]) {
    testWidgets(name, (tester) async {
      await tester.pumpWidget(MaterialApp(home: page()));
      expect(find.text('网页登录'), findsNothing);
      expect(find.text('VPN 辅助登录'), findsNothing);
      expect(find.text('导入会话'), findsOneWidget);
      expect(find.text(method), findsOneWidget);
      await tester.tap(find.text(method));
      await tester.pumpAndSettle();
      expect(find.text(form), findsOneWidget);
      expect(find.text('改用网页登录'), findsNothing);
      expect(find.text('打开官网登录'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: platforms);
  }

  for (final source in ['sfacg', 'fanqie']) {
    testWidgets('$source 手动导入会话仍通过 App 接口验证并保存', (tester) async {
      var saves = 0;
      final sf = SfacgApi(
        client: MockClient((request) async {
          expect(request.url.host, 'api.sfacg.com');
          expect(request.url.path, '/user');
          expect(
            request.headers['Cookie'],
            contains('session_APP=app-session'),
          );
          return sfResponse({'accountId': 42});
        }),
      );
      final fq = FanqieApi(
        client: MockClient((request) async {
          expect(request.url.host, 'security.snssdk.com');
          expect(request.url.path, '/passport/account/info/v2/');
          expect(request.headers['Cookie'], 'sessionid=app-session');
          return http.Response(
            jsonEncode({
              'message': 'success',
              'data': {'user_id': '42'},
            }),
            200,
          );
        }),
      );
      fq.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});
      addTearDown(sf.close);
      addTearDown(fq.close);
      sf.onSessionChanged = fq.onSessionChanged = () async {
        saves++;
      };
      await tester.pumpWidget(
        MaterialApp(
          home: source == 'sfacg'
              ? Scaffold(
                  body: AccountPage(
                    library: Library(Directory.systemTemp, SfacgSource(sf)),
                  ),
                )
              : FanqieAccountPage(api: fq),
        ),
      );
      await tester.tap(find.text('导入会话'));
      await tester.pumpAndSettle();
      expect(find.text('打开官网登录'), findsNothing);
      await tester.enterText(
        find.byType(TextField),
        source == 'sfacg'
            ? '.SFCommunity=app; session_APP=app-session'
            : 'sessionid=app-session',
      );
      await tester.tap(find.text('验证并保存会话'));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      if (source == 'sfacg') expect(sf.websiteSession, isFalse);
      expect(source == 'sfacg' ? sf.hasSession : fq.hasSession, isTrue);
      expect(tester.takeException(), isNull);
    }, variant: platforms);
  }
}
