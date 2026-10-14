import '../domain/models.dart';
import 'novel_source.dart';

class NovelSearchResult {
  const NovelSearchResult(this.books, this.failedSources);
  final List<Book> books;
  final List<String> failedSources;
}

Future<NovelSearchResult> searchNovels(
  Iterable<SearchableNovelSource> sources,
  String keyword,
) async {
  final query = keyword.trim();
  if (query.isEmpty) return const NovelSearchResult([], []);
  final responses = await Future.wait(
    sources.map((source) async {
      try {
        return (books: await source.search(query), failure: null);
      } catch (_) {
        return (books: <Book>[], failure: source.name);
      }
    }),
  );
  final books = <String, Book>{};
  for (final response in responses) {
    for (final book in response.books) {
      books.putIfAbsent(book.key, () => book);
    }
  }
  final normalized = _normalize(query);
  final tokens = query
      .split(RegExp(r'\s+'))
      .map(_normalize)
      .where((s) => s.isNotEmpty)
      .toList();
  final ranked = [
    for (final book in books.values)
      (book: book, relevance: _relevance(book, normalized, tokens)),
  ];
  // Keep the source/result order as the final tie breaker, independent of latency.
  final positions = {
    for (var i = 0; i < ranked.length; i++) ranked[i].book.key: i,
  };
  ranked.sort((a, b) {
    var order = b.relevance.compareTo(a.relevance);
    if (order == 0) {
      order = (b.book.favoriteCount ?? -1).compareTo(
        a.book.favoriteCount ?? -1,
      );
    }
    return order == 0
        ? positions[a.book.key]!.compareTo(positions[b.book.key]!)
        : order;
  });
  return NovelSearchResult(
    ranked.map((entry) => entry.book).toList(),
    responses.map((response) => response.failure).whereType<String>().toList(),
  );
}

String _normalize(String text) => text.toLowerCase().replaceAll(
  RegExp(r'[\s\p{P}\p{S}]+', unicode: true),
  '',
);

int _relevance(Book book, String query, List<String> tokens) {
  if (query.isEmpty) return 0;
  final title = _normalize(book.title), author = _normalize(book.author);
  if (title == query) return 600;
  if (title.contains(query)) return 500;
  if (author == query) return 400;
  if (author.contains(query)) return 300;
  if (tokens.isNotEmpty &&
      tokens.every(
        (token) => title.contains(token) || author.contains(token),
      )) {
    return 200;
  }
  // Adjacent matching characters give fuzzy results a common relevance scale.
  final characters = query.runes.toList();
  final pairs = <String>{
    for (var i = 1; i < characters.length; i++)
      String.fromCharCodes(characters.sublist(i - 1, i + 1)),
  };
  final matched = pairs
      .where((pair) => title.contains(pair) || author.contains(pair))
      .length;
  return pairs.isEmpty ? 0 : matched * 100 ~/ pairs.length;
}
