import 'dart:convert';
import 'dart:typed_data';

import '../domain/models.dart';

typedef LibrarySnapshot = ({
  Map<String, Object?> preferences,
  List<Object> books,
  List<Object> recentBooks,
});

typedef EncodedLibrarySnapshot = ({Uint8List bytes, List<String> newBooks});

// Strings are immutable and shared between isolates. Only changed books need
// their chapter models copied and converted again; the large index and its
// UTF-8 bytes are assembled entirely in the worker isolate.
EncodedLibrarySnapshot encodeLibrarySnapshot(LibrarySnapshot snapshot) {
  final newBooks = <String>[];
  final preferences = jsonEncode(snapshot.preferences);
  final buffer = StringBuffer(preferences.substring(0, preferences.length - 1));
  void writeBooks(String key, List<Object> books) {
    buffer.write(',"$key":[');
    for (var i = 0; i < books.length; i++) {
      if (i > 0) buffer.write(',');
      final book = books[i];
      if (book is String) {
        buffer.write(book);
      } else {
        final json = jsonEncode((book as Book).toJson());
        newBooks.add(json);
        buffer.write(json);
      }
    }
    buffer.write(']');
  }

  writeBooks('books', snapshot.books);
  writeBooks('recentBooks', snapshot.recentBooks);
  buffer.write('}');
  return (bytes: utf8.encode(buffer.toString()), newBooks: newBooks);
}
