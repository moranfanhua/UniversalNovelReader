import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/chapter_batch_source.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/chapter_download_dialog.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/memory_library.dart';
import 'helpers/viewport.dart';

const chapter = Chapter(id: '12345', title: '第一章');
const book = Book(
  id: '12',
  source: 'qidian',
  title: '旧缓存作品',
  author: '',
  chapters: [chapter],
);
const firstText = '第一段正文。原始章节在本段后还有一个空行。';
const thirdText = '第三段正文。旧缓存中的第二个显示段落，实际段号为三。';
const legacy = ChapterContent([Paragraph(firstText), Paragraph(thirdText)]);

http.Response ok(Object data) => http.Response.bytes(
  utf8.encode(jsonEncode({'Result': 0, 'Data': data})),
  200,
);

class RefreshQidianSource extends QidianSource {
  RefreshQidianSource(super.api);
  int downloads = 0;
  @override
  Future<List<ChapterBatchResult>> readChapterBatch(
    Book book,
    List<Chapter> chapters,
  ) async {
    downloads++;
    return [
      for (final chapter in chapters)
        ChapterBatchResult.success(
          chapter.id,
          QidianSource.parseContent('$firstText\n\n$thirdText', null),
        ),
    ];
  }
}

class ReaderCacheLibrary extends Library
    with MemoryPersistence, MemoryReadingProgress {
  ReaderCacheLibrary(super.root, super.source, RefreshQidianSource qidian)
    : super(novelSources: [qidian]);
  ChapterContent snapshot = legacy;
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async => snapshot;
}

class DownloadOptionsLibrary extends Library {
  DownloadOptionsLibrary(super.root, super.source, {super.novelSources});
  final options = <bool>[];
  Completer<void>? gate;
  @override
  Future<void> downloadChapters(
    Book book,
    List<Chapter> chapters, {
    required void Function(Chapter, Object?) onProgress,
    bool Function()? isCancelled,
    bool refreshCached = false,
  }) async {
    options.add(refreshCached);
    await gate?.future;
    for (final chapter in chapters) {
      onProgress(chapter, null);
    }
  }
}

SfacgSource defaultSource() {
  final api = SfacgApi(
    client: MockClient((_) async => throw const SocketException('离线')),
  );
  addTearDown(api.close);
  return SfacgSource(api);
}

void main() {
  test('旧起点缓存经主动重取获得真实段号，持久化保留正文与阅读位置并可获取段评', () async {
    final root = await Directory.systemTemp.createTemp('unr-qidian-refresh-');
    addTearDown(() => root.delete(recursive: true));
    final api = QidianApi(
      client: MockClient((request) async {
        expect(request.url.host, 'druidv6.if.qidian.com');
        if (request.url.path.endsWith('getparagraphscommentcounts')) {
          return ok({
            'ChapterId': 0,
            'DataList': [
              {'ParagraphId': 3, 'CommentCount': 4},
            ],
          });
        }
        expect(
          request.url.path,
          '/argus/api/v2/chapterreview/getparagraphscomments',
        );
        expect(request.url.queryParameters['paragraphId'], '3');
        return ok({
          'DataList': [
            {
              'Id': '100',
              'ReviewType': 1,
              'ParagraphId': 3,
              'Content': '合成段评内容',
            },
          ],
        });
      }),
    );
    addTearDown(api.close);
    final qidian = RefreshQidianSource(api), sfacg = defaultSource();
    final library = Library(root, sfacg, novelSources: [qidian]);
    addTearDown(library.dispose);
    await library.add(book);
    await library.store(book, chapter, legacy);
    library.pageOffsets[book.key] = 5;
    await library.remember(book, 0, 1);
    await library.downloadChapters(book, [
      chapter,
    ], onProgress: (_, error) => expect(error, isNull));
    expect(qidian.downloads, 0);
    expect(
      (await library.read(book, chapter)).paragraphs.last.remoteIndex,
      isNull,
    );
    await library.downloadChapters(
      book,
      [chapter],
      refreshCached: true,
      onProgress: (_, error) => expect(error, isNull),
    );
    expect(qidian.downloads, 1);
    final reopened = await Library.open(
      sfacg,
      directory: root,
      novelSources: [qidian],
    );
    addTearDown(reopened.dispose);
    final cached = await reopened.read(book, chapter);
    expect(
      cached.paragraphs.map((p) => p.text),
      legacy.paragraphs.map((p) => p.text),
    );
    expect(cached.paragraphs.map((p) => p.remoteIndex), [1, 3]);
    expect(reopened.progress[book.key], [0, 1]);
    expect(reopened.pageOffsets[book.key], 5);
    final location = CommentLocation(
      book: book,
      chapter: chapter,
      paragraph: cached.paragraphs.last,
    );
    expect(await qidian.paragraphCommentCount(location), 4);
    expect((await qidian.commentPage(location)).items.single.text, '合成段评内容');
  });

  for (final mode in ReadingMode.values) {
    for (final width in [390.0, 1400.0]) {
      testWidgets('旧缓存重取后恢复正确段评入口（${mode.name}，宽 $width）', (tester) async {
        setTestViewport(tester, Size(width, 900));
        final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('unr-reader-refresh-'),
        ))!;
        addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
        final rows = <String?>[];
        final api = QidianApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('getparagraphscommentcounts')) {
              return ok({
                'ChapterId': 0,
                'DataList': [
                  {'ParagraphId': 1, 'CommentCount': 1},
                  {'ParagraphId': 3, 'CommentCount': 4},
                ],
              });
            }
            rows.add(request.url.queryParameters['paragraphId']);
            return ok({
              'DataList': [
                {
                  'Id': '100',
                  'ReviewType': 1,
                  'ParagraphId': 3,
                  'Content': '合成段评内容',
                },
              ],
            });
          }),
        );
        addTearDown(api.close);
        final qidian = RefreshQidianSource(api);
        final library = ReaderCacheLibrary(root, defaultSource(), qidian)
          ..readingMode = mode;
        addTearDown(library.dispose);
        await tester.runAsync(() => library.store(book, chapter, legacy));
        Future<void> open() async {
          await tester.pumpWidget(
            MaterialApp(
              home: ReaderPage(library: library, book: book),
            ),
          );
          await tester.pumpAndSettle();
        }

        await open();
        expect(find.byTooltip('阅读本段段评'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await library.downloadChapters(
            book,
            [chapter],
            refreshCached: true,
            onProgress: (_, error) => expect(error, isNull),
          );
          library.snapshot = (await library.cached(book, chapter))!;
        });
        await open();
        expect(find.byTooltip('阅读本段段评'), findsWidgets);
        await tester.tap(find.byTooltip('阅读本段段评').last);
        await tester.pumpAndSettle();
        expect(rows, ['3']);
        expect(find.text('合成段评内容'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final width in [390.0, 1400.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('下载窗口可主动重取缓存且运行期间锁定选项（宽 $width，缩放 $scale）', (tester) async {
        setTestViewport(tester, Size(width, 900));
        final api = QidianApi(
          client: MockClient((_) async => throw StateError('不应联网')),
        );
        addTearDown(api.close);
        final library = DownloadOptionsLibrary(
          Directory.systemTemp,
          defaultSource(),
          novelSources: [QidianSource(api)],
        );
        addTearDown(library.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: DownloadDialog(library: library, book: book),
          ),
        );
        await tester.pumpAndSettle();
        final option = find.byKey(const ValueKey('refresh-cached-chapters'));
        expect(tester.widget<CheckboxListTile>(option).value, isFalse);
        await tester.tap(find.text('开始下载'));
        await tester.pumpAndSettle();
        expect(library.options, [false]);
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pumpAndSettle();
        library.gate = Completer<void>();
        await tester.tap(find.text('重新下载'));
        await tester.pump();
        expect(library.options, [false, true]);
        expect(tester.widget<CheckboxListTile>(option).onChanged, isNull);
        library.gate!.complete();
        await tester.pumpAndSettle();
        expect(find.textContaining('成功 1 章'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
