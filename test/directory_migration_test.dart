import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/reader.dart';

import 'helpers/reading_taps.dart';
import 'helpers/memory_library.dart';
import 'helpers/viewport.dart';

Book directory(List<String> ids) => Book(
  id: 'directory',
  source: 'local',
  title: '目录迁移',
  author: '',
  chapters: [for (final id in ids) Chapter(id: id, title: id)],
);

class MigrationLibrary extends TestLibrary with MemoryPersistence {
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      ChapterContent([Paragraph('${chapter.id}章正文')]);
}

void main() {
  MigrationLibrary library() {
    final value = useLibrary(MigrationLibrary());
    return value;
  }

  test('插入章节后同时迁移双页记录的键和前驱索引，不修改原记录', () async {
    final value = library()..books.add(directory(['A', 'B', 'C']));
    final original = [1, 0, 0];
    value.progress['local:directory'] = [2, 7];
    value.pagedChapterEntries['local:directory:2'] = original;
    await value.updateBook(
      directory(['序章', 'A', 'B', 'C']),
      preserveChapterPosition: true,
    );
    expect(value.progress['local:directory'], [3, 7]);
    // A's final spread contains B, so C still returns to A rather than B.
    expect(value.pagedChapterEntries, {
      'local:directory:3': [1, 1, 0],
    });
    expect(original, [1, 0, 0]);
  });

  for (final ids in [
    ['序章', 'B', 'C'], // Delete the predecessor.
    ['序章', 'C', 'A', 'B'], // Move the predecessor after the current chapter.
    ['序章', 'A', '新章', 'B', 'C'], // Insert into the old cross-chapter spread.
    ['序章', 'A', 'C'], // Delete the chapter previously shown on the right.
  ]) {
    test('前驱或跨章关系变化后清除失效衔接（${ids.join('、')}）', () async {
      final value = library()..books.add(directory(['序章', 'A', 'B', 'C']));
      value.progress['local:directory'] = [3, 0];
      value.pagedChapterEntries['local:directory:2'] = [1, 1, 0];
      value.pagedChapterEntries['local:directory:3'] = [1, 1, 0];
      await value.updateBook(directory(ids), preserveChapterPosition: true);
      expect(value.pagedChapterEntries['local:directory:${ids.indexOf('C')}'], [
        0,
      ]);
      if (!ids.contains('B')) expect(value.pagedChapterEntries.length, 1);
    });
  }

  test('迁移后保存失败完整恢复记录的键、前驱和阅读位置', () async {
    final originalBook = directory(['A', 'B']);
    final value = library()..books.add(originalBook);
    final original = [1, 0, 0];
    value.progress[originalBook.key] = [1, 7];
    value.pagedChapterEntries['${originalBook.key}:1'] = original;
    value.failSave = true;
    await expectLater(
      value.updateBook(
        directory(['序章', 'A', 'B']),
        preserveChapterPosition: true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(value.books.single, same(originalBook));
    expect(value.progress[originalBook.key], [1, 7]);
    expect(value.pagedChapterEntries, {
      '${originalBook.key}:1': [1, 0, 0],
    });
    expect(original, [1, 0, 0]);
  });

  test('迁移后的前驱索引和阅读位置保存后重开仍然正确', () async {
    final root = await Directory.systemTemp.createTemp(
      'unr-directory-migration-',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = SfacgSource(SfacgApi());
    addTearDown(source.api.close);
    final original = directory(['A', 'B']);
    final value = Library(root, source)..books.add(original);
    addTearDown(value.dispose);
    value.progress[original.key] = [1, 7];
    value.pageOffsets[original.key] = 12;
    value.pagedChapterEntries['${original.key}:1'] = [1, 0, 0];
    await value.updateBook(
      directory(['序章', 'A', 'B']),
      preserveChapterPosition: true,
    );
    final reopened = await Library.open(source, directory: root);
    addTearDown(reopened.dispose);
    expect(reopened.progress[original.key], [2, 7]);
    expect(reopened.pageOffsets[original.key], 12);
    expect(reopened.pagedChapterEntries, {
      '${original.key}:2': [1, 1, 0],
    });
  });

  for (final width in [390.0, 1400.0]) {
    for (final deleted in [false, true]) {
      testWidgets('目录${deleted ? '删除前驱' : '前插章节'}后重开 B，向前翻到新目录的上一章（$width）', (
        tester,
      ) async {
        setTestViewport(tester, Size(width, 844));
        final previous = directory(deleted ? ['序章', 'A', 'B'] : ['A', 'B']);
        final next = directory(deleted ? ['序章', 'B'] : ['序章', 'A', 'B']);
        final oldIndex = previous.chapters.length - 1;
        final value = library()
          ..readingMode = ReadingMode.paged
          ..books.add(previous);
        value.progress[previous.key] = [oldIndex, 0];
        value.pagedChapterEntries['${previous.key}:$oldIndex'] = [
          0,
          oldIndex - 1,
          0,
        ];
        await value.updateBook(next, preserveChapterPosition: true);
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(library: value, book: value.books.single),
          ),
        );
        await tester.pumpAndSettle();
        expect(readingChapter(tester), next.chapters.length - 1);
        await tapReadingSide(tester, -1);
        await tester.pumpAndSettle();
        expect(readingChapter(tester), next.chapters.length - 2);
        expect(
          find.text('　　${deleted ? '序章' : 'A'}章正文').hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
