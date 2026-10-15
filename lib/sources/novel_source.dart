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
