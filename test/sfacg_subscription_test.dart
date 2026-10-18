import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/chapter_subscription_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

void main() {
  final book = Book(
    id: '123',
    title: '订阅测试',
    author: '',
    chapters: [
      for (var i = 1; i <= 130; i++)
        Chapter(id: '$i', title: '第$i章', vip: i > 1),
    ],
  );
  late SfacgSource source;
  late Set<String> owned;
  late List<http.Request> writes;
  late int price;
  late bool uncertain;
  late bool malformed;
  setUp(() {
    owned = {'2', '4'};
    writes = [];
    price = 5;
    uncertain = false;
    malformed = false;
    source = SfacgSource(
      SfacgApi(
        client: MockClient((request) async {
          expect(request.url.host, 'api.sfacg.com');
          expect(request.headers['Cookie'], contains('session_APP='));
          if (request.method == 'POST') {
            writes.add(request);
            expect(request.url.path, '/novels/123/orderedchaps');
            final body = jsonDecode(request.body) as Map;
            expect(body['autoOrder'], false);
            expect(body['orderAll'], false);
            expect(body['orderType'], 'readOrder');
            expect(body['novelId'], 123);
            for (final cid in body['chapIds'] as List) {
              owned.add('$cid');
            }
            if (uncertain) return http.Response('unrecognized', 503);
            return http.Response(
              jsonEncode({
                'status': {'httpCode': 200},
                'data': {},
              }),
              200,
            );
          }
          expect(request.url.path, '/novels/123/dirs');
          return http.Response(
            jsonEncode({
              'status': {'httpCode': 200},
              'data': {
                'novelId': 123,
                'volumeList': [
                  {
                    'chapterList': [
                      for (final c in book.chapters)
                        {
                          'chapId': c.id,
                          if (!malformed || c.id != '3')
                            'needFireMoney': !c.vip || owned.contains(c.id)
                                ? 0
                                : price,
                        },
                    ],
                  },
                ],
              },
            }),
            200,
          );
        }),
      )..setCookie('.SFCommunity=test; session_APP=test'),
    );
    addTearDown(source.api.close);
  });

  for (final count in [20, 100, 7, null]) {
    test('菠萝包订阅 $count 章从当前章起跳过免费与已购章节', () async {
      final quote = await source.prepareSubscription(
        book,
        book.chapters[2],
        count: count,
      );
      expect(writes, isEmpty);
      expect(quote.chapters.length, count ?? 127);
      expect(quote.chapters.first.id, '3');
      expect(quote.chapters.any((c) => owned.contains(c.id)), false);
      expect(quote.totalCost, '${quote.chapters.length * 5} 火券');
      await quote.confirm();
      expect(writes, hasLength(1));
      expect(
        (jsonDecode(writes.single.body)['chapIds'] as List).map((c) => '$c'),
        quote.chapters.map((c) => c.id),
      );
      await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
      expect(writes, hasLength(1));
    });
  }
  test('切换账号、更新价格、更新报价后均不能提交旧费用', () async {
    var quote = await source.prepareSubscription(book, book.chapters[2]);
    source.api.setCookie('.SFCommunity=another; session_APP=another');
    await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
    quote = await source.prepareSubscription(book, book.chapters[2]);
    price = 6;
    await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
    quote = await source.prepareSubscription(book, book.chapters[2]);
    await source.prepareSubscription(book, book.chapters[2], count: 1);
    await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
    expect(writes, isEmpty);
  });
  test('费用缺失、跨平台及无效数量不允许订阅', () async {
    malformed = true;
    await expectLater(
      source.prepareSubscription(book, book.chapters[2]),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.prepareSubscription(book, book.chapters[2], count: 0),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.prepareSubscription(
        Book(
          id: '123',
          source: 'qidian',
          title: '',
          author: '',
          chapters: book.chapters,
        ),
        book.chapters[2],
      ),
      throwsA(isA<SourceException>()),
    );
    expect(writes, isEmpty);
  });
  test('写入结果不确定只发送一次，重新获取费用过滤已购章节', () async {
    final quote = await source.prepareSubscription(book, book.chapters[2]);
    uncertain = true;
    await expectLater(
      quote.confirm(),
      throwsA(isA<SubscriptionUncertainException>()),
    );
    expect(writes, hasLength(1));
    final refreshed = await source.prepareSubscription(book, book.chapters[2]);
    expect(refreshed.chapters.first.id, '24');
    expect(writes, hasLength(1));
  });
  test('未订阅响应即使带试读内容，也只提供订阅入口', () async {
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.queryParameters['autoOrder'], 'false');
        return http.Response(
          jsonEncode({
            'status': {'httpCode': 200},
            'data': {
              'needFireMoney': 5,
              'expand': {'content': '试读正文'},
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    )..setCookie('.SFCommunity=test; session_APP=test');
    addTearDown(api.close);
    await expectLater(
      SfacgSource(api).readChapter(book, book.chapters[2]),
      throwsA(isA<SubscriptionRequiredException>()),
    );
  });
}
