import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../domain/models.dart';
import '../sources/sfacg_source.dart';

class Library extends ChangeNotifier {
  Library(this.root, this.source);
  final Directory root;
  final SfacgSource source;
  final List<Book> books = [];
  final Map<String, List<int>> progress = {};
  double fontSize = 20;
  bool night = false;
  Future<void> _writes = Future.value();
  final Map<String, Future<ChapterContent>> _reads = {};
  final Map<String, Future<Uint8List>> _imageReads = {};
  final Map<String, Future<void>> _fileWrites = {};
  static String safeKey(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static Future<Library> open(SfacgSource source) async {
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/library',
    );
    await dir.create(recursive: true);
    final library = Library(dir, source);
    final file = File('${dir.path}/index.json');
    if (await file.exists()) {
      final data = jsonDecode(await file.readAsString()) as Map;
      library.books.addAll(
        (data['books'] as List).map(
          (j) => Book.fromJson(Map<String, dynamic>.from(j)),
        ),
      );
      library.fontSize = (data['fontSize'] as num? ?? 20).toDouble();
      library.night = data['night'] == true;
      library.progress.addAll(
        (data['progress'] as Map? ?? {}).map(
          (k, v) => MapEntry('$k', (v as List).cast<int>()),
        ),
      );
    }
    return library;
  }

  Future<void> _atomic(File file, List<int> bytes) {
    final previous = _fileWrites[file.path] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .catchError((_) {})
        .then((_) => _replace(file, bytes))
        .whenComplete(() {
          if (identical(_fileWrites[file.path], next)) {
            _fileWrites.remove(file.path);
          }
        });
    _fileWrites[file.path] = next;
    return next;
  }

  Future<void> _replace(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.${const Uuid().v4()}.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } finally {
      // A failed write must neither replace existing content nor leave a shared
      // temporary file that another request could rename.
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // Preserve the original write/rename failure for the caller.
      }
    }
  }

  Future<void> save() {
    final json = jsonEncode({
      'books': books.map((b) => b.toJson()).toList(),
      'progress': progress,
      'fontSize': fontSize,
      'night': night,
    });
    // Serialize preferences writes so navigation and font changes cannot race.
    final next = _writes
        .catchError((_) {})
        .then(
          (_) => _atomic(File('${root.path}/index.json'), utf8.encode(json)),
        );
    _writes = next;
    notifyListeners();
    return next;
  }

  File _chapterFile(Book book, Chapter chapter) =>
      File('${root.path}/${safeKey(book.key)}/${safeKey(chapter.id)}.json');
  Future<void> add(Book book) async {
    final index = books.indexWhere((b) => b.key == book.key);
    if (index < 0) {
      books.insert(0, book);
    } else {
      books[index] = book;
    }
    await save();
  }

  Future<void> store(Book book, Chapter chapter, ChapterContent content) =>
      _atomic(
        _chapterFile(book, chapter),
        utf8.encode(jsonEncode(content.toJson())),
      );
  Future<ChapterContent?> cached(Book book, Chapter chapter) async {
    final file = _chapterFile(book, chapter);
    if (!await file.exists()) return null;
    return ChapterContent.fromJson(jsonDecode(await file.readAsString()));
  }

  Future<ChapterContent> read(Book book, Chapter chapter) {
    final key = '${book.key}/${chapter.id}';
    return _reads.putIfAbsent(key, () {
      return _readChapter(book, chapter).whenComplete(() {
        _reads.remove(key);
      });
    });
  }

  Future<ChapterContent> _readChapter(Book book, Chapter chapter) async {
    final saved = await cached(book, chapter);
    if (saved != null) return saved;
    if (book.source != 'sfacg') {
      throw const SourceException('本地章节缓存缺失，请重新导入原文件');
    }
    final content = await source.readChapter(book, chapter);
    await store(book, chapter, content);
    return content;
  }

  Future<Map<String, ChapterContent>> cachedContents(Book book) async {
    final result = <String, ChapterContent>{};
    for (final chapter in book.chapters) {
      final c = await cached(book, chapter);
      if (c != null) result[chapter.id] = c;
    }
    return result;
  }

  File imageFile(Book book, String key) =>
      File('${root.path}/${safeKey(book.key)}/images/${safeKey(key)}');
  Future<Uint8List?> image(Book book, String key) async {
    final file = imageFile(book, key);
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<void> saveImage(Book book, String key, Uint8List bytes) =>
      _atomic(imageFile(book, key), bytes);
  Future<Uint8List> loadImage(Book book, String key) {
    final requestKey = '${book.key}/$key';
    return _imageReads.putIfAbsent(requestKey, () {
      return _loadImage(book, key).whenComplete(() {
        _imageReads.remove(requestKey);
      });
    });
  }

  Future<Uint8List> _loadImage(Book book, String key) async {
    final saved = await image(book, key);
    if (saved != null) return saved;
    if (key.startsWith('local:')) {
      throw const SourceException('本地插图缺失，请重新导入原文件');
    }
    var uri = Uri.parse(key);
    if (uri.scheme == 'http') uri = uri.replace(scheme: 'https');
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      throw const SourceException('插图地址无效');
    }
    final response = await source.api.client
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw SourceException('插图下载失败（HTTP ${response.statusCode}）');
    }
    final builder = BytesBuilder();
    await for (final bytes in response.stream.timeout(
      const Duration(seconds: 25),
    )) {
      builder.add(bytes);
      if (builder.length > 20 * 1024 * 1024) {
        throw const SourceException('单张插图超过 20 MB');
      }
    }
    final data = builder.takeBytes();
    await saveImage(book, key, data);
    return data;
  }

  Future<void> cacheImages(Book book, ChapterContent content) async {
    for (final p in content.paragraphs) {
      if (p.image != null) await loadImage(book, p.image!);
    }
  }

  Future<void> import(ImportedBook data) async {
    for (final chapter in data.book.chapters) {
      await store(data.book, chapter, data.contents[chapter.id]!);
    }
    for (final entry in data.images.entries) {
      await saveImage(data.book, entry.key, entry.value);
    }
    await add(data.book);
  }

  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
    await save();
  }
}
