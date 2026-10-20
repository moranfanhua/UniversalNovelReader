import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/formats/ebook.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

class EncodingBook extends Book {
  const EncodingBook(this.events, {required super.title})
    : super(
        id: 'encoded',
        author: '作者',
        chapters: const [Chapter(id: '1', title: '第一章')],
      );

  final SendPort events;

  @override
  Map<String, dynamic> toJson() {
    events.send((title, Isolate.current.debugName));
    return super.toJson();
  }
}

void main() {
  SfacgSource source(SfacgApi api) =>
      SfacgSource(api, cipher: {for (var i = 0; i < 3751; i++) '$i': '$i'});
  http.Response chapterResponse(String content) => http.Response(
    jsonEncode({
      'status': {'httpCode': 200},
      'data': {'content': content},
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('unr-cache-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  const chapter = Chapter(
    id: '1',
    title: '第一章',
    url: 'https://book.sfacg.com/Novel/1/2/1/',
  );
  const book = Book(id: '1', title: '测试书', author: '测试', chapters: [chapter]);

  test('缓存标记只查文件元数据，兼容旧缓存并隔离平台与临时文件', () async {
    final api = SfacgApi();
    addTearDown(api.close);
    final library = Library(root, source(api));
    addTearDown(library.dispose);
    final chapters = [
      for (var i = 0; i < 1000; i++) Chapter(id: '$i', title: '$i'),
    ];
    final large = book.withChapters(chapters);
    final directory = Directory('${root.path}/${Library.safeKey(large.key)}');
    await directory.create();
    // Invalid JSON is deliberately present: listing must not parse any body.
    await Future.wait([
      for (final chapter in chapters)
        File(
          '${directory.path}/${Library.safeKey(chapter.id)}.json',
        ).writeAsString('not JSON'),
    ]);
    expect(await library.cachedChapterIds(large), hasLength(1000));
    final file = File('${directory.path}/${Library.safeKey('1')}.json');
    await file.delete();
    await File(
      '${directory.path}/${Library.safeKey('2')}.json',
    ).writeAsString('');
    await File(
      '${directory.path}/${Library.safeKey('1')}.json.tmp',
    ).writeAsString('x');
    expect(await library.cachedChapterIds(large), hasLength(998));
    await expectLater(
      library.cached(large, chapters[3]),
      throwsFormatException,
    );
    expect(await library.cachedChapterIds(large), hasLength(997));
    await library.store(
      large,
      chapters[3],
      const ChapterContent([Paragraph('修复')]),
    );
    expect(await library.cachedChapterIds(large), hasLength(998));
    expect(
      await library.cachedChapterIds(
        Book(
          id: book.id,
          title: '',
          author: '',
          source: 'fanqie',
          chapters: chapters,
        ),
      ),
      isEmpty,
    );
  });

  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1QAAAAASUVORK5CYII=',
  );
  const illustratedBook = Book(
    id: '1',
    title: '测试书',
    author: '测试',
    chapters: [chapter],
    cover: 'https://rs.sfacg.com/cover.png',
  );
  const illustration = 'https://rs.sfacg.com/illustration.png';
  final chapterApiUrl = Uri.https('api.sfacg.com', '/Chaps/1', {
    'expand':
        'content,needFireMoney,originNeedFireMoney,tsukkomi,chatlines,isbranch,isContentEncrypted,authorTalk',
    'autoOrder': 'false',
  }).toString();

  test('下载包含封面和插图，断网重开后可阅读并导出 EPUB 和 TXT', () async {
    final calls = <String, int>{};
    final api = SfacgApi(
      client: MockClient((request) async {
        final url = request.url.toString();
        calls[url] = (calls[url] ?? 0) + 1;
        if (url == chapterApiUrl) {
          return chapterResponse('离线正文\n[img=$illustration]');
        }
        expect([illustratedBook.cover, illustration], contains(url));
        return http.Response.bytes(png, 200);
      }),
    );
    final library = Library(root, source(api));
    await library.add(illustratedBook);
    final content = await library.read(illustratedBook, chapter);
    await library.cacheImages(illustratedBook, content);
    await library.cacheImages(illustratedBook, content);
    expect(calls, {
      chapterApiUrl: 1,
      illustration: 1,
      illustratedBook.cover: 1,
    });
    api.close();

    var offlineRequests = 0;
    final offlineApi = SfacgApi(
      client: MockClient((_) async {
        offlineRequests++;
        throw const SocketException('离线');
      }),
    );
    addTearDown(offlineApi.close);
    final reopened = await Library.open(source(offlineApi), directory: root);
    final savedBook = reopened.books.single;
    final savedContent = await reopened.read(
      savedBook,
      savedBook.chapters.single,
    );
    expect(savedContent.paragraphs.first.text, '离线正文');
    final contents = await reopened.cachedContents(savedBook);
    final epub = await Ebook.exportEpub(
      savedBook,
      contents,
      (key) => reopened.loadImage(savedBook, key),
    );
    final imported = Ebook.importEpub(epub);
    expect(imported.images[imported.book.cover], png);
    final paragraphs = imported.contents.values.expand((c) => c.paragraphs);
    expect(paragraphs.map((p) => p.text), contains('离线正文'));
    final image = paragraphs.firstWhere((p) => p.image != null).image!;
    expect(imported.images[image], png);
    expect(utf8.decode(Ebook.exportTxt(savedBook, contents)), contains('离线正文'));
    expect(offlineRequests, 0);
  });

  test('封面下载失败明确报错，保留已缓存正文和插图，重试只补封面', () async {
    var coverCalls = 0, imageCalls = 0;
    final api = SfacgApi(
      client: MockClient((request) async {
        if (request.url.toString() == illustratedBook.cover) {
          coverCalls++;
          if (coverCalls == 1) return http.Response('', 503);
        } else {
          expect(request.url.toString(), illustration);
          imageCalls++;
        }
        return http.Response.bytes(png, 200);
      }),
    );
    addTearDown(api.close);
    final library = Library(root, source(api));
    const content = ChapterContent([
      Paragraph('缓存正文'),
      Paragraph('', image: illustration),
    ]);
    await library.store(illustratedBook, chapter, content);
    await expectLater(
      library.cacheImages(illustratedBook, content),
      throwsA(isA<SourceException>()),
    );
    expect(await library.image(illustratedBook, illustratedBook.cover), isNull);
    expect(await library.image(illustratedBook, illustration), png);
    expect(
      (await library.cached(illustratedBook, chapter))!.paragraphs.first.text,
      '缓存正文',
    );
    await library.cacheImages(illustratedBook, content);
    expect(coverCalls, 2);
    expect(imageCalls, 1);
    expect(await library.image(illustratedBook, illustratedBook.cover), png);
  });

  test('同时读取同一章节只请求一次，后续可离线读取', () async {
    var calls = 0;
    final response = Completer<http.Response>();
    final api = SfacgApi(
      client: MockClient((_) {
        calls++;
        return response.future;
      }),
    );
    final library = Library(root, source(api));
    final first = library.read(book, chapter),
        second = library.read(book, chapter);
    response.complete(chapterResponse('缓存正文'));
    final result = await Future.wait([first, second]);
    expect(calls, 1);
    expect(result[0], same(result[1]));
    api.close();
    expect((await library.read(book, chapter)).paragraphs.single.text, '缓存正文');
  });

  test('失败请求释放占位，重试不会永久返回第一次失败', () async {
    var calls = 0;
    final api = SfacgApi(
      client: MockClient((_) async {
        calls++;
        return calls == 1 ? http.Response('', 503) : chapterResponse('成功正文');
      }),
    );
    final library = Library(root, source(api));
    await expectLater(
      library.read(book, chapter),
      throwsA(isA<SourceException>()),
    );
    expect((await library.read(book, chapter)).paragraphs.single.text, '成功正文');
    expect(calls, 2);
    api.close();
  });

  test('并发缓存写入不会争抢同一个临时文件或留下半个 JSON', () async {
    final api = SfacgApi();
    final library = Library(root, SfacgSource(api));
    await Future.wait([
      library.store(book, chapter, const ChapterContent([Paragraph('甲')])),
      library.store(book, chapter, const ChapterContent([Paragraph('乙')])),
    ]);
    expect([
      '甲',
      '乙',
    ], contains((await library.cached(book, chapter))!.paragraphs.single.text));
    expect(
      (await root.list(recursive: true).toList()).where(
        (e) => e.path.endsWith('.tmp'),
      ),
      isEmpty,
    );
    final index = File('${root.path}/index.json');
    await library.add(book);
    await library.remember(book, 0, 3);
    expect(
      (jsonDecode(await index.readAsString()) as Map)['progress'][book.key],
      [0, 3],
    );
    api.close();
  });

  test('目录在后台编码，进度和偏好保存复用未变化作品，替换作品后更新缓存', () async {
    final api = SfacgApi();
    addTearDown(api.close);
    final library = Library(root, SfacgSource(api));
    addTearDown(library.dispose);
    final port = ReceivePort();
    addTearDown(port.close);
    final encodings = <(String, String?)>[];
    final delivered = Completer<void>();
    port.listen((event) {
      if (event == null) {
        delivered.complete();
      } else {
        encodings.add(event as (String, String?));
      }
    });
    final original = EncodingBook(port.sendPort, title: '原书名');
    await library.add(original);
    await library.remember(original, 0, 7);
    await library.setThemeMode(AppThemeMode.dark);
    await library.updateBook(EncodingBook(port.sendPort, title: '新书名'));
    await library.save();
    port.sendPort.send(null);
    await delivered.future;
    expect(encodings, [('原书名', 'library.encode'), ('新书名', 'library.encode')]);
    final reopened = await Library.open(SfacgSource(api), directory: root);
    addTearDown(reopened.dispose);
    expect(reopened.books.single.title, '新书名');
    expect(reopened.books.single.chapters.single.id, '1');
    expect(reopened.progress[original.key], [0, 7]);
    expect(reopened.themeMode, AppThemeMode.dark);
  });

  test('后台保存冻结调用时的可变进度，排队的新快照最终覆盖旧快照', () async {
    final api = SfacgApi();
    addTearDown(api.close);
    final library = Library(root, SfacgSource(api));
    addTearDown(library.dispose);
    library.books.add(book);
    library.progress[book.key] = [0, 1];
    library.pagedChapterEntries['${book.key}:0'] = [0];
    final first = library.save();
    library.progress[book.key]![1] = 9;
    library.pagedChapterEntries['${book.key}:0']![0] = 1;
    await first;
    final index = File('${root.path}/index.json');
    final original = jsonDecode(await index.readAsString()) as Map;
    expect(original['progress'][book.key], [0, 1]);
    expect(original['pagedChapterEntries']['${book.key}:0'], [0]);

    final second = library.save();
    library.fontSize = 28;
    final third = library.save();
    await Future.wait([second, third]);
    final latest = jsonDecode(await index.readAsString()) as Map;
    expect(latest['progress'][book.key], [0, 9]);
    expect(latest['pagedChapterEntries']['${book.key}:0'], [1]);
    expect(latest['fontSize'], 28);
  });

  test('失败保存保留原索引，恢复存储后仍可保存新快照', () async {
    final api = SfacgApi();
    addTearDown(api.close);
    final library = Library(root, SfacgSource(api));
    addTearDown(library.dispose);
    await library.add(book);
    final index = File('${root.path}/index.json');
    final backup = File('${root.path}/index.backup');
    await index.rename(backup.path);
    await Directory(index.path).create();
    await expectLater(
      library.setThemeMode(AppThemeMode.dark),
      throwsA(isA<FileSystemException>()),
    );
    expect(library.themeMode, AppThemeMode.system);
    expect(
      (jsonDecode(await backup.readAsString()) as Map)['books'],
      hasLength(1),
    );
    await Directory(index.path).delete();
    await backup.rename(index.path);
    await library.setThemeMode(AppThemeMode.light);
    expect(
      (jsonDecode(await index.readAsString()) as Map)['themeMode'],
      'light',
    );
    expect(
      (await root.list().toList()).where((file) => file.path.endsWith('.tmp')),
      isEmpty,
    );
  });
}
