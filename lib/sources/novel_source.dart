import '../domain/models.dart';

abstract interface class NovelSource {
  String get id;
  String get name;
  Future<Book> getBook(String input);
  Future<ChapterContent> readChapter(Book book, Chapter chapter);
}

abstract interface class SearchableNovelSource implements NovelSource {
  Future<List<Book>> search(String keyword, {int page = 0});
}

/// The platform may match information absent from the returned book, such as
/// alternate titles. Preserve its result order when merging search results.
abstract interface class PlatformRankedSearchSource
    implements SearchableNovelSource {
  String? get searchNotice;
}
