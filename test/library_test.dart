import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg_api.dart';
import 'package:unr/sources/sfacg_source.dart';

void main() {
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

  test('同时读取同一章节只请求一次，后续可离线读取', () async {
    var calls = 0;
    final response = Completer<http.Response>();
    final api = SfacgApi(
      client: MockClient((_) {
        calls++;
        return response.future;
      }),
    );
    final library = Library(root, SfacgSource(api));
    final first = library.read(book, chapter),
        second = library.read(book, chapter);
    response.complete(
      http.Response(
        '<div id="ChapterBody"><p>缓存正文</p></div>',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      ),
    );
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
        return http.Response(
          calls == 1 ? '' : '<div id="ChapterBody"><p>成功正文</p></div>',
          calls == 1 ? 503 : 200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }),
    );
    final library = Library(root, SfacgSource(api));
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
}
