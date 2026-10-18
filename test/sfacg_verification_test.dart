import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_verification.dart';
import 'package:unr/sources/source_verification.dart';

http.Response response(Object? data, {int code = 200, String? cookie}) =>
    http.Response(
      jsonEncode({
        'status': {'httpCode': code},
        'data': data,
      }),
      code,
      headers: {'set-cookie': ?cookie},
    );

Map<String, Object?> user({Object? ban = 6, int id = 42}) => {
  'accountId': id,
  'expand': {
    'accountException': ban == null ? null : {'banStatus': ban},
  },
};

SfacgApi apiWith(Future<http.Response> Function(http.Request) handler) =>
    SfacgApi(
      client: MockClient((request) {
        expect(request.url.host, 'api.sfacg.com');
        expect(request.method, 'GET');
        expect(request.headers['sfsecurity'], contains('devicetoken='));
        return handler(request);
      }),
    )..setCookie('.SFCommunity=original; session_APP=original-app');

Future<T?> solve<T>(SourceVerificationChallenge<T> challenge) async =>
    challenge.parseResult({'ret': 0, 'ticket': 'ticket', 'randstr': 'random'});

void main() {
  for (final code in [401, 429, 503]) {
    test('App 明确提示风控时保留可验证错误，不盲目重试（$code）', () async {
      var attempts = 0;
      final api = apiWith((_) async {
        attempts++;
        return http.Response(
          jsonEncode({
            'status': {
              'httpCode': code,
              'errorCode': 123,
              'msg': '触发风控，请完成安全验证',
            },
          }),
          code,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      addTearDown(api.close);
      await expectLater(
        api.get('Chaps/1'),
        throwsA(
          isA<SourceVerificationRequiredException>()
              .having((e) => e.code, '原状态码', code)
              .having((e) => e.errorCode, '原错误码', 123),
        ),
      );
      expect(attempts, 1);
      if (code == 401) {
        await expectLater(
          api.checkSession(),
          throwsA(isA<SourceVerificationRequiredException>()),
        );
      }
      expect(api.hasSession, isTrue);
    });
  }

  test('官方 App 验证配置、SDK 及回传字段对应，服务器确认后才保存会话', () async {
    final paths = <String>[];
    var saves = 0;
    late SfacgApi api;
    api = apiWith((request) async {
      paths.add(request.url.path);
      expect(api.cookies['session_APP'], 'original-app');
      if (request.url.path == '/user/captcha/aid') {
        return response('encrypted-aid');
      }
      expect(request.url.queryParameters['expand'], 'accountException');
      if (!request.url.queryParameters.containsKey('captcha_ticket')) {
        return response(user());
      }
      expect(request.url.queryParameters['captcha_ticket'], 'ticket');
      expect(request.url.queryParameters['captcha_randstr'], 'random');
      expect(saves, 0);
      return response(user(ban: null), cookie: 'session_APP=rotated; Path=/');
    });
    addTearDown(api.close);
    api.onSessionChanged = () async {
      saves++;
    };
    final outcome = await api.verifyAccess(<T>(challenge) async {
      expect(challenge, isA<SfacgVerificationChallenge>());
      final document = challenge.createDocument('nonce');
      expect(
        document.html,
        contains('https://turing.captcha.qcloud.com/TJCaptcha.js'),
      );
      expect(document.html, contains("'190225369'"));
      expect(document.html, contains('aidEncrypted: aid'));
      expect(document.html, isNot(contains('original-app')));
      expect(document.html, isNot(contains('console.log')));
      return solve(challenge);
    });
    expect(outcome, SourceVerificationOutcome.verified);
    expect(paths, ['/user', '/user/captcha/aid', '/user']);
    expect(saves, 1);
    expect(api.cookies['session_APP'], 'rotated');
  });

  for (final ban in [0, null, 7, 8, 9, 10, 'invalid']) {
    test('状态 $ban 仅人机验证限制允许打开验证页', () async {
      var requests = 0;
      final api = apiWith((_) async {
        requests++;
        return response(user(ban: ban));
      });
      addTearDown(api.close);
      Future<T?> unexpected<T>(SourceVerificationChallenge<T> _) async {
        fail('不应打开验证页');
      }

      if (ban == null || ban == 0) {
        expect(
          await api.verifyAccess(unexpected),
          SourceVerificationOutcome.notRequired,
        );
      } else {
        await expectLater(
          api.verifyAccess(unexpected),
          throwsA(isA<SourceException>()),
        );
      }
      expect(requests, 1);
      expect(api.cookies['session_APP'], 'original-app');
    });
  }

  test('取消验证不提交票据、不保存配置阶段轮换的会话，可重新发起', () async {
    var requests = 0;
    final api = apiWith((request) async {
      requests++;
      return response(
        request.url.path == '/user' ? user() : 'aid',
        cookie: 'session_APP=candidate; Path=/',
      );
    });
    addTearDown(api.close);
    api.onSessionChanged = () async => fail('取消不应保存');
    for (var i = 0; i < 2; i++) {
      expect(
        await api.verifyAccess(<T>(_) async => null),
        SourceVerificationOutcome.cancelled,
      );
    }
    expect(requests, 4);
    expect(api.cookies['session_APP'], 'original-app');
  });

  test('重复触发共用一次验证，不能同时打开多个页面', () async {
    final completion = Completer<void>();
    var prompts = 0, requests = 0;
    final api = apiWith((request) async {
      requests++;
      if (request.url.path.endsWith('/aid')) return response('aid');
      return response(
        user(
          ban: request.url.queryParameters.containsKey('captcha_ticket')
              ? 0
              : 6,
        ),
      );
    });
    addTearDown(api.close);
    Future<T?> delayed<T>(SourceVerificationChallenge<T> challenge) async {
      prompts++;
      await completion.future;
      return solve(challenge);
    }

    final first = api.verifyAccess(delayed);
    final second = api.verifyAccess(delayed);
    expect(identical(first, second), isTrue);
    completion.complete();
    expect(await first, SourceVerificationOutcome.verified);
    expect(await second, SourceVerificationOutcome.verified);
    expect(prompts, 1);
    expect(requests, 3);
  });

  for (final changeDuringSubmit in [false, true]) {
    test('验证${changeDuringSubmit ? '提交' : '回调'}期间变更登录，不覆盖新会话', () async {
      var submissions = 0;
      late SfacgApi api;
      api = apiWith((request) async {
        if (request.url.path.endsWith('/aid')) return response('aid');
        if (request.url.queryParameters.containsKey('captcha_ticket')) {
          submissions++;
          api.setCookie('.SFCommunity=new; session_APP=new-app');
          return response(user(ban: 0), cookie: 'session_APP=stale; Path=/');
        }
        return response(user());
      });
      addTearDown(api.close);
      api.onSessionChanged = () async => fail('过期结果不应保存');
      await expectLater(
        api.verifyAccess(<T>(challenge) async {
          if (!changeDuringSubmit) {
            api.setCookie('.SFCommunity=new; session_APP=new-app');
          }
          return solve(challenge);
        }),
        throwsA(isA<SourceException>()),
      );
      expect(api.cookies['session_APP'], 'new-app');
      expect(submissions, changeDuringSubmit ? 1 : 0);
    });
  }

  for (final verified in [
    user(),
    user(ban: 7),
    user(ban: 0, id: 99),
    {'accountId': 42},
  ]) {
    test('服务器未确认原账号解除限制时保留旧会话：$verified', () async {
      final api = apiWith((request) async {
        if (request.url.path.endsWith('/aid')) return response('aid');
        return response(
          request.url.queryParameters.containsKey('captcha_ticket')
              ? verified
              : user(),
          cookie: 'session_APP=candidate; Path=/',
        );
      });
      addTearDown(api.close);
      api.onSessionChanged = () async => fail('未经确认不应保存');
      await expectLater(
        api.verifyAccess(solve),
        throwsA(isA<SourceException>()),
      );
      expect(api.cookies['session_APP'], 'original-app');
    });
  }

  test('票据提交结果不确定不自动重试，错误消息隐藏票据', () async {
    var submissions = 0;
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/aid')) return response('aid');
      if (!request.url.queryParameters.containsKey('captcha_ticket')) {
        return response(user());
      }
      submissions++;
      return http.Response(
        jsonEncode({
          'status': {'httpCode': 503, 'msg': 'ticket random'},
        }),
        503,
      );
    });
    addTearDown(api.close);
    await expectLater(
      api.verifyAccess(solve),
      throwsA(
        isA<SourceException>()
            .having((e) => e.message, '票据已隐藏', isNot(contains('ticket')))
            .having((e) => e.message, '随机串已隐藏', isNot(contains('random'))),
      ),
    );
    expect(submissions, 1);
    expect(api.cookies['session_APP'], 'original-app');
  });

  test('未登录和旧网页会话不能发起 App 验证', () async {
    final api = SfacgApi(client: MockClient((_) async => fail('不应请求')));
    addTearDown(api.close);
    await expectLater(api.verifyAccess(solve), throwsA(isA<SourceException>()));
    api.setCookie('.SFCommunity=website', website: true);
    await expectLater(api.verifyAccess(solve), throwsA(isA<SourceException>()));
    expect(api.cookies['.SFCommunity'], 'website');
  });

  test('验证配置不能注入脚本，非法和未成功票据被拒绝', () {
    final challenge = SfacgVerificationChallenge(
      aid: '</script>"',
      expiresAt: DateTime.now(),
    );
    expect(
      challenge.createDocument('nonce').html,
      contains(r'\u003c/script>\"'),
    );
    expect(challenge.parseResult({'ret': 2}), isNull);
    for (final invalid in [
      null,
      {},
      {'ret': 0, 'ticket': '', 'randstr': 'random'},
      {'ret': 0, 'ticket': 'ticket\n', 'randstr': 'random'},
      {'ret': -1},
    ]) {
      expect(
        () => challenge.parseResult(invalid),
        throwsA(isA<SourceException>()),
      );
    }
  });
}
