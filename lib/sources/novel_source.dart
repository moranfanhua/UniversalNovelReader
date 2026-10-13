import '../domain/models.dart';

abstract interface class NovelSource {
  String get id;
  String get name;
  Future<Book> getBook(String input);
  Future<ChapterContent> readChapter(Book book, Chapter chapter);
}
