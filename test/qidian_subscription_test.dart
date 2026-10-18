import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/chapter_subscription_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_source.dart';

void main() {
  final book = Book(
    id: '12',
    source: 'qidian',
    title: '',
    author: '',
    chapters: [
      for (var i = 1; i <= 130; i++)
        Chapter(id: '$i', title: '第$i章', vip: i > 1),
    ],
  );
  QidianCredentials session() => QidianCredentials(
    userId: '106',
    ywGuid: '106',
    ywKey: 'synthetic',
    token: 'synthetic',
  );
  late QidianSource source;
  late Set<String> owned;
  late List<http.Request> writes;
  late int price, totalDiscount;
  late bool uncertain, missing, partial;
  http.Response ok(Object data) =>
      http.Response(jsonEncode({'Result': 0, 'Data': data}), 200);
  setUp(() {
    owned = {'2', '4'};
    writes = [];
    price = 8;
    totalDiscount = 0;
    uncertain = false;
    missing = false;
    partial = false;
    source = QidianSource(
      QidianApi(
        client: MockClient((request) async {
          expect(request.url.host, 'druidv6.if.qidian.com');
          expect(request.method, 'POST');
          expect(request.headers['QDSign'], isNotEmpty);
          expect(request.headers['Cookie'], contains('cmfuToken='));
          expect(request.bodyFields['bookId'], '12');
          if (request.url.path.endsWith('/changeCoupons')) {
            expect(request.bodyFields['couponServerChoose'], '0');
            expect(request.bodyFields['discountCoupon'], '');
            expect(request.bodyFields['chapterCardList'], '');
            final ids = request.bodyFields['chapterList']!.split(',');
            return ok({
              'BookId': 12,
              'DiscountPrice': ids.length * price - totalDiscount,
            });
          }
          if (request.url.path.endsWith('/buyvipchapter')) {
            writes.add(request);
            expect(request.bodyFields, {
              'bookId': '12',
              'chapterlist': request.bodyFields['chapterlist'],
              'consumeType': '0',
              'withoutLimitFree': '1',
              'sp': '',
              'type': '0',
              'scene': '1',
              'showCoupon': '1',
              'confirmType': '1',
            });
            final ids = request.bodyFields['chapterlist']!.split(',');
            owned.addAll(partial ? ids.take(1) : ids);
            if (uncertain) return http.Response('unrecognized', 503);
            return ok({});
          }
          if (request.url.path.endsWith('/getboughtchapterlist')) {
            return ok(owned.toList());
          }
          expect(
            request.url.path,
            '/argus/api/v2/subscription/getunboughtchapterlist',
          );
          expect(request.bodyFields['pageSize'], '99999');
          expect(request.bodyFields['pageIndex'], '1');
          return ok({
            'Chapter': [
              for (final c in book.chapters.where(
                (c) => c.vip && !owned.contains(c.id),
              ))
                {
                  'CId': int.parse(c.id),
                  'Price': 99,
                  'PriceInfo': {
                    if (!missing || c.id != '3') 'DiscountPrice': price,
                  },
                  'LF': c.id == '6' ? 1 : 0,
                },
            ],
            'FascicleLimitFreeChapterIds': [7],
          });
        }),
      )..credentials = session(),
    );
    addTearDown(source.api.close);
  });
  for (final count in [20, 100, 3, null]) {
    test('起点 $count 章使用账号折扣价格并跳过免费、限免与已购章节', () async {
      final quote = await source.prepareSubscription(
        book,
        book.chapters[2],
        count: count,
      );
      expect(quote.chapters.length, count ?? 125);
      expect(quote.totalCost, '${quote.chapters.length * 8} 起点币');
      expect(
        quote.chapters.any((c) => ['1', '2', '4', '6', '7'].contains(c.id)),
        false,
      );
      expect(writes, isEmpty);
      await quote.confirm();
      expect(writes, hasLength(1));
      expect(
        writes.single.bodyFields['chapterlist']!.split(','),
        quote.chapters.map((c) => c.id),
      );
      await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
    });
  }
  test('账号切换和价格变化使报价失效', () async {
    var quote = await source.prepareSubscription(book, book.chapters[2]);
    source.api.credentials = session();
    await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
    quote = await source.prepareSubscription(book, book.chapters[2]);
    price = 9;
    await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
    expect(writes, isEmpty);
  });
  test('使用服务端批量总价；确认前总价变化不扣费', () async {
    totalDiscount = 5;
    final quote = await source.prepareSubscription(book, book.chapters[2]);
    expect(quote.totalCost, '155 起点币');
    totalDiscount = 6;
    await expectLater(quote.confirm(), throwsA(isA<SourceException>()));
    expect(writes, isEmpty);
  });
  test('费用缺失和未登录不允许提交', () async {
    missing = true;
    await expectLater(
      source.prepareSubscription(book, book.chapters[2]),
      throwsA(isA<SourceException>()),
    );
    source.api.credentials = null;
    await expectLater(
      source.prepareSubscription(book, book.chapters[2]),
      throwsA(isA<SourceException>()),
    );
    expect(writes, isEmpty);
  });
  test('响应不明或仅部分章节获得权限，不报告成功且不重发', () async {
    var quote = await source.prepareSubscription(book, book.chapters[2]);
    uncertain = true;
    await expectLater(
      quote.confirm(),
      throwsA(isA<SubscriptionUncertainException>()),
    );
    expect(writes, hasLength(1));
    uncertain = false;
    partial = true;
    quote = await source.prepareSubscription(book, book.chapters[2]);
    expect(quote.chapters.first.id, '26');
    await expectLater(
      quote.confirm(),
      throwsA(isA<SubscriptionUncertainException>()),
    );
    expect(writes, hasLength(2));
  });
  test('读取未订阅章节提供类型化入口且不自动购买', () async {
    await expectLater(
      source.readChapter(book, book.chapters[2]),
      throwsA(isA<SubscriptionRequiredException>()),
    );
    expect(writes, isEmpty);
  });
}
