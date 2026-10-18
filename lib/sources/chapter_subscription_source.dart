import '../domain/models.dart';
import 'novel_source.dart';

abstract interface class ChapterSubscriptionSource implements NovelSource {
  bool get canSubscribe;
  Future<ChapterSubscriptionQuote> prepareSubscription(
    Book book,
    Chapter first, {
    int? count = 20,
  });
}

class SubscriptionRequiredException extends SourceException {
  const SubscriptionRequiredException(
    super.message, {
    super.code,
    super.errorCode,
  });
}

class SubscriptionUncertainException extends SourceException {
  const SubscriptionUncertainException()
    : super('订阅结果未确认，请先重试阅读或到官方 App 检查订阅记录，再重新获取费用；请勿直接重复订阅。');
}

/// A quote is bound to one source/account and may be submitted only once.
class ChapterSubscriptionQuote {
  ChapterSubscriptionQuote._(this.chapters, this.totalCost, this._submit);
  final List<Chapter> chapters;
  final String totalCost;
  final Future<void> Function() _submit;
  bool _used = false;

  Future<void> confirm() async {
    if (_used) throw const SourceException('请重新获取订阅费用后再确认');
    _used = true;
    await _submit();
  }
}

class ChapterSubscriptionController {
  ChapterSubscriptionQuote? _latest;
  bool _submitting = false;

  ChapterSubscriptionQuote quote({
    required List<Chapter> chapters,
    required String totalCost,
    required Future<void> Function() submit,
  }) {
    final expires = DateTime.now().add(const Duration(minutes: 5));
    late ChapterSubscriptionQuote result;
    result = ChapterSubscriptionQuote._(
      List.unmodifiable(chapters),
      totalCost,
      () async {
        if (_submitting || !identical(result, _latest)) {
          throw const SourceException('订阅信息已更新，请重新获取费用');
        }
        if (DateTime.now().isAfter(expires)) {
          throw const SourceException('订阅费用已过期，请重新获取');
        }
        _submitting = true;
        _latest = null;
        try {
          await submit();
        } finally {
          _submitting = false;
        }
      },
    );
    _latest = result;
    return result;
  }
}

List<Chapter> subscriptionCandidates(
  String sourceId,
  Book book,
  Chapter first,
  int? count,
) {
  final start = book.chapters.indexWhere((c) => c.id == first.id);
  if (book.source != sourceId ||
      start < 0 ||
      count != null && count < 1 ||
      book.chapters.map((c) => c.id).toSet().length != book.chapters.length) {
    throw const SourceException('订阅作品、章节或数量无效');
  }
  return book.chapters.skip(start).toList();
}

List<Chapter> selectSubscriptionChapters(
  List<Chapter> candidates,
  Map<String, int> prices,
  int? count,
) {
  final selected = <Chapter>[];
  for (final chapter in candidates) {
    final price = prices[chapter.id];
    if (price == null || price < 0) {
      throw const SourceException('未取得完整章节权限与费用，请刷新目录后重试');
    }
    if (price == 0) continue;
    selected.add(chapter);
    if (selected.length == count) break;
  }
  if (selected.isEmpty) {
    throw const SourceException('此范围已无需要订阅的章节，请重试阅读');
  }
  return selected;
}
