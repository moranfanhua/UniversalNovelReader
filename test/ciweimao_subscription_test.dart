import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/chapter_subscription_source.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';

void main() {
  final book = Book(
    id: '12',
    source: 'ciweimao',
    title: '',
    author: '',
    chapters: [
      for (var i = 1; i <= 110; i++)
        Chapter(id: '$i', title: '第$i章', vip: i > 1),
    ],
  );
  CiweimaoCredentials session() => CiweimaoCredentials(
    account: 'synthetic',
    token: 'synthetic-token-123456',
    readerId: '106',
  );
  late CiweimaoSource source;
  late Set<String> owned;
  late List<http.Request> writes;
  late String price;
  late bool uncertain;
  late bool missing;
  http.Response ok(Object data) => http.Response(
    CiweimaoCrypto.encrypt(jsonEncode({'code': 100000, 'data': data})),
    200,
  );
  setUp(() {
    owned = {'2', '4'};
    writes = [];
    price = '12.50';
    uncertain = false;
    missing = false;
    final api = CiweimaoApi(
      client: MockClient((request) async {
        expect(request.url.host, 'app1.hbooker.com');
        if (request.url.path == '/chapter/buy_multi') {
          writes.add(request);
          expect(request.bodyFields['is_full'], '0');
          expect(request.bodyFields['shelf_id'], '8');
          final ids =
              jsonDecode(request.bodyFields['chapter_id_list']!) as List;
          owned.addAll(ids.map((c) => '$c'));
          if (uncertain) return http.Response('invalid', 503);
          return ok({
            'prop_info': {'rest_hlb': '1000'},
          });
        }
        if (request.url.path == '/bookshelf/get_shelf_list') {
          return ok({
            'shelf_list': [
              {'shelf_id': '8', 'shelf_name': '默认书架', 'reader_id': '106'},
            ],
          });
        }
        expect(request.url.path, '/chapter/get_chapter_permission_list');
        return ok({
          'chapter_permission_list': [
            for (final c in book.chapters.where((c) => c.vip))
              {
                'chapter_id': c.id,
                'auth_access': owned.contains(c.id) ? '1' : '0',
                if (!missing || c.id != '3') 'unit_hlb': price,
              },
          ],
        });
      }),
    )..restoreSession(session());
    source = CiweimaoSource(api);
    addTearDown(api.close);
  });
  for (final count in [20, 100, 3, null]) {
    test('刺猬猫 $count 章费用使用十进制定点数，批量请求仅含未购章节', () async {
      final quote = await source.prepareSubscription(
        book,
        book.chapters[2],
        count: count,
      );
      expect(quote.chapters.length, count ?? 107);
      expect(
        quote.totalCost,
        count == 3
            ? '37.50 欢乐币'
            : '${quote.chapters.length * 1250 ~/ 100}${quote.chapters.length.isOdd ? '.50' : ''} 欢乐币',
      );
      expect(writes, isEmpty);
      await quote.confirm();
      expect(writes, hasLength(1));
      expect(requestIds(writes.single), quote.chapters.map((c) => c.id));
      await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
    });
  }
  test('切换会话和费用变化均要求重新确认，不发送写请求', () async {
    var quote = await source.prepareSubscription(book, book.chapters[2]);
    source.api.restoreSession(session());
    await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
    quote = await source.prepareSubscription(book, book.chapters[2]);
    price = '13';
    await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
    expect(writes, isEmpty);
  });
  test('权限费用缺失不猜价格，游客不发起订阅', () async {
    missing = true;
    await expectLater(
      source.prepareSubscription(book, book.chapters[2]),
      throwsA(isA<SourceException>()),
    );
    source.api.restoreSession(null);
    await expectLater(
      source.prepareSubscription(book, book.chapters[2]),
      throwsA(isA<SourceException>()),
    );
    expect(writes, isEmpty);
  });
  test('结果不确定不自动重发，重新报价排除已购章节', () async {
    final quote = await source.prepareSubscription(book, book.chapters[2]);
    uncertain = true;
    await expectLater(
      quote.confirm(),
      throwsA(isA<SubscriptionUncertainException>()),
    );
    expect(writes, hasLength(1));
    final refreshed = await source.prepareSubscription(book, book.chapters[2]);
    expect(refreshed.chapters.first.id, '24');
  });
  test('阅读未订阅章节抛出订阅入口类型且绝不自动购买', () async {
    await expectLater(
      source.readChapter(book, book.chapters[2]),
      throwsA(isA<SubscriptionRequiredException>()),
    );
    expect(writes, isEmpty);
  });
}

Iterable<String> requestIds(http.Request request) =>
    (jsonDecode(request.bodyFields['chapter_id_list']!) as List).map(
      (c) => '$c',
    );
