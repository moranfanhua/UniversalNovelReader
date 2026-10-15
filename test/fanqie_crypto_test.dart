import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_crypto.dart';

void main() {
  // Independent golden vectors from ch6vip/fqapp's pinned Go oracle.
  test('签名与注册请求逐字节匹配公开固定向量', () {
    expect(
      FanqieCrypto.ladon(1700000000, 1967, [1, 2, 3, 4]),
      'AQIDBKM7Y7bWnOIUXmTybD6/MpGbuge4sBwUJsyHVivhtMsH',
    );
    expect(
      FanqieCrypto.simonBlock(
        [
          BigInt.parse('1234567890123456789'),
          BigInt.parse('9876543210987654321'),
        ],
        [
          for (final n in [
            '1111111111111111111',
            '2222222222222222222',
            '3333333333333333333',
            '4444444444444444444',
          ])
            BigInt.parse(n),
        ],
      ),
      [
        BigInt.parse('6071150433487837324'),
        BigInt.parse('2027321285990159935'),
      ],
    );
    expect(
      FanqieCrypto.argus(
        'aid=1967&device_id=dev_aaaaaaaa&iid=111',
        1700000000,
        659662259,
      ),
      '8oHyrVYEy1xDCDlx64ko40qC6JC9VYY/ZkjJzEl50iSFDw8Yfph1hupLxfKrA9GswSEz0Yi4goA7OQ4u+H8ECdOaQDL4GduQ3LULSq9Q4iSEGbS3L6G24GXChtnmPr6n46M2PLlKpXvF7uE0lhH4yD+X69FpdM41gQwx5Y5U3NdwXFaxlqYFszyp7dlUE6BEBWqwDsiAH8Jk9TGKr/jfHt4fVmMc9zRyNRdGeV0x6aP//x7aV+8Po8a/9KK3UNG5KEpmIgzRT6NUttkBP9gRNUh3',
    );
    expect(
      FanqieCrypto.registerRequest(
        '7276663560427471412',
        iv: utf8.encode('0123456789abcdef'),
      ),
      'MDEyMzQ1Njc4OWFiY2RlZvVb0lAf40euDsfvj1ILUK9jAhLCs8plve4qa3UqkHsj',
    );
    expect(
      utf8.decode(
        FanqieCrypto.decryptBlob(
          'ABEiM0RVZneImaq7zN3u//NnA1PPLklvy0VWJ2Qnd45A/zarUCjsToTdr+Zm34ab',
          FanqieCrypto.hex('ac25c67ddd8f38c1b37a2348828e222e'),
        ),
      ),
      'SECRETKEY_16byte',
    );
  });

  test('设备注册加密匹配固定向量，拒绝损坏密文及非法填充', () {
    final out = FanqieCrypto.ttEncrypt(
      utf8.encode('hello-tt-encrypt-payload'),
      random: List.generate(32, (i) => i),
    );
    expect(
      out.map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
      '746305100000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f9c2938fa4a012faf0ecd9d31020e00f9748841c73838f76c10a9f9084bcfc717bc3cb6085a81a491f6e9b3d47a574b96bd818707ca911fc89bfad9a68edc174aa2f2dbc4ea60415c1e06b7525320a6451dbebd0a552028b5e70653d538c39842',
    );
    for (final bad in [
      'bad',
      base64Encode(List.filled(16, 0)),
      base64Encode(List.filled(33, 0)),
    ]) {
      expect(
        () => FanqieCrypto.decryptBlob(bad, List.filled(16, 0)),
        throwsA(isA<SourceException>()),
      );
    }
  });

  test('签名覆盖实际发送的查询和 POST 字节，改变正文会改变摘要', () {
    final uri = Uri.parse(
      'https://reading.snssdk.com/test?aid=1967&q=%E4%B8%AD%E6%96%87',
    );
    final a = FanqieCrypto.sign(
      uri,
      body: utf8.encode('{"text":"你好"}'),
      timestamp: 1700000000,
      nonce: 123,
      random: [1, 2, 3, 4],
    );
    final b = FanqieCrypto.sign(
      uri,
      body: utf8.encode('{"text":"再见"}'),
      timestamp: 1700000000,
      nonce: 123,
      random: [1, 2, 3, 4],
    );
    expect(
      a['x-ss-stub'],
      md5.convert(utf8.encode('{"text":"你好"}')).toString(),
    );
    expect(a['x-argus'], isNot(b['x-argus']));
    expect(a['x-khronos'], '1700000000');
  });

  test('阅读密钥过期仅重新注册一次，解密 gzip 正文并持久化新密钥', () async {
    final key = List.filled(16, 9), iv = List.filled(16, 3);
    final master = FanqieCrypto.hex('ac25c67ddd8f38c1b37a2348828e222e');
    var fullCalls = 0, keyCalls = 0, saves = 0;
    const bid = '7143038691944959011', cid = '7173216089122439711';
    final api = FanqieApi(
      client: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(request.headers['x-argus'], isNotEmpty);
        if (request.url.path == '/reading/crypt/registerkey') {
          keyCalls++;
          expect(
            request.headers['x-ss-stub'],
            md5.convert(request.bodyBytes).toString(),
          );
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'key': base64Encode([
                  ...iv,
                  ...FanqieCrypto.aes(key, master, iv),
                ]),
                'keyver': 1,
              },
            }),
            200,
          );
        }
        fullCalls++;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'novel_data': {
                'book_id': bid,
                'item_id': cid,
                'version': 'test-version',
              },
              'crypt_status': fullCalls == 1 ? 2 : 0,
              'compress_status': 1,
              'paragraphs_num': 1,
              'content': base64Encode([
                ...iv,
                ...FanqieCrypto.aes(
                  gzip.encode(utf8.encode('<p idx="0">完整正文</p>')),
                  key,
                  iv,
                ),
              ]),
            },
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    api.app.restore({
      'deviceId': '123456789',
      'installId': '987654321',
      'key': base64Encode(List.filled(16, 7)),
      'keyOwner': sha256.convert([]).toString(),
    });
    api.onSessionChanged = () async {
      saves++;
    };
    final content = await api.app.chapter(bid, cid);
    expect(content['content'], '<p idx="0">完整正文</p>');
    expect(fullCalls, 2);
    expect(keyCalls, 1);
    expect(saves, 1);
    expect(api.app.toJson()['key'], base64Encode(key));
  });

  test('登录后的阅读密钥使用 APK Passport 账号接口，不请求网页认证', () async {
    final key = List.filled(16, 9), iv = List.filled(16, 3);
    final master = FanqieCrypto.hex('ac25c67ddd8f38c1b37a2348828e222e');
    final paths = <String>[];
    var valid = false;
    final api = FanqieApi(
      client: MockClient((request) async {
        paths.add(request.url.path);
        expect(request.url.host, isNot('fanqienovel.com'));
        expect(request.headers['Cookie'], 'sessionid=app-session');
        expect(request.headers['x-argus'], isNotEmpty);
        if (request.url.path == '/passport/account/info/v2/') {
          expect(request.url.host, 'security.snssdk.com');
          expect(request.method, 'GET');
          expect(
            request.url.queryParameters['passport-sdk-version'],
            '5051452',
          );
          return http.Response(
            jsonEncode({
              'message': 'success',
              'data': {'user_id': valid ? 42 : 0},
            }),
            200,
          );
        }
        if (request.url.path == '/reading/crypt/registerkey') {
          final body = jsonDecode(request.body);
          final bytes = FanqieCrypto.decryptBlob(body['content'], master);
          expect(bytes.skip(8), [42, 0, 0, 0, 0, 0, 0, 0]);
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'key': base64Encode([
                  ...iv,
                  ...FanqieCrypto.aes(key, master, iv),
                ]),
              },
            }),
            200,
          );
        }
        expect(request.url.path, '/reading/reader/full/v/');
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'novel_data': {'book_id': '1', 'item_id': '2'},
              'crypt_status': 1,
              'content': '<p>body</p>',
            },
          }),
          200,
        );
      }),
    )..setCookie('sessionid=app-session');
    addTearDown(api.close);
    api.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});
    await expectLater(
      api.app.chapter('1', '2'),
      throwsA(isA<SourceException>()),
    );
    expect(paths, ['/passport/account/info/v2/']);
    valid = true;
    final content = await api.app.chapter('1', '2');
    expect(content['content'], '<p>body</p>');
    expect(paths.skip(1), [
      '/passport/account/info/v2/',
      '/reading/crypt/registerkey',
      '/reading/reader/full/v/',
    ]);
  });

  test('本机设备注册不携带账号会话，并拒绝外部接口地址', () async {
    var calls = 0;
    final api = FanqieApi(
      client: MockClient((request) async {
        calls++;
        expect(request.url.host, 'log.snssdk.com');
        expect(request.headers.containsKey('cookie'), isFalse);
        expect(request.bodyBytes.take(6), [0x74, 0x63, 5, 16, 0, 0]);
        return http.Response(
          '{"device_id_str":"123456789","install_id_str":"987654321"}',
          200,
        );
      }),
    )..setCookie('sessionid=synthetic');
    addTearDown(api.close);
    await Future.wait([api.app.ensureDevice(), api.app.ensureDevice()]);
    expect(calls, 1);
    expect(api.app.deviceId, '123456789');
    await expectLater(
      api.app.request('/test', hostname: 'evil.com'),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 1);
  });
}
