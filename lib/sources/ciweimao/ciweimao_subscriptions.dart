import '../../domain/models.dart';
import '../chapter_subscription_source.dart';
import 'ciweimao_bookshelf.dart';
import 'ciweimao_parser.dart';

mixin CiweimaoSubscriptions on CiweimaoBookshelf
    implements ChapterSubscriptionSource {
  final _subscriptions = ChapterSubscriptionController();
  @override
  bool get canSubscribe => api.hasSession;

  // unit_hlb is a decimal string. Keep hundredths as integers when summing.
  static int _price(Object? value) {
    final text = '$value';
    if (!RegExp(r'^\d{1,10}(?:\.\d{1,2})?$').hasMatch(text)) {
      throw const SourceException('刺猬猫章节订阅费用无效');
    }
    final parts = text.split('.');
    return int.parse(parts.first) * 100 +
        (parts.length == 1 ? 0 : int.parse(parts.last.padRight(2, '0')));
  }

  Future<Map<String, int>> _subscriptionPrices(Book book) async {
    final data = await api.request('chapter/get_chapter_permission_list', {
      'book_id': book.id,
    });
    final prices = <String, int>{
      for (final chapter in book.chapters.where((c) => !c.vip)) chapter.id: 0,
    };
    final seen = <String>{};
    for (final row in CiweimaoParser.list(
      data['chapter_permission_list'],
      '订阅权限',
    )) {
      final info = CiweimaoParser.object(row, '订阅权限');
      final cid = CiweimaoParser.numericId(info['chapter_id']);
      if (!seen.add(cid) || !['0', '1'].contains('${info['auth_access']}')) {
        throw const SourceException('刺猬猫订阅权限格式已变化');
      }
      prices[cid] = '${info['auth_access']}' == '1'
          ? 0
          : _price(info['unit_hlb']);
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
    CiweimaoParser.numericId(book.id);
    for (final chapter in candidates) {
      CiweimaoParser.numericId(chapter.id);
    }
    final generation = api.sessionGeneration;
    void checkAccount() {
      api.checkSession(generation);
      if (!canSubscribe) throw const SourceException('请先登录刺猬猫后重新获取费用');
    }

    checkAccount();
    final prices = await _subscriptionPrices(book);
    checkAccount();
    final selected = selectSubscriptionChapters(candidates, prices, count);
    final shelves = await getShelves();
    checkAccount();
    if (shelves.isEmpty) throw const SourceException('刺猬猫未返回可用书架，无法订阅');
    final total = selected.fold(0, (sum, c) => sum + prices[c.id]!);
    final cost = total % 100 == 0
        ? '${total ~/ 100}'
        : '${total ~/ 100}.${(total % 100).toString().padLeft(2, '0')}';
    return _subscriptions.quote(
      chapters: selected,
      totalCost: '$cost 欢乐币',
      submit: () async {
        checkAccount();
        final latest = await _subscriptionPrices(book);
        checkAccount();
        if (selected.any((c) => latest[c.id] != prices[c.id])) {
          throw const SourceException('章节权限或费用已变化，请重新获取订阅费用');
        }
        try {
          // Official ChaptersBuyTask uses List.toString(), not comma-only IDs.
          // is_full=0 restricts the purchase to this explicit list (even “全部”).
          await api.request('chapter/buy_multi', {
            'chapter_id_list': '[${selected.map((c) => c.id).join(', ')}]',
            'is_full': '0',
            'shelf_id': shelves.first.id,
          }, write: true);
        } on SourceException catch (error) {
          if (error.code >= 100000) rethrow;
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
