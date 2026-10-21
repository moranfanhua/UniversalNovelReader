import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/data/reader_fonts.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/novel_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

class TestLibrary extends Library {
  TestLibrary({
    SfacgSource? source,
    ReaderFonts? fonts,
    DateTime Function()? clock,
    Iterable<CommentSource> commentSources = const [],
    Iterable<NovelSource> novelSources = const [],
  }) : super(
         Directory.systemTemp,
         source ?? SfacgSource(SfacgApi()),
         fonts: fonts,
         clock: clock,
         commentSources: commentSources,
         novelSources: novelSources,
       );
}

T useLibrary<T extends Library>(T library) {
  addTearDown(library.dispose);
  addTearDown(library.source.api.close);
  return library;
}

// UI tests opt into each replacement separately so persistence and cache tests
// can keep exercising the real Library methods.
mixin MemoryPersistence on Library {
  bool failSave = false;

  @override
  Future<void> save() async {
    if (failSave) throw const FileSystemException('保存失败');
    notifyListeners();
  }
}

mixin MemoryReadingProgress on Library {
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

mixin EmptyChapterCache on Library {
  @override
  Future<Set<String>> cachedChapterIds(Book book) async =>
      (await cachedContents(book)).keys.toSet();

  @override
  Future<Map<String, ChapterContent>> cachedContents(Book book) async => {};
}
