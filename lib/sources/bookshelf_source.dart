import 'novel_source.dart';

class RemoteBookshelf {
  const RemoteBookshelf({required this.id, required this.name, this.bookIds});
  final String id, name;
  final List<String>? bookIds;
}

abstract interface class BookshelfSource implements NovelSource {
  bool get hasSession;
  Future<List<RemoteBookshelf>> getShelves();
  Future<List<String>> getShelfBookIds(RemoteBookshelf shelf);
}
