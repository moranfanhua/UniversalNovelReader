import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../domain/models.dart';
import '../sources/sfacg/sfacg_source.dart';
import '../sources/comment_source.dart';
import 'reader_fonts.dart';

enum ReadingMode { scroll, paged }

enum ShelfSort { updated, name, lastActive }

extension ShelfSortLabel on ShelfSort {
  String get label => switch (this) {
    ShelfSort.updated => '按更新时间',
    ShelfSort.name => '按名称',
    ShelfSort.lastActive => '按上次活跃时间',
  };
}

class Library extends ChangeNotifier {
  Library(
    this.root,
    this.source, {
    ReaderFonts? fonts,
    DateTime Function()? clock,
    Iterable<CommentSource> commentSources = const [],
  }) : fonts = fonts ?? ReaderFonts(Directory('${root.path}/fonts')),
       clock = clock ?? DateTime.now,
       _commentSources = {
         source.id: source,
         for (final service in commentSources) service.id: service,
       };
  final Map<String, CommentSource> _commentSources;
  CommentSource? commentsFor(Book book) => _commentSources[book.source];
  final DateTime Function() clock;
  final ReaderFonts fonts;
  final Directory root;
  final SfacgSource source;
  final List<Book> books = [];
  ShelfSort shelfSort = ShelfSort.lastActive;
  final Map<String, int> updatedTimes = {}, lastActiveTimes = {};
  int _updatedTime(Book book) => book.source == 'local'
      ? updatedTimes[book.key] ?? 0
      : book.updatedAt?.millisecondsSinceEpoch ?? updatedTimes[book.key] ?? 0;
  List<Book> get sortedBooks {
    final result = books.toList();
    final position = {for (var i = 0; i < books.length; i++) books[i].key: i};
    result.sort((a, b) {
      final comparison = switch (shelfSort) {
        ShelfSort.name => a.title.trim().toLowerCase().compareTo(
          b.title.trim().toLowerCase(),
        ),
        ShelfSort.updated => _updatedTime(b).compareTo(_updatedTime(a)),
        ShelfSort.lastActive => (lastActiveTimes[b.key] ?? 0).compareTo(
          lastActiveTimes[a.key] ?? 0,
        ),
      };
      return comparison == 0
          ? position[a.key]!.compareTo(position[b.key]!)
          : comparison;
    });
    return result;
  }

  final Map<String, List<int>> progress = {};
  double fontSize = 20;
  bool night = false;
  ReadingMode readingMode = ReadingMode.scroll;
  bool volumeKeyPaging = true;
  final Map<String, int> pageOffsets = {};
  // Entry alignment and preceding spread origin, indexed by book and chapter.
  final Map<String, List<int>> pagedChapterEntries = {};
  String readingFontId = '';
  String? readingFontFamily, fontNotice;
  final downloadedFonts = <String>{};
  double horizontalMargin = 22, verticalMargin = 24, lineHeight = 1.9;
  Future<void> _writes = Future.value();
  final Map<String, Future<ChapterContent>> _reads = {};
  final Map<String, Future<Uint8List>> _imageReads = {};
  final Map<String, Future<void>> _fileWrites = {};
  static String safeKey(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static Future<Library> open(
    SfacgSource source, {
    Directory? directory,
    ReaderFonts? fonts,
    DateTime Function()? clock,
    Iterable<CommentSource> commentSources = const [],
  }) async {
    final dir =
        directory ??
        Directory('${(await getApplicationSupportDirectory()).path}/library');
    await dir.create(recursive: true);
    final library = Library(
      dir,
      source,
      fonts: fonts,
      clock: clock,
      commentSources: commentSources,
    );
    final file = File('${dir.path}/index.json');
    if (await file.exists()) {
      final data = jsonDecode(await file.readAsString()) as Map;
      library.books.addAll(
        (data['books'] as List).map(
          (j) => Book.fromJson(Map<String, dynamic>.from(j)),
        ),
      );
      library.fontSize = (data['fontSize'] as num? ?? 20).toDouble().clamp(
        14,
        32,
      );
      library.night = data['night'] == true;
      library.volumeKeyPaging = data['volumeKeyPaging'] != false;
      library.shelfSort = ShelfSort.values.firstWhere(
        (sort) => sort.name == data['shelfSort'],
        orElse: () => ShelfSort.lastActive,
      );
      for (final entry in (data['updatedTimes'] as Map? ?? {}).entries) {
        if (entry.value is num) {
          library.updatedTimes['${entry.key}'] = (entry.value as num).toInt();
        }
      }
      for (final entry in (data['lastActiveTimes'] as Map? ?? {}).entries) {
        if (entry.value is num) {
          library.lastActiveTimes['${entry.key}'] = (entry.value as num)
              .toInt();
        }
      }
      library.horizontalMargin = (data['horizontalMargin'] as num? ?? 22)
          .toDouble()
          .clamp(8, 64);
      library.verticalMargin = (data['verticalMargin'] as num? ?? 24)
          .toDouble()
          .clamp(8, 48);
      library.lineHeight = (data['lineHeight'] as num? ?? 1.9).toDouble().clamp(
        1.2,
        2.6,
      );
      library.readingFontId = data['readingFontId'] as String? ?? '';
      library.readingMode = data['readingMode'] == 'paged'
          ? ReadingMode.paged
          : ReadingMode.scroll;
      library.pageOffsets.addAll(
        (data['pageOffsets'] as Map? ?? {}).map(
          (key, value) => MapEntry('$key', (value as num).toInt()),
        ),
      );
      library.progress.addAll(
        (data['progress'] as Map? ?? {}).map(
          (k, v) => MapEntry('$k', (v as List).cast<int>()),
        ),
      );
      for (final entry in (data['pagedChapterEntries'] as Map? ?? {}).entries) {
        if (entry.value is List &&
            (entry.value as List).every((value) => value is int)) {
          library.pagedChapterEntries['${entry.key}'] = (entry.value as List)
              .cast<int>();
        }
      }
    }
    library.downloadedFonts.addAll(await library.fonts.available());
    if (library.readingFontId.isNotEmpty) {
      try {
        library.readingFontFamily = await library.fonts.load(
          library.readingFontId,
        );
      } catch (_) {
        library.downloadedFonts.remove(library.readingFontId);
        library.fontNotice = '所选字体不可用，暂使用系统字体。可重新下载字体或选择系统字体。';
      }
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
      'readingMode': readingMode.name,
      'volumeKeyPaging': volumeKeyPaging,
      'pageOffsets': pageOffsets,
      'pagedChapterEntries': pagedChapterEntries,
      'readingFontId': readingFontId,
      'horizontalMargin': horizontalMargin,
      'verticalMargin': verticalMargin,
      'lineHeight': lineHeight,
      'shelfSort': shelfSort.name,
      'updatedTimes': updatedTimes,
      'lastActiveTimes': lastActiveTimes,
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

  Future<void> selectFont(String id) async {
    String? family;
    try {
      family = id.isEmpty ? null : await fonts.load(id);
    } catch (_) {
      downloadedFonts.remove(id);
      notifyListeners();
      rethrow;
    }
    final oldId = readingFontId, oldFamily = readingFontFamily;
    readingFontId = id;
    readingFontFamily = family;
    fontNotice = null;
    try {
      await save();
    } catch (_) {
      readingFontId = oldId;
      readingFontFamily = oldFamily;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> downloadFont(
    String id, {
    void Function(int, int?)? onProgress,
  }) async {
    await fonts.download(id, onProgress: onProgress);
    downloadedFonts.add(id);
    await selectFont(id);
  }

  Future<void> resetReadingPreferences() async {
    readingFontId = '';
    readingFontFamily = null;
    fontNotice = null;
    fontSize = 20;
    horizontalMargin = 22;
    verticalMargin = 24;
    lineHeight = 1.9;
    readingMode = ReadingMode.scroll;
    volumeKeyPaging = true;
    night = false;
    await save();
  }

  Future<void> add(Book book) async {
    final now = clock().millisecondsSinceEpoch;
    if (book.source == 'local') {
      updatedTimes[book.key] = now;
    } else if (book.updatedAt != null) {
      updatedTimes[book.key] = book.updatedAt!.millisecondsSinceEpoch;
    } else {
      updatedTimes.putIfAbsent(book.key, () => 0);
    }
    lastActiveTimes.putIfAbsent(book.key, () => now);
    final index = books.indexWhere((b) => b.key == book.key);
    if (index < 0) {
      books.insert(0, book);
    } else {
      books[index] = book;
    }
    await save();
  }

  Future<void> setShelfSort(ShelfSort sort) async {
    final old = shelfSort;
    shelfSort = sort;
    try {
      await save();
    } catch (_) {
      shelfSort = old;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> markActive(Book book) async {
    lastActiveTimes[book.key] = clock().millisecondsSinceEpoch;
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
    // EPUB export also needs the cover, even if its preview was never opened.
    if (book.cover.isNotEmpty) await loadImage(book, book.cover);
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
    lastActiveTimes[book.key] = clock().millisecondsSinceEpoch;
    await save();
  }
}
