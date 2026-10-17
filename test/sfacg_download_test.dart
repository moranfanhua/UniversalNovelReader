import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

const chapters = [
  Chapter(id: '1', title: '第一章'),
  Chapter(id: '2', title: '第二章'),
  Chapter(id: '3', title: '第三章'),
  Chapter(id: '4', title: '第四章'),
  Chapter(id: '5', title: '第五章'),
  Chapter(id: '6', title: '第六章'),
  Chapter(id: '7', title: '付费章节', vip: true),
];
const book = Book(id: '1', title: '下载测试', author: '作者', chapters: chapters);

SfacgSource source(SfacgApi api) =>
    SfacgSource(api, cipher: {for (var i = 0; i < 3751; i++) '$i': '$i'});
http.Response response(String text, {int code = 200}) => http.Response(
  jsonEncode({
    'status': {'httpCode': code},
    'data': {'content': text},
  }),
  code,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('菠萝包按官方App保持五个任务并及时补位，失败保留其他缓存', () async {
    final root = await Directory.systemTemp.createTemp('unr-sfacg-download-');
    addTearDown(() => root.delete(recursive: true));
    final gates = <String, Completer<void>>{};
    final started = Completer<void>();
    final replenished = Completer<void>();
    var active = 0, maximum = 0;
    final ids = <String>[];
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.url.host, 'api.sfacg.com');
        expect(request.method, 'GET');
        expect(request.url.queryParameters, {
          'expand':
              'content,needFireMoney,originNeedFireMoney,tsukkomi,chatlines,isbranch,isContentEncrypted,authorTalk',
          'autoOrder': 'false',
        });
        expect(request.headers['sfsecurity'], contains('sign='));
        final id = request.url.pathSegments.last;
        ids.add(id);
        final gate = gates.putIfAbsent(id, () => Completer<void>());
        active++;
        if (active > maximum) maximum = active;
        if (active == 5 && !started.isCompleted) started.complete();
        if (id == '6' && !replenished.isCompleted) replenished.complete();
        await gate.future;
        active--;
        return id == '2' ? response('', code: 403) : response('正文 $id');
      }),
    );
    addTearDown(api.close);
    final library = Library(root, source(api));
    final failures = <String>[];
    final download = library.downloadChapters(
      book,
      chapters,
      onProgress: (chapter, error) {
        if (error != null) failures.add(chapter.id);
      },
    );
    await started.future.timeout(const Duration(seconds: 5));
    expect(ids.length, 5);
    expect(maximum, 5);
    gates['1']!.complete();
    await replenished.future.timeout(const Duration(seconds: 5));
    expect(ids.length, 6);
    expect(active, 5);
    expect(maximum, 5);
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await download;
    expect(failures, unorderedEquals(['2', '7']));
    expect(ids, isNot(contains('7')));
    expect(
      (await library.cachedContents(book)).keys,
      unorderedEquals(['1', '3', '4', '5', '6']),
    );
    ids.clear();
    await library.downloadChapters(book, chapters, onProgress: (_, _) {});
    expect(ids, ['2']);
  });

  test('下载按原目录判断付费权限，不能通过传入免费标记触发VIP请求', () async {
    var calls = 0;
    final api = SfacgApi(
      client: MockClient((_) async {
        calls++;
        return response('不应请求');
      }),
    );
    addTearDown(api.close);
    final results = await source(
      api,
    ).readChapterBatch(book, [const Chapter(id: '7', title: '伪造免费标记')]);
    expect(results.single.error, isA<SourceException>());
    expect(calls, 0);
  });
}
