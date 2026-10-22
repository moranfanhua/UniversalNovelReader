import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/app_log.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_auth.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/fanqie/fanqie_app_api.dart';
import 'package:unr/sources/fanqie/fanqie_auth.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_auth.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';

http.Response jsonResponse(Object? data, {int status = 200}) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> expectDescription(
  String event,
  String description,
  List<String> secrets,
) async {
  final snapshot = await AppLog.instance.snapshot();
  final entry = const LineSplitter()
      .convert(snapshot.text)
      .where((line) => line.startsWith('{'))
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .lastWhere((entry) => entry['event'] == event);
  expect(entry['serverMessage'], contains(description));
  expect(entry['httpStatus'], isA<int>());
  for (final secret in secrets) {
    expect(snapshot.text, isNot(contains(secret)));
  }
}

Matcher failureWithDescription(String description, {int? code}) => throwsA(
  isA<SourceException>()
      .having((e) => e.message, '服务端说明', contains(description))
      .having((e) => code == null || e.code == code, '保留业务码', isTrue),
);

void main() {
  setUp(() => AppLog.instance.clear());

  test('菠萝包正文 507 保留固定处理建议及服务端原说明，日志隐藏会话', () async {
    var calls = 0;
    final api = SfacgApi(
      client: MockClient((_) async {
        calls++;
        return jsonResponse({
          'status': {
            'httpCode': 401,
            'errorCode': 507,
            'msg': '没有访问接口的权限；private-session',
          },
        }, status: 401);
      }),
    )..setCookie('.SFCommunity=private-account; session_APP=private-session');
    addTearDown(api.close);
    await expectLater(
      api.get('Chaps/123'),
      throwsA(
        isA<SourceException>()
            .having((e) => e.message, '处理建议', contains('App 请求配置'))
            .having((e) => e.message, '服务端说明', contains('没有访问接口的权限'))
            .having((e) => e.errorCode, '保留错误码', 507),
      ),
    );
    await expectDescription('sfacg.request_rejected', '没有访问接口的权限', [
      'private-session',
      'private-account',
    ]);
    expect(calls, 1);
    expect(api.hasSession, isTrue);
  });

  test('番茄业务拒绝保留 message，移除请求内容、Cookie 和设备标识，不重发', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return jsonResponse({
        'code': 1001,
        'message': '当前作品暂不可读；private-session；私密评论；12345678',
      });
    });
    addTearDown(client.close);
    final api =
        FanqieAppApi(client: client, cookie: () => 'sessionid=private-session')
          ..deviceId = '12345678'
          ..installId = '87654321';
    await expectLater(
      api.request('/reader/test', body: {'content': '私密评论'}),
      failureWithDescription('当前作品暂不可读', code: 1001),
    );
    await expectDescription('fanqie.request_rejected', '当前作品暂不可读', [
      'private-session',
      '私密评论',
      '12345678',
    ]);
    expect(calls, 1);
  });

  test('番茄认证采用嵌套 description，隐藏手机号和验证码且不覆盖会话', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return jsonResponse({
        'message': 'error',
        'data': {'error_code': 7, 'description': '请求频率过高；13800138000；123456'},
      });
    });
    addTearDown(client.close);
    final api =
        FanqieAppApi(client: client, cookie: () => 'sessionid=private-session')
          ..deviceId = '12345678'
          ..installId = '87654321';
    final auth = FanqieAuth(client, api);
    await expectLater(
      auth.sendCode('13800138000'),
      failureWithDescription('请求频率过高', code: 7),
    );
    await expectDescription('fanqie.auth_rejected', '请求频率过高', [
      '13800138000',
      '123456',
    ]);
    expect(calls, 1);
    expect(api.cookie(), 'sessionid=private-session');
  });

  test('刺猬猫 tip 保留详细原因，账密加密前原文不会被回显进日志', () async {
    var calls = 0;
    final api =
        CiweimaoApi(
          client: MockClient((request) async {
            calls++;
            final doc = request.url.path == '/signup/use_geetest'
                ? {
                    'code': '100000',
                    'data': {'need_use_geetest': '0'},
                  }
                : {
                    'code': '320002',
                    'tip': '设备校验未通过；私人密码；私密账号；private-session-token',
                  };
            return http.Response(CiweimaoCrypto.encrypt(jsonEncode(doc)), 200);
          }),
        )..restoreSession(
          CiweimaoCredentials(
            account: '私密账号',
            token: 'private-session-token',
            readerId: '106',
          ),
        );
    addTearDown(api.close);
    final original = api.credentials;
    await expectLater(
      CiweimaoAuth(api).passwordLogin('私密账号', '私人密码'),
      failureWithDescription('设备校验未通过', code: 320002),
    );
    await expectDescription('ciweimao.auth_rejected', '设备校验未通过', [
      '私人密码',
      '私密账号',
      'private-session-token',
    ]);
    expect(calls, 2);
    expect(api.credentials, same(original));
  });

  test('起点业务拒绝保留 Message 和业务码，GET 响应不会误判为解析失败', () async {
    var calls = 0;
    final api =
        QidianApi(
            client: MockClient((_) async {
              calls++;
              return jsonResponse({
                'Result': 403,
                'Message': '未获得此章节的阅读权限；private-token',
              });
            }),
          )
          ..credentials = QidianCredentials(
            userId: '10',
            ywGuid: '20',
            ywKey: 'private-key',
            token: 'private-token',
          );
    addTearDown(api.close);
    final original = api.credentials;
    await expectLater(
      api.request('/argus/api/v1/test', {}),
      failureWithDescription('未获得此章节的阅读权限', code: 403),
    );
    await expectDescription('qidian.request_rejected', '未获得此章节的阅读权限', [
      'private-token',
    ]);
    expect(calls, 1);
    expect(api.credentials, same(original));
  });

  test('起点认证保留 msg，移除 RSA 加密前密码与账号，不重发', () async {
    var calls = 0;
    final api = QidianApi(
      client: MockClient((_) async {
        calls++;
        return jsonResponse({'code': -1, 'msg': '当前账号暂不可登录；私人密码；私密账号'});
      }),
    );
    addTearDown(api.close);
    await expectLater(
      QidianAuth(api).loginPassword('私密账号', '私人密码'),
      failureWithDescription('当前账号暂不可登录', code: -1),
    );
    await expectDescription('qidian.auth_rejected', '当前账号暂不可登录', [
      '私人密码',
      '私密账号',
    ]);
    expect(calls, 1);
  });
}
