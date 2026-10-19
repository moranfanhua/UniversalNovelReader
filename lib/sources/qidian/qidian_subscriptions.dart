import '../../domain/models.dart';
import '../chapter_subscription_source.dart';
import 'qidian_api.dart';

mixin QidianSubscriptions implements ChapterSubscriptionSource {
  QidianApi get api;
  final _subscriptions = ChapterSubscriptionController();
  @override
  bool get canSubscribe => api.hasSession;

  Future<Set<String>> _subscriptionOwned(Book book) async {
    final data = api.responsePayload(
      await api.send('/argus/api/v2/subscription/getboughtchapterlist', {
        'bookId': book.id,
      }, post: true),
    );
    if (data is! List ||
        data.any((c) => !RegExp(r'^[1-9]\d{0,11}$').hasMatch('$c'))) {
      throw const SourceException('起点已购章节列表格式已变化');
    }
    return data.map((c) => '$c').toSet();
  }

  Future<Map<String, int>> _subscriptionPrices(Book book) async {
    final owned = await _subscriptionOwned(book);
    final data = await api.request(
      '/argus/api/v2/subscription/getunboughtchapterlist',
      {
        // Official db.e.getUnBoughtChapterList defaults to this complete list.
        'bookId': book.id, 'pageSize': '99999', 'pageIndex': '1',
      },
      post: true,
    );
    if (data['Chapter'] is! List) throw const SourceException('起点订阅费用列表格式已变化');
    final prices = <String, int>{
      for (final c in book.chapters.where(
        (c) => !c.vip || owned.contains(c.id),
      ))
        c.id: 0,
    };
    final seen = <String>{};
    for (final row in data['Chapter']) {
      if (row is! Map) throw const SourceException('起点订阅章节格式已变化');
      final cid = '${row['CId']}';
      final info = row['PriceInfo'];
      final price = int.tryParse(
        '${info is Map ? info['DiscountPrice'] : row['Price']}',
      );
      if (!RegExp(r'^[1-9]\d{0,11}$').hasMatch(cid) ||
          !seen.add(cid) ||
          price == null ||
          price < 0) {
        throw const SourceException('起点未返回有效的章节订阅费用');
      }
      // Limited-free chapters and existing ownership never enter checkout.
      if (!owned.contains(cid)) prices[cid] = '${row['LF']}' == '1' ? 0 : price;
    }
    final limited = data['FascicleLimitFreeChapterIds'];
    if (limited is List) {
      for (final cid in limited) {
        prices['$cid'] = 0;
      }
    }
    return prices;
  }

  Future<int> _subscriptionTotal(Book book, List<Chapter> chapters) async {
    // Official db.e.changeCoupons recalculates the selected batch. Empty
    // coupon lists and couponServerChoose=0 keep coupon selection explicit.
    final data = await api.request('/argus/api/v1/subscription/changeCoupons', {
      'bookId': book.id,
      'chapterList': chapters.map((c) => c.id).join(','),
      'discountCoupon': '',
      'chapterCardList': '',
      'couponServerChoose': '0',
    }, post: true);
    final total = int.tryParse('${data['DiscountPrice']}');
    if ('${data['BookId']}' != book.id || total == null || total < 0) {
      throw const SourceException('起点未返回对应作品的订阅总费用');
    }
    return total;
  }

  @override
  Future<ChapterSubscriptionQuote> prepareSubscription(
    Book book,
    Chapter first, {
    int? count = 20,
  }) async {
    final candidates = subscriptionCandidates(id, book, first, count);
    if (!RegExp(r'^[1-9]\d{0,11}$').hasMatch(book.id) ||
        candidates.any((c) => !RegExp(r'^[1-9]\d{0,11}$').hasMatch(c.id))) {
      throw const SourceException('起点订阅作品或章节编号无效');
    }
    final session = api.credentials;
    void checkAccount() {
      if (session == null || !identical(session, api.credentials)) {
        throw const SourceException('请登录同一起点账号后重新获取费用');
      }
    }

    checkAccount();
    final prices = await _subscriptionPrices(book);
    checkAccount();
    final selected = selectSubscriptionChapters(candidates, prices, count);
    final total = await _subscriptionTotal(book, selected);
    checkAccount();
    return _subscriptions.quote(
      chapters: selected,
      totalCost: '$total 起点币',
      submit: () async {
        checkAccount();
        final latest = await _subscriptionPrices(book);
        checkAccount();
        if (selected.any((c) => latest[c.id] != prices[c.id])) {
          throw const SourceException('章节权限或费用已变化，请重新获取订阅费用');
        }
        final latestTotal = await _subscriptionTotal(book, selected);
        checkAccount();
        if (latestTotal != total) {
          throw const SourceException('订阅总费用已变化，请重新获取费用并确认');
        }
        try {
          // Official component.api.f0.h -> f0.j -> Urls.b0. Parameters were
          // checked against the APK's native builder with HTTP blocked.
          api.responsePayload(
            await api.send('/argus/api/v3/subscription/buyvipchapter', {
              'bookId': book.id,
              'chapterlist': selected.map((c) => c.id).join(','),
              'consumeType': '0',
              'withoutLimitFree': '1',
              'sp': '',
              'type': '0',
              'scene': '1',
              'showCoupon': '1',
              'confirmType': '1',
            }, post: true),
          );
        } on SourceException catch (error) {
          if (error.code != 0 && !(error.code >= 500 && error.code < 600)) {
            rethrow;
          }
          throw const SubscriptionUncertainException();
        } catch (_) {
          throw const SubscriptionUncertainException();
        }
        try {
          checkAccount();
          final purchased = await _subscriptionOwned(book);
          checkAccount();
          if (selected.any((c) => !purchased.contains(c.id))) {
            throw const SubscriptionUncertainException();
          }
        } catch (_) {
          throw const SubscriptionUncertainException();
        }
      },
    );
  }
}
