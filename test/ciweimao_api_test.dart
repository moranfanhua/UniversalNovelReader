import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';

CiweimaoCredentials session({String id = '106', bool guest = false}) =>
    CiweimaoCredentials(
      account: 'synthetic+account',
      token: 'synthetic-token-1234',
      readerId: id,
      guest: guest,
    );
http.Response ok(Object? data, {String code = '100000'}) => http.Response(
  CiweimaoCrypto.encrypt(jsonEncode({'code': code, 'data': data})),
  200,
);

void main() {
  test('请求在等待会话的微任务间隙切换账号时，不使用旧凭据发送请求', () async {
    var calls = 0;
    final api = CiweimaoApi(
      client: MockClient((_) async {
        calls++;
        return ok({});
      }),
    )..restoreSession(session());
    addTearDown(api.close);
    final pending = api.request('reader/get_my_info', {});
    api.restoreSession(session(id: '107'));
    await expectLater(pending, throwsA(isA<SourceException>()));
    expect(calls, 0);
  });
  test('当前 APK 签名与独立 Python HMAC 向量一致，值仅编码一次', () {
    final body = CiweimaoCrypto.form({
      'account': 'synthetic+account',
      'app_version': '2.9.367',
      'key': '合成 😀&=+%',
      'empty': '',
    }, nonce: '1234abcdef012345');
    final fields = Uri.splitQueryString(body);
    expect(fields['p'], '9CYUK94yKMa5MSs1RMEKQDCs7zMx5lOT2zc7mqJ80N0=');
    expect(fields['account'], 'synthetic+account');
    expect(fields['key'], '合成 😀&=+%');
    expect(body.indexOf('account='), lessThan(body.indexOf('empty=')));
    expect(body, endsWith('rand_str=1234abcdef012345&'));
  });
  test('当前 APK AES 响应与独立向量一致，拒绝损坏密文', () {
    expect(
      CiweimaoCrypto.decrypt(
        '5DGa7wDsQ75CERueOQ4+MgCHgOEb7JAISsvOCA2CI9+bfrpGSLHn59emxbcQTzdU',
      ),
      '{"code":"100000","data":{"value":"合成😀"}}',
    );
    for (final text in ['', '{}', 'bm90LWFlcw==']) {
      expect(
        () => CiweimaoCrypto.decrypt(text),
        throwsA(isA<SourceException>()),
      );
    }
  });
  test('并发公开请求仅建立一次游客会话，并按 App 用户分流且禁止跳转', () async {
    var registrations = 0, reads = 0;
    final api = CiweimaoApi(
      client: MockClient((r) async {
        expect(r.method, 'POST');
        expect(r.followRedirects, isFalse);
        expect(r.headers['cookie'], isNull);
        expect(r.headers['user-agent'], contains('novel.c  2.9.367'));
        expect(r.bodyFields['device_token'], 'ciweimao_');
        if (r.url.path == '/signup/auto_reg_v2') {
          registrations++;
          expect(r.bodyFields['account'], isNull);
          return ok({
            'login_token': 'synthetic-token-1234',
            'reader_info': {'account': 'synthetic+account', 'reader_id': '101'},
          });
        }
        reads++;
        expect(r.url.host, 'app1.happybooker.cn');
        expect(r.bodyFields['account'], 'synthetic+account');
        return ok({'value': 1});
      }),
    );
    addTearDown(api.close);
    final result = await Future.wait(
      List.generate(
        3,
        (_) => api.request('book/get_info_by_id', {'book_id': '12'}),
      ),
    );
    expect(result.map((r) => r['value']), [1, 1, 1]);
    expect(registrations, 1);
    expect(reads, 3);
    expect(api.hasSession, isFalse);
    expect(api.credentials!.guest, isTrue);
  });
  test('账号切换使旧响应失效，失败不清除现有会话', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    final api = CiweimaoApi(
      client: MockClient((_) {
        started.complete();
        return response.future;
      }),
    );
    addTearDown(api.close);
    final original = session();
    api.restoreSession(original);
    final pending = api.request('reader/get_my_info', {});
    final checked = expectLater(
      pending,
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          'message',
          contains('已切换'),
        ),
      ),
    );
    await started.future;
    await api.saveSession(session(id: '102'));
    response.complete(ok({'reader_info': {}}));
    await checked;
    expect(api.credentials!.readerId, '102');
  });
  test('写入超时、服务异常与损坏响应不重发，并明确结果未确认', () async {
    for (final kind in ['timeout', 'server', 'malformed']) {
      var calls = 0;
      final api = CiweimaoApi(
        client: MockClient((_) async {
          calls++;
          if (kind == 'timeout') throw TimeoutException('synthetic');
          return http.Response('broken', kind == 'server' ? 503 : 200);
        }),
      );
      api.restoreSession(session());
      addTearDown(api.close);
      await expectLater(
        api.request('chapter/add_tsukkomi', {}, write: true),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'message',
            contains('结果未确认'),
          ),
        ),
      );
      expect(calls, 1);
      expect(api.hasSession, isTrue);
    }
  });
  test('业务失败保留平台错误码，非法地址与保留参数不联网', () async {
    var calls = 0;
    final api = CiweimaoApi(
      client: MockClient((_) async {
        calls++;
        return ok({}, code: '200100');
      }),
    )..restoreSession(session());
    addTearDown(api.close);
    await expectLater(
      api.request('reader/get_my_info', {}),
      throwsA(isA<SourceException>().having((e) => e.code, 'code', 200100)),
    );
    for (final path in [
      'https://example.com',
      '../signup/login',
      'book/get_info_by_id?x=1',
    ]) {
      await expectLater(api.request(path, {}), throwsA(isA<SourceException>()));
    }
    await expectLater(
      api.request('book/get_info_by_id', {'account': 'other'}),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 1);
    expect(api.hasSession, isTrue);
  });
}
