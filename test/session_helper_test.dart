import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:unr/ui/session_helper_page.dart';

http.Response sfResponse(Object data, {int status = 200}) => http.Response(
  jsonEncode({
    'status': {'httpCode': status},
    'data': data,
  }),
  status,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const helper = MethodChannel('unr/session_helper');
  const events = MethodChannel('unr/session_helper/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() {
    messenger.setMockMethodCallHandler(helper, null);
    messenger.setMockMethodCallHandler(events, null);
  });

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

  testWidgets(
    '番茄账号页仅提供 App 登录，不调用网页助手',
    (tester) async {
      messenger.setMockMethodCallHandler(helper, (_) async => fail('不得调用网页助手'));
      final api = FanqieApi();
      addTearDown(api.close);
      await tester.pumpWidget(MaterialApp(home: FanqieAccountPage(api: api)));
      expect(find.text('网页登录'), findsNothing);
      expect(find.text('手机号验证码登录'), findsOneWidget);
      expect(find.text('VPN 辅助登录'), findsOneWidget);
      await tester.tap(find.text('手机号验证码登录'));
      await tester.pumpAndSettle();
      expect(find.text('获取验证码'), findsOneWidget);
      expect(find.text('改用网页登录'), findsNothing);
      expect(find.text('打开官网登录'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    '菠萝包仅提供 App 登录，不调用网页助手',
    (tester) async {
      messenger.setMockMethodCallHandler(helper, (_) async => fail('不得打开网页'));
      final api = SfacgApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountPage(
              library: Library(Directory.systemTemp, SfacgSource(api)),
            ),
          ),
        ),
      );
      expect(find.text('网页登录'), findsNothing);
      expect(find.text('VPN 辅助登录'), findsOneWidget);
      await tester.tap(find.text('账号密码登录'));
      await tester.pumpAndSettle();
      expect(find.text('登录菠萝包'), findsOneWidget);
      expect(find.text('打开官网登录'), findsNothing);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'VPN 入口要求证书，拒绝授权可恢复并在退出时停止',
    (tester) async {
      var installed = false, denied = true;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(helper, (call) async {
        methods.add(call.method);
        return switch (call.method) {
          'prepare' => {
            'phase': 'idle',
            'certificateInstalled': installed,
            'appInstalled': true,
          },
          'installCertificate' => 'UNR-session-CA.cer',
          'certificateSettings' => null,
          'start' =>
            denied
                ? throw PlatformException(
                    code: 'cancelled',
                    message: '未授权 VPN，请使用短信、账号密码或导入 App 会话',
                  )
                : {'phase': 'capturing', 'source': 'fanqie', 'requests': 0},
          'stop' => null,
          _ => throw StateError('意外调用 ${call.method}'),
        };
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: SessionHelperPage(source: 'fanqie', name: '番茄小说'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '启动 VPN 辅助'),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('安装本机抓包证书'));
      await tester.tap(find.text('安装本机抓包证书'));
      await tester.pumpAndSettle();
      expect(find.textContaining('下载/UNR-session-CA.cer'), findsOneWidget);
      await tester.tap(find.text('打开系统设置'));
      await tester.pumpAndSettle();
      installed = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('启动 VPN 辅助'));
      await tester.tap(find.text('启动 VPN 辅助'));
      await tester.pumpAndSettle();
      expect(find.text('未授权 VPN，请使用短信、账号密码或导入 App 会话'), findsOneWidget);
      denied = false;
      await tester.tap(find.text('启动 VPN 辅助'));
      await tester.pumpAndSettle();
      expect(find.textContaining('正在等待官方 App 请求'), findsOneWidget);
      expect(find.text('停止抓取'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(methods.last, 'stop');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    '非 Android 保留原有登录，不调用原生会话助手',
    (tester) async {
      messenger.setMockMethodCallHandler(
        helper,
        (_) async => fail('非 Android 不应调用原生会话助手'),
      );
      final api = FanqieApi();
      addTearDown(api.close);
      await tester.pumpWidget(MaterialApp(home: FanqieAccountPage(api: api)));
      expect(find.text('网页登录'), findsNothing);
      expect(find.text('VPN 辅助登录'), findsNothing);
      await tester.tap(find.text('导入会话'));
      await tester.pumpAndSettle();
      expect(find.text('验证并保存会话'), findsOneWidget);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  for (final source in ['sfacg', 'fanqie']) {
    testWidgets(
      '$source 的 VPN 辅助打开官方 App 并按 App 会话验证，不进入网页',
      (tester) async {
        var phase = 'idle', saves = 0;
        final calls = <String>[];
        messenger.setMockMethodCallHandler(events, (_) async => null);
        messenger.setMockMethodCallHandler(helper, (call) async {
          calls.add(call.method);
          if (call.method != 'stop') expect(call.arguments, {'source': source});
          switch (call.method) {
            case 'prepare':
              return {
                'phase': phase,
                'source': source,
                'certificateInstalled': true,
                'appInstalled': true,
              };
            case 'start':
              phase = 'capturing';
              return {'phase': phase, 'source': source};
            case 'openApp':
              phase = 'captured';
              return null;
            case 'captureResult':
              return source == 'sfacg'
                  ? '.SFCommunity=app; session_APP=app-session'
                  : 'sessionid=app-session';
            case 'stop':
              return null;
            default:
              fail('VPN 辅助不应调用 ${call.method}');
          }
        });
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
        await tester.tap(find.text('VPN 辅助登录'));
        await tester.pumpAndSettle();
        expect(find.text('打开官网登录'), findsNothing);
        await tester.ensureVisible(find.text('启动 VPN 辅助'));
        await tester.tap(find.text('启动 VPN 辅助'));
        await tester.pumpAndSettle();
        final openApp = find.text(
          '打开${source == 'sfacg' ? '菠萝包' : '番茄小说'}官方 App',
        );
        await tester.ensureVisible(openApp);
        await tester.tap(openApp);
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('验证并保存 App 会话'));
        await tester.tap(find.text('验证并保存 App 会话'));
        await tester.pumpAndSettle();
        expect(saves, 1);
        expect(
          calls,
          containsAllInOrder(['start', 'openApp', 'captureResult', 'stop']),
        );
        expect(calls, isNot(contains('openLogin')));
        if (source == 'sfacg') expect(sf.websiteSession, isFalse);
        expect(source == 'sfacg' ? sf.hasSession : fq.hasSession, isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
  }
}
