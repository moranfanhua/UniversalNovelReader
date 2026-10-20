import '../../domain/models.dart';
import '../chapter_subscription_source.dart';
import 'sfacg_api.dart';

mixin SfacgSubscriptions implements ChapterSubscriptionSource {
  SfacgApi get api;
  final _subscriptions = ChapterSubscriptionController();
  @override
  bool get canSubscribe => api.hasSession && !api.websiteSession;
  String get _subscriptionAccount =>
      '${api.cookies['.SFCommunity']}|${api.cookies['session_APP']}';

  Future<Map<String, int>> _subscriptionPrices(Book book) async {
    final data = await api.get(
      'novels/${book.id}/dirs',
      query: {'expand': 'needFireMoney,originNeedFireMoney'},
    );
    if (data is! Map ||
        data['volumeList'] is! List ||
        data['novelId'] != null && '${data['novelId']}' != book.id) {
      throw const SourceException('菠萝包订阅目录格式已变化');
    }
    final prices = <String, int>{};
    for (final volume in data['volumeList']) {
      if (volume is! Map || volume['chapterList'] is! List) {
        throw const SourceException('菠萝包订阅分卷格式已变化');
      }
      for (final chapter in volume['chapterList']) {
        if (chapter is! Map) throw const SourceException('菠萝包订阅章节格式已变化');
        final cid = '${chapter['chapId']}';
        final price = int.tryParse('${chapter['needFireMoney']}');
        if (!RegExp(r'^[1-9]\d*$').hasMatch(cid) ||
            prices.containsKey(cid) ||
            price == null ||
            price < 0) {
          throw const SourceException('菠萝包未返回有效的章节订阅费用');
        }
        prices[cid] = price;
      }
    }
    return prices;
  }

  @override
  Future<ChapterSubscriptionQuote> prepareSubscription(
    Book book,
    Chapter first, {
    int? count = 20,
  }) async {
    final candidates = subscriptionCandidates(id, book, first, count);
    if (!RegExp(r'^[1-9]\d{0,9}$').hasMatch(book.id) ||
        candidates.any((c) => !RegExp(r'^[1-9]\d*$').hasMatch(c.id))) {
      throw const SourceException('菠萝包订阅作品或章节编号无效');
    }
    final account = _subscriptionAccount;
    void checkAccount() {
      if (!canSubscribe || account != _subscriptionAccount) {
        throw const SourceException('请登录同一菠萝包 App 账号后重新获取费用');
      }
    }

    checkAccount();
    final prices = await _subscriptionPrices(book);
    checkAccount();
    final selected = selectSubscriptionChapters(candidates, prices, count);
    final total = selected.fold(0, (sum, c) => sum + prices[c.id]!);
    return _subscriptions.quote(
      chapters: selected,
      totalCost: '$total 火券',
      submit: () async {
        checkAccount();
        final latest = await _subscriptionPrices(book);
        checkAccount();
        if (selected.any((c) => latest[c.id] != prices[c.id])) {
          throw const SourceException('章节权限或费用已变化，请重新获取订阅费用');
        }
        try {
          // Official DownloadViewModel.T1 / NovelApi.orderNovelChaps.
          await api.request(
            'novels/${book.id}/orderedchaps',
            body: {
              'chapIds': selected.map((c) => int.parse(c.id)).toList(),
              'orderAll': false,
              'autoOrder': false,
              'novelId': int.parse(book.id),
              'orderType': 'readOrder',
            },
            retry: false,
          );
        } on SourceException catch (error) {
          if (error.code >= 400 && error.code < 500) rethrow;
          throw const SubscriptionUncertainException();
        } catch (_) {
          throw const SubscriptionUncertainException();
        }
        try {
          checkAccount();
          final purchased = await _subscriptionPrices(book);
          checkAccount();
          if (selected.any((c) => purchased[c.id] != 0)) {
            throw const SubscriptionUncertainException();
          }
        } catch (_) {
          throw const SubscriptionUncertainException();
        }
      },
    );
  }
}
