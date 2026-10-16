import 'novel_source.dart';
import '../domain/models.dart';

class RemoteBookshelf {
  const RemoteBookshelf({required this.id, required this.name, this.bookIds});
  final String id, name;
  final List<String>? bookIds;
}

abstract interface class BookshelfSource implements NovelSource {
  bool get hasSession;
  Future<List<RemoteBookshelf>> getShelves();
  Future<List<String>> getShelfBookIds(RemoteBookshelf shelf);
  int get shelfBookBatchSize;

  /// Fetch shelf previews without downloading chapter directories.
  Future<List<ShelfBookResult>> getShelfBooks(List<String> ids);
}

class ShelfBookResult {
  const ShelfBookResult.success(this.id, Book value)
    : book = value,
      error = null;
  const ShelfBookResult.failure(this.id, Object reason)
    : book = null,
      error = reason;

  final String id;
  final Book? book;
  final Object? error;
}
