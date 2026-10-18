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

http.Response response(Object json) => http.Response(
  jsonEncode(json),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('菠萝包更新检查绕过导入预览缓存，只请求 App 详情并读取最新时间', () async {
    var details = 0;
    final api = SfacgApi(
      client: MockClient((request) async {
        if (request.url.path == '/user/Pockets') {
          expect(request.headers['Cookie'], contains('session_APP=synthetic'));
          return response({
            'status': {'httpCode': 200},
            'data': [
              {
                'pocketId': 10,
                'typeId': 2,
                'name': '收藏',
                'expand': {
                  'novels': [
                    {
                      'novelId': 1,
                      'novelName': '旧作品',
                      'authorName': '',
                      'novelCover': '',
                      'lastUpdateTime': '2026-10-01T12:00:00',
                    },
                  ],
                },
              },
            ],
          });
        }
        expect(request.url.host, 'api.sfacg.com');
        expect(request.url.path, '/novels/1');
        expect(request.headers['Cookie'], isNull);
        expect(request.headers['sfsecurity'], isNotEmpty);
        details++;
        return response({
          'status': {'httpCode': 200},
          'data': {
            'novelId': 1,
            'novelName': '新作品',
            'lastUpdateTime': '2026-10-18T12:00:00',
          },
        });
      }),
    )..setCookie('.SFCommunity=synthetic; session_APP=synthetic');
    addTearDown(api.close);
    final source = SfacgSource(api);
    await source.getShelves();
    expect((await source.getShelfBooks(['1'])).single.book!.title, '旧作品');
    expect(details, 0);
    final update = await source.getBookUpdate('1');
    expect(update.title, '新作品');
    expect(update.chapters, isEmpty);
    expect(update.updatedAt, DateTime.utc(2026, 10, 18, 4));
    expect(details, 1);
  });

  test('番茄更新检查仅访问 App 批量详情并保留发布时间', () async {
    const id = '7143038691944959011';
    final api = FanqieApi(
      client: MockClient((request) async {
        expect(request.url.path, '/reading/bookapi/multi-detail/v/');
        expect(request.url.queryParameters['book_id'], id);
        expect(request.headers['Cookie'], isNull);
        expect(request.headers['x-argus'], isNotEmpty);
        return response({
          'code': 0,
          'data': [
            {
              'book_id': id,
              'book_name': '作品',
              'last_publish_time': '1792296000',
            },
          ],
        });
      }),
    )..setCookie('sessionid=synthetic-session');
    addTearDown(api.close);
    api.app.restore({'deviceId': '123456789', 'installId': '234567890'});
    final update = await FanqieSource(api).getBookUpdate(id);
    expect(update.key, 'fanqie:$id');
    expect(update.chapters, isEmpty);
    expect(update.updatedAt!.millisecondsSinceEpoch, 1792296000000);
    expect(api.cookie, 'sessionid=synthetic-session');
  });

  test('刺猬猫更新检查无需目录或书架账号，读取 App 最新章节时间', () async {
    final api =
        CiweimaoApi(
          client: MockClient((request) async {
            expect(request.url.path, '/book/get_info_by_id');
            return http.Response(
              CiweimaoCrypto.encrypt(
                jsonEncode({
                  'code': 100000,
                  'data': {
                    'book_info': {
                      'book_id': '1',
                      'book_name': '作品',
                      'book_type': 1,
                      'last_chapter_info': {'uptime': '2026-10-18 12:00:00'},
                    },
                  },
                }),
              ),
              200,
            );
          }),
        )..restoreSession(
          CiweimaoCredentials(
            account: 'synthetic-account',
            token: 'synthetic-token-1234',
            readerId: '106',
            guest: true,
          ),
        );
    addTearDown(api.close);
    final update = await CiweimaoSource(api).getBookUpdate('1');
    expect(update.key, 'ciweimao:1');
    expect(update.chapters, isEmpty);
    expect(update.updatedAt, DateTime.utc(2026, 10, 18, 4));
  });

  test('起点更新检查仅取 App 详情并选取免费与 VIP 章节中较新的时间', () async {
    final now = DateTime.utc(2026, 10, 18);
    const device = 'aabbccddeeff001122334455667788990000';
    final api = QidianApi(
      device: device,
      clock: () => now,
      client: MockClient((request) async {
        expect(request.url.host, 'druidv6.if.qidian.com');
        expect(request.url.path, '/argus/api/v3/bookdetail/get');
        expect(request.headers['Cookie'], isNull);
        expect(
          request.headers['QDSign'],
          QidianCrypto.headers(
            request.url.queryParameters,
            device: device,
            timestamp: now.millisecondsSinceEpoch,
            userId: '0',
          )['QDSign'],
        );
        return response({
          'Result': 0,
          'Data': {
            'BaseBookInfo': {
              'BookId': 12,
              'BookName': '作品',
              'ChapterInfo': {
                'LastChapterUpdateTime': 100000,
                'LastVipChapterUpdateTime': 200000,
              },
            },
          },
        });
      }),
    );
    final session = QidianCredentials(
      userId: '12',
      ywGuid: '13',
      ywKey: 'synthetic-key',
      token: 'synthetic-token',
    );
    api.credentials = session;
    addTearDown(api.close);
    final update = await QidianSource(api).getBookUpdate('12');
    expect(update.key, 'qidian:12');
    expect(update.chapters, isEmpty);
    expect(update.updatedAt!.millisecondsSinceEpoch, 200000);
    expect(api.credentials, same(session));
  });
}
