import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_verification.dart';
import 'package:unr/sources/source_verification.dart';

http.Response response(Object? data, {int status = 200, String? message}) =>
    http.Response(
      jsonEncode({
        'status': {'httpCode': status, 'msg': ?message},
        'data': data,
      }),
      status,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'set-cookie': 'session_APP=candidate; Path=/',
      },
    );

class Server {
  int ban = 9, afterCaptcha = 0, afterSms = 0, accountId = 42;
  Object? phone = '13900000000', country = 86;
  final requests = <http.Request>[];
  Future<http.Response?> Function(http.Request)? intercept;
  late final api = SfacgApi(
    client: MockClient((request) async {
      requests.add(request);
      expect(request.url.host, 'api.sfacg.com');
      expect(request.headers['sfsecurity'], contains('devicetoken='));
      expect(request.headers['authorization'], startsWith('Basic '));
      final override = await intercept?.call(request);
      if (override != null) return override;
      if (request.url.path == '/user/captcha/aid') return response('aid');
      if (request.url.path.startsWith('/sms/')) {
        expect(request.url.path, '/sms/13900000000/86');
        expect(request.url.queryParameters, {'type': 'check'});
        if (request.method == 'POST') {
          expect(jsonDecode(request.body), {
            'ticket': 'ticket',
            'randstr': 'random',
          });
        } else {
          expect(request.method, 'PUT');
          expect(jsonDecode(request.body), {'smsAuthCode': '001234'});
          ban = afterSms;
        }
        return response('ok');
      }
      expect(request.method, 'GET');
      expect(request.url.path, '/user');
      expect(request.url.queryParameters['expand'], 'accountException');
      if (request.url.queryParameters.containsKey('captcha_ticket')) {
        ban = afterCaptcha;
      }
      return response({
        'accountId': accountId,
        'phoneNum': phone,
        'countryCode': country,
        'expand': {
          'accountException': {'banStatus': ban},
        },
      });
    }),
  )..setCookie('.SFCommunity=original; session_APP=original-app');

  int count(String method) => requests.where((r) => r.method == method).length;
}

Future<T?> captcha<T>(SourceVerificationChallenge<T> challenge) async =>
    challenge.parseResult({'ret': 0, 'ticket': 'ticket', 'randstr': 'random'});

Future<T?> complete<T>(SourceVerificationChallenge<T> challenge) async {
  if (challenge is! SfacgSmsVerificationChallenge) return captcha(challenge);
  final sms = challenge as SfacgSmsVerificationChallenge;
  expect(sms.maskedDestination, '+86 ****0000');
  expect(sms.canSubmit, isFalse);
  await sms.sendCode(captcha);
  await sms.submitCode('001234');
  return sms.parseResult(true) as T?;
}

void main() {
  late Server server;
  setUp(() => server = Server());
  tearDown(() => server.api.close());

  test('短信风控使用官方 App 签名、绑定号码和 check 类型，确认解除后才保存', () async {
    var saves = 0;
    server.api.onSessionChanged = () async => saves++;
    server.intercept = (_) async {
      expect(server.api.cookies['session_APP'], 'original-app');
      expect(saves, 0);
      return null;
    };
    expect(
      await server.api.verifyAccess(complete),
      SourceVerificationOutcome.verified,
    );
    expect(server.requests.map((r) => '${r.method} ${r.url.path}'), [
      'GET /user',
      'GET /user/captcha/aid',
      'POST /sms/13900000000/86',
      'PUT /sms/13900000000/86',
      'GET /user',
    ]);
    expect(saves, 1);
    expect(server.api.cookies['session_APP'], 'candidate');
  });

  for (final initial in [6, 9]) {
    test('人机和短信限制按服务器结果衔接：初始 $initial', () async {
      server
        ..ban = initial
        ..afterCaptcha = initial == 6 ? 9 : 0
        ..afterSms = initial == 9 ? 6 : 0;
      expect(
        await server.api.verifyAccess(complete),
        SourceVerificationOutcome.verified,
      );
      expect(server.count('POST'), 1);
      expect(server.count('PUT'), 1);
      expect(
        server.requests.where((r) => r.url.path.endsWith('/aid')).length,
        2,
      );
    });
  }

  test('取消短信或人机验证不发短信、不提交或保存，取消人机后可重试', () async {
    server.api.onSessionChanged = () async => fail('取消不能保存');
    expect(
      await server.api.verifyAccess(<T>(_) async => null),
      SourceVerificationOutcome.cancelled,
    );
    await server.api.verifyAccess(<T>(challenge) async {
      final sms = challenge as SfacgSmsVerificationChallenge;
      expect(await sms.sendCode(<R>(_) async => null), isFalse);
      expect(sms.resendAt, isNull);
      expect(await sms.sendCode(<R>(_) async => null), isFalse);
      expect(sms.canSubmit, isFalse);
      return null;
    });
    expect(server.count('POST'), 0);
    expect(server.count('PUT'), 0);
    expect(server.api.cookies['session_APP'], 'original-app');
  });

  test('错码留在当前步骤，可手动重试；验证码和票据不进入错误提示', () async {
    var attempts = 0;
    server.intercept = (request) async {
      if (request.method == 'PUT' && ++attempts == 1) {
        return response(null, status: 503, message: '001234 验证码错误');
      }
      return null;
    };
    await server.api.verifyAccess(<T>(challenge) async {
      final sms = challenge as SfacgSmsVerificationChallenge;
      await sms.sendCode(captcha);
      await expectLater(
        sms.submitCode('001234'),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            '隐藏验证码',
            isNot(contains('001234')),
          ),
        ),
      );
      expect(attempts, 1);
      expect(sms.completed, isFalse);
      expect(sms.canSubmit, isTrue);
      await sms.submitCode('001234');
      return sms.parseResult(true) as T?;
    });
    expect(attempts, 2);
    expect(server.count('POST'), 1);
  });

  test('发码超时不重发，退出重进仍保留倒计时并可提交已收到的验证码', () async {
    server.intercept = (request) async {
      if (request.method == 'POST') throw TimeoutException('uncertain');
      return null;
    };
    await server.api.verifyAccess(<T>(challenge) async {
      final sms = challenge as SfacgSmsVerificationChallenge;
      await expectLater(
        sms.sendCode(captcha),
        throwsA(isA<TimeoutException>()),
      );
      expect(sms.canSubmit, isTrue);
      await expectLater(sms.sendCode(captcha), throwsA(isA<SourceException>()));
      return null;
    });
    expect(server.count('POST'), 1);
    expect(server.api.cookies['session_APP'], 'original-app');
    expect(
      await server.api.verifyAccess(<T>(challenge) async {
        final sms = challenge as SfacgSmsVerificationChallenge;
        expect(sms.resendAt!.isAfter(DateTime.now()), isTrue);
        await expectLater(
          sms.sendCode(captcha),
          throwsA(isA<SourceException>()),
        );
        await sms.submitCode('001234');
        return sms.parseResult(true) as T?;
      }),
      SourceVerificationOutcome.verified,
    );
    expect(server.count('POST'), 1);
  });

  test('提交结果不确定不自动重试，也不保存临时会话', () async {
    server.intercept = (request) async {
      if (request.method == 'PUT') throw TimeoutException('uncertain');
      return null;
    };
    await expectLater(
      server.api.verifyAccess(complete),
      throwsA(isA<TimeoutException>()),
    );
    expect(server.count('PUT'), 1);
    expect(server.api.cookies['session_APP'], 'original-app');
  });

  for (final changedAccount in [false, true]) {
    test('服务端${changedAccount ? '切换账号' : '未解除限制'}不能确认成功', () async {
      if (changedAccount) {
        server.intercept = (request) async {
          if (request.method == 'PUT') server.accountId = 99;
          return null;
        };
      } else {
        server.afterSms = 9;
      }
      await expectLater(
        server.api.verifyAccess(complete),
        throwsA(isA<SourceException>()),
      );
      expect(server.api.cookies['session_APP'], 'original-app');
    });
  }

  for (final invalid in [null, '', '139****0000', '../user']) {
    test('未绑定或无完整手机号时不能向任意号码发送：$invalid', () async {
      server.phone = invalid;
      await expectLater(
        server.api.verifyAccess(complete),
        throwsA(isA<SourceException>()),
      );
      expect(server.requests.length, 1);
    });
  }

  test('未经提交不能伪造成功，过期步骤不能继续调用', () async {
    late SfacgSmsVerificationChallenge sms;
    await expectLater(
      server.api.verifyAccess(<T>(challenge) async {
        sms = challenge as SfacgSmsVerificationChallenge;
        await expectLater(
          sms.submitCode('001234'),
          throwsA(isA<SourceException>()),
        );
        return true as T;
      }),
      throwsA(isA<SourceException>()),
    );
    await expectLater(sms.sendCode(captcha), throwsA(isA<SourceException>()));
    expect(server.count('POST'), 0);
    expect(server.count('PUT'), 0);
  });

  for (final stage in ['captcha', 'POST', 'PUT']) {
    test('在 $stage 期间切换会话，丢弃旧步骤且不覆盖新登录', () async {
      server.intercept = (request) async {
        if (request.method == stage ||
            stage == 'captcha' && request.url.path.endsWith('/aid')) {
          server.api.setCookie('.SFCommunity=new; session_APP=new-app');
        }
        return null;
      };
      await expectLater(
        server.api.verifyAccess(complete),
        throwsA(isA<SourceException>()),
      );
      expect(server.api.cookies['session_APP'], 'new-app');
      expect(server.count('POST'), stage == 'captcha' ? 0 : 1);
      expect(server.count('PUT'), stage == 'PUT' ? 1 : 0);
    });
  }

  test('重复发码共用一个进行中的步骤，页面取消后迟到的人机结果不发短信', () async {
    final release = Completer<void>();
    late Future<bool> pending;
    await server.api.verifyAccess(<T>(challenge) async {
      final sms = challenge as SfacgSmsVerificationChallenge;
      pending = sms.sendCode(<R>(challenge) async {
        await release.future;
        return captcha(challenge);
      });
      await expectLater(sms.sendCode(captcha), throwsA(isA<SourceException>()));
      return null;
    });
    final expected = expectLater(pending, throwsA(isA<SourceException>()));
    release.complete();
    await expected;
    expect(server.count('POST'), 0);
  });
}
