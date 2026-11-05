import '../domain/models.dart';

/// A platform explicitly rejected further access. Finish active batch results,
/// then stop scheduling requests rather than treating this as a chapter error.
class SourceAccessRestrictedException extends SourceException {
  const SourceAccessRestrictedException(super.message, {super.code});
}

abstract interface class NovelSource {
  String get id;
  String get name;
  Future<Book> getBook(String input);
  Future<ChapterContent> readChapter(Book book, Chapter chapter);
}

/// Fresh App metadata used by automatic shelf checks. Unlike import previews,
/// this must bypass any preview cached when the remote shelf was first read.
abstract interface class BookUpdateSource implements NovelSource {
  Future<Book> getBookUpdate(String id);
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
