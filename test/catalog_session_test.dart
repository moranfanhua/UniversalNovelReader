import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_crypto.dart';
import 'package:unr/sources/qidian/qidian_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

http.Response jsonResponse(
  Object data, {
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json; charset=utf-8', ...headers},
);

void main() {
  test('菠萝包已登录时详情和目录仍匿名，匿名响应 Cookie 不覆盖用户会话', () async {
    final paths = <String>[];
    final api = SfacgApi(
      client: MockClient((request) async {
        final path = request.url.path;
        paths.add(path);
        expect(request.headers['sfsecurity'], isNotEmpty);
        if (path == '/user') {
          expect(
            request.headers['Cookie'],
            contains('session_APP=original-app'),
          );
          return jsonResponse({
            'status': {'httpCode': 200},
            'data': {'userId': 1},
          });
        }
        expect(request.headers['Cookie'], isNull);
        return jsonResponse(
          {
            'status': {'httpCode': 200},
            'data': path.endsWith('/dirs')
                ? {
                    'volumeList': [
                      {
                        'volumeId': 1,
                        'chapterList': [
                          {'chapId': 10, 'title': '第一章'},
                        ],
                      },
                    ],
                  }
                : {'novelId': 1, 'novelName': '作品'},
          },
          headers: {
            'set-cookie':
                '.SFCommunity=anonymous; Path=/, session_APP=anonymous; Path=/',
          },
        );
      }),
    )..setCookie('.SFCommunity=original-community; session_APP=original-app');
    addTearDown(api.close);
    var saved = 0;
    api.onSessionChanged = () async {
      saved++;
    };
    final book = await SfacgSource(api).getBook('1');
    expect(book.chapters.single.id, '10');
    expect(saved, 0);
    expect(api.cookies, {
      '.SFCommunity': 'original-community',
      'session_APP': 'original-app',
    });
    await api.get('user');
    expect(paths, ['/novels/1', '/novels/1/dirs', '/user']);
  });

  test('番茄已登录时目录使用匿名 App 签名请求，账号请求仍携带原会话', () async {
    const bid = '7143038691944959011', cid = '7173216089122439711';
    final api = FanqieApi(
      client: MockClient((request) async {
        expect(request.headers['x-argus'], isNotEmpty);
        if (request.url.path == '/passport/account/info/v2/') {
          expect(request.headers['Cookie'], 'sessionid=original-session');
          return jsonResponse({
            'message': 'success',
            'data': {'user_id': '12345'},
          });
        }
        expect(request.url.path, '/reading/bookapi/directory/all_items/v/');
        expect(request.headers['Cookie'], isNull);
        return jsonResponse({
          'code': 0,
          'data': {
            'book_info': {'book_id': bid, 'book_name': '作品', 'genre': '0'},
            'item_data_list': [
              {'item_id': cid, 'title': '第一章'},
            ],
          },
        });
      }),
    )..setCookie('sessionid=original-session');
    addTearDown(api.close);
    api.app.restore({'deviceId': '123456789', 'installId': '234567890'});
    expect((await FanqieSource(api).getBook(bid)).chapters.single.id, cid);
    expect(await api.app.accountId(), '12345');
    expect(api.cookie, 'sessionid=original-session');
  });

  test('起点已登录时目录签名使用匿名用户，私有接口仍使用原账号和 Cookie', () async {
    final now = DateTime.utc(2026, 10, 18);
    const device = 'aabbccddeeff001122334455667788990000';
    final api = QidianApi(
      device: device,
      clock: () => now,
      client: MockClient((request) async {
        final path = request.url.path;
        final private =
            path == '/argus/api/v2/subscription/getboughtchapterlist';
        expect(
          request.headers['QDSign'],
          QidianCrypto.headers(
            request.url.queryParameters,
            device: device,
            timestamp: now.millisecondsSinceEpoch,
            userId: private ? '123' : '0',
          )['QDSign'],
        );
        if (private) {
          expect(
            request.headers['Cookie'],
            contains('cmfuToken=original-token'),
          );
          return jsonResponse({'Result': 0, 'Data': {}});
        }
        expect(request.headers['Cookie'], isNull);
        return jsonResponse({
          'Result': 0,
          'Data': path.endsWith('/bookdetail/get')
              ? {
                  'BaseBookInfo': {'BookId': 12, 'BookName': '作品'},
                }
              : {
                  'BookId': 12,
                  'Volumes': [
                    {'VolumeCode': 1, 'VolumeName': '正文'},
                  ],
                  'Chapters': [
                    {'C': 101, 'N': '第一章', 'O': 1, 'Vc': 1, 'V': 0},
                  ],
                },
        });
      }),
    );
    addTearDown(api.close);
    final session = QidianCredentials(
      userId: '123',
      ywGuid: '456',
      ywKey: 'original-key',
      token: 'original-token',
    );
    api.credentials = session;
    expect((await QidianSource(api).getBook('12')).chapters.single.id, '101');
    await api.request('/argus/api/v2/subscription/getboughtchapterlist', {
      'bookId': '12',
    });
    expect(api.credentials, same(session));
  });

  test('刺猬猫并发详情与目录仅建立一次独立游客会话，已登录账号和存储不变', () async {
    var registrations = 0, saved = 0;
    final api = CiweimaoApi(
      client: MockClient((request) async {
        Object data;
        if (request.url.path == '/signup/auto_reg_v2') {
          registrations++;
          expect(request.bodyFields['account'], isNull);
          expect(request.bodyFields['login_token'], isNull);
          data = {
            'login_token': 'synthetic-guest-token-1234',
            'reader_info': {'account': 'synthetic-guest', 'reader_id': '101'},
          };
        } else {
          expect(request.url.host, 'app1.happybooker.cn');
          expect(request.bodyFields['account'], 'synthetic-guest');
          expect(
            request.bodyFields['login_token'],
            'synthetic-guest-token-1234',
          );
          data = request.url.path == '/book/get_info_by_id'
              ? {
                  'book_info': {
                    'book_id': '12',
                    'book_name': '作品',
                    'book_type': 1,
                  },
                }
              : {
                  'chapter_list': [
                    {
                      'division_id': 1,
                      'division_index': 1,
                      'division_name': '正文',
                      'chapter_list': [
                        {
                          'chapter_id': 101,
                          'chapter_index': 1,
                          'chapter_title': '第一章',
                        },
                      ],
                    },
                  ],
                };
        }
        return http.Response(
          CiweimaoCrypto.encrypt(jsonEncode({'code': 100000, 'data': data})),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final session = CiweimaoCredentials(
      account: 'synthetic-user',
      token: 'synthetic-user-token-1234',
      readerId: '106',
    );
    api.restoreSession(session);
    final generation = api.sessionGeneration;
    api.onSessionChanged = () async {
      saved++;
    };
    final source = CiweimaoSource(api);
    final results = await Future.wait([
      source.getBookUpdate('12'),
      source.getBook('12'),
    ]);
    expect(results.first.chapters, isEmpty);
    expect(results.last.chapters.single.id, '101');
    expect(registrations, 1);
    expect(saved, 0);
    expect(api.credentials, same(session));
    expect(api.sessionGeneration, generation);
    expect(api.hasSession, isTrue);
  });
}
