import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/novel_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_auth.dart';
import 'package:unr/sources/qidian/qidian_native.dart';
import 'package:unr/sources/qidian/qidian_device_profile.dart';

const heads = {
  'QDSign': 'synthetic-sign',
  'borgus': 'synthetic-borgus',
  'cecelia': 'synthetic-script',
  'tstamp': '1',
  'QDInfo': 'synthetic-info',
  'User-Agent': 'synthetic-agent',
  'Cookie': 'synthetic-cookie',
  'gorgon': 'synthetic-environment',
  'ibex': 'synthetic-report',
};
QidianCredentials account(String id) => QidianCredentials(
  userId: id,
  ywGuid: id,
  ywKey: 'synthetic-key-$id',
  token: 'synthetic-token-$id',
);

void main() {
  test('Windows 兼容设备档案包含指定型号和 Android 16，Android 不套用此档案', () {
    const profile = QidianDeviceProfile.windows;
    expect(profile.brand, 'Xiaomi');
    expect(profile.model, 'Xiaomi 17 Pro Max');
    expect(profile.androidRelease, '16');
    expect(profile.androidApiLevel, 36);
    expect(profile.packageName, 'com.qidian.QDReader');
    expect(profile.cpuAbi, 'arm64-v8a');
    expect(profile.screenWidth, 1200);
    expect(profile.screenHeight, 2608);
    expect(profile.screenDiagonalInches, 6.9);
    final provider = NativeQidianSecurity();
    expect(provider.deviceProfile, Platform.isWindows ? same(profile) : isNull);
    provider.close();
  });

  test('Windows SDK 登录字段与原生兼容设备档案一致', () async {
    var requests = 0;
    final provider = NativeQidianSecurity(
      directory: () async => '/synthetic',
      dispatch: (input) async {
        if (input['op'] == 'create') return {'ok': true, 'handle': '1'};
        if (input['op'] == 'ensure') return {'ok': true, 'ready': true};
        return {'ok': true, 'headers': heads};
      },
    );
    final api = QidianApi(
      security: provider,
      client: MockClient((request) async {
        requests++;
        final fields = Uri.splitQueryString(request.body);
        expect(fields['devicetype'], 'Xiaomi_Xiaomi 17 Pro Max');
        expect(fields['devicename'], 'Xiaomi 17 Pro Max');
        expect(fields['osversion'], 'Android16_7.9.480_1996');
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {'sessionKey': 'synthetic-sms-session'},
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await QidianAuth(api).sendCode('13800138000');
    expect(requests, 1);
  }, skip: !Platform.isWindows);

  test('并发业务请求只初始化和注册一次，传入当次会话及原始参数', () async {
    final calls = <Map<String, dynamic>>[];
    final waiting = Completer<void>();
    final provider = NativeQidianSecurity(
      directory: () async => '/synthetic',
      dispatch: (input) async {
        calls.add(input);
        return switch (input['op']) {
          'create' => {'ok': true, 'handle': '1'},
          'ensure' => await (() async {
            await waiting.future;
            return {'ok': true, 'ready': true};
          })(),
          'headers' => {'ok': true, 'headers': heads},
          _ => {'ok': true},
        };
      },
    );
    final pending = List.generate(
      8,
      (i) => provider.headers(
        {'BookId': '$i', 'text': 'a +%中'},
        device: 'device',
        session: {'userId': '$i'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c['op'] == 'ensure'), hasLength(1));
    waiting.complete();
    expect(await Future.wait(pending), everyElement(heads));
    expect(calls.where((c) => c['op'] == 'create'), hasLength(1));
    expect(calls.where((c) => c['op'] == 'headers'), hasLength(8));
    expect((calls.last['params'] as Map)['text'], 'a +%中');
    provider.close();
  });

  test('初始化失败后连续业务调用不重复注册，不降级旧请求头', () async {
    var registrations = 0;
    var business = 0;
    final provider = NativeQidianSecurity(
      directory: () async => '/synthetic',
      dispatch: (input) async {
        if (input['op'] == 'create') return {'ok': true, 'handle': '1'};
        if (input['op'] == 'ensure') {
          registrations++;
          return {'ok': true, 'ready': false};
        }
        if (input['op'] == 'headers') business++;
        return {'ok': true};
      },
    );
    for (var i = 0; i < 3; i++) {
      await expectLater(
        provider.headers({}, device: 'device', session: {}),
        throwsA(isA<SourceException>()),
      );
    }
    expect(registrations, 1);
    expect(business, 0);
    provider.close();
  });

  test('原生冷却拒绝请求，保留风控码', () async {
    final provider = NativeQidianSecurity(
      directory: () async => '/synthetic',
      dispatch: (input) async => input['op'] == 'create'
          ? {'ok': true, 'handle': '1'}
          : {'ok': true, 'ready': false, 'serviceCode': -4403},
    );
    await expectLater(
      provider.headers({}, device: 'device', session: {}),
      throwsA(
        isA<SourceAccessRestrictedException>().having(
          (e) => e.code,
          'code',
          -4403,
        ),
      ),
    );
    provider.close();
  });

  test('关闭正在注册的提供器会取消原生句柄，迟到结果不产生业务头', () async {
    final waiting = Completer<void>();
    var closes = 0;
    var signed = 0;
    final provider = NativeQidianSecurity(
      directory: () async => '/synthetic',
      dispatch: (input) async {
        switch (input['op']) {
          case 'create':
            return {'ok': true, 'handle': '1'};
          case 'ensure':
            await waiting.future;
            return {'ok': true, 'ready': true};
          case 'close':
            closes++;
            return {'ok': true};
          default:
            signed++;
            return {'ok': true, 'headers': heads};
        }
      },
    );
    final pending = provider.headers({}, device: 'device', session: {});
    final assertion = expectLater(pending, throwsA(isA<SourceException>()));
    await Future<void>.delayed(Duration.zero);
    provider.close();
    await Future<void>.delayed(Duration.zero);
    expect(closes, 1);
    waiting.complete();
    await assertion;
    expect(signed, 0);
  });

  test('原生头进入实际 HTTP 请求，匿名目录不携带账号，业务风控通知原生', () async {
    final sessions = <Map<String, String>>[];
    var pauses = 0;
    final provider = NativeQidianSecurity(
      directory: () async => '/synthetic',
      dispatch: (input) async {
        if (input['op'] == 'create') return {'ok': true, 'handle': '1'};
        if (input['op'] == 'ensure') return {'ok': true, 'ready': true};
        if (input['op'] == 'pause') pauses++;
        if (input['op'] == 'headers') {
          sessions.add(Map<String, String>.from(input['session'] as Map));
          return {'ok': true, 'headers': heads};
        }
        return {'ok': true};
      },
    );
    var requests = 0;
    final api = QidianApi(
      security: provider,
      client: MockClient((request) async {
        requests++;
        expect(request.headers['ibex'], heads['ibex']);
        expect(request.headers['gorgon'], heads['gorgon']);
        expect(request.followRedirects, isFalse);
        return http.Response(
          jsonEncode({'Result': requests == 2 ? -4403 : 0, 'Data': {}}),
          200,
        );
      }),
    )..credentials = account('12');
    addTearDown(api.close);
    await api.request('/argus/api/v1/book/get', {}, useSession: false);
    expect(sessions.single, isEmpty);
    expect(api.credentials!.userId, '12');
    await expectLater(
      api.request('/argus/api/v3/user/getaccountpage', {}),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(pauses, 1);
    expect(sessions.last['userId'], '12');
    expect(api.credentials!.userId, '12');
    await expectLater(
      api.request('/argus/api/v1/book/get', {}),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(requests, 2);
  });

  test('重启后的原生风控也阻止 SDK 短信请求', () async {
    var requests = 0;
    final provider = NativeQidianSecurity(
      directory: () async => '/synthetic',
      dispatch: (input) async => input['op'] == 'create'
          ? {'ok': true, 'handle': '1'}
          : {'ok': true, 'ready': false, 'serviceCode': -4403},
    );
    final api = QidianApi(
      security: provider,
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(api.close);
    await expectLater(
      QidianAuth(api).sendCode('13800138000'),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    await expectLater(
      api.request('/argus/api/v1/book/get', {}),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(requests, 0);
  });

  test('等待原生签名期间切换账号，旧账号请求不会发出', () async {
    final waiting = Completer<void>();
    var requests = 0;
    final provider = NativeQidianSecurity(
      directory: () async => '/synthetic',
      dispatch: (input) async {
        if (input['op'] == 'create') return {'ok': true, 'handle': '1'};
        if (input['op'] == 'ensure') {
          await waiting.future;
          return {'ok': true, 'ready': true};
        }
        return {'ok': true, 'headers': heads};
      },
    );
    final api = QidianApi(
      security: provider,
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    )..credentials = account('12');
    addTearDown(api.close);
    final pending = api.request('/argus/api/v3/user/getaccountpage', {});
    final assertion = expectLater(pending, throwsA(isA<SourceException>()));
    await Future<void>.delayed(Duration.zero);
    api.credentials = account('13');
    waiting.complete();
    await assertion;
    expect(requests, 0);
    expect(api.credentials!.userId, '13');
  });
}
