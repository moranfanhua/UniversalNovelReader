import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_crypto.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

const bid = '7143038691944959011';
final chapters = List.generate(
  31,
  (i) => Chapter(id: '${7173216089122439700 + i}', title: '第${i + 1}章'),
);
final book = Book(
  id: bid,
  source: 'fanqie',
  title: '番茄下载',
  author: '作者',
  chapters: chapters,
);

http.Response ok(Object data) => http.Response(
  jsonEncode({'code': 0, 'data': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Map<String, dynamic> item(String id, {String? bookId, List<int>? key}) {
  final markup = '<p idx="0">正文 $id</p>';
  final iv = List.filled(16, 3);
  return {
    'novel_data': {
      'book_id': bookId ?? bid,
      'item_id': id,
      'version': 'version-1',
    },
    'crypt_status': key == null ? 1 : 0,
    'compress_status': key == null ? 0 : 1,
    'paragraphs_num': 1,
    'content': key == null
        ? markup
        : base64Encode([
            ...iv,
            ...FanqieCrypto.aes(gzip.encode(utf8.encode(markup)), key, iv),
          ]),
  };
}

void restore(FanqieApi api, {List<int>? key}) => api.app.restore({
  'deviceId': '123456789',
  'installId': '987654321',
  'key': base64Encode(key ?? List.filled(16, 7)),
  'keyOwner': sha256.convert([]).toString(),
  'keyRegisterTs': 17,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('31章按官方30章分组，只请求App批量接口，乱序结果保留段评版本并写入缓存', () async {
    final calls = <List<String>>[];
    final api = FanqieApi(
      client: MockClient((request) async {
        expect(request.url.host, 'reading.snssdk.com');
        expect(request.url.path, '/reading/reader/batch_full/v/');
        expect(request.method, 'GET');
        expect(request.headers['x-argus'], isNotEmpty);
        expect(request.url.queryParameters['book_id'], bid);
        expect(request.url.queryParameters['req_type'], '0');
        expect(request.url.queryParameters['novel_text_type'], '1');
        expect(request.url.queryParameters['key_register_ts'], '17');
        final ids = request.url.queryParameters['item_ids']!.split(',');
        calls.add(ids);
        return ok({for (final id in ids.reversed) id: item(id)});
      }),
    );
    restore(api);
    addTearDown(api.close);
    final root = await Directory.systemTemp.createTemp('unr-fanqie-download-');
    addTearDown(() => root.delete(recursive: true));
    final sf = SfacgApi(
      client: MockClient((_) async => throw StateError('不应调用菠萝包')),
    );
    addTearDown(sf.close);
    final library = Library(
      root,
      SfacgSource(sf),
      novelSources: [FanqieSource(api)],
    );
    await library.downloadChapters(
      book,
      chapters,
      onProgress: (_, error) => expect(error, isNull),
    );
    expect(calls.map((ids) => ids.length), [30, 1]);
    final saved = await library.cachedContents(book);
    expect(saved.length, 31);
    for (final chapter in chapters) {
      final p = saved[chapter.id]!.paragraphs.single;
      expect(p.text, '正文 ${chapter.id}');
      expect(p.remoteId, 'version-1');
      expect(p.remoteIndex, 0);
    }
    await library.downloadChapters(
      book,
      chapters,
      onProgress: (_, error) => expect(error, isNull),
    );
    expect(calls.length, 2);
  });

  test('仅重试密钥过期章节一次，其他章节按原密钥解压，不重试缺失或无权限章节', () async {
    final oldKey = List.filled(16, 7),
        newKey = List.filled(16, 9),
        iv = List.filled(16, 3);
    final ids = chapters.take(4).map((c) => c.id).toList();
    final batches = <List<String>>[];
    var registrations = 0;
    final api = FanqieApi(
      client: MockClient((request) async {
        if (request.url.path == '/reading/crypt/registerkey') {
          registrations++;
          return ok({
            'key_register_ts': 29,
            'key': base64Encode([
              ...iv,
              ...FanqieCrypto.aes(
                newKey,
                FanqieCrypto.hex('ac25c67ddd8f38c1b37a2348828e222e'),
                iv,
              ),
            ]),
          });
        }
        final requested = request.url.queryParameters['item_ids']!.split(',');
        batches.add(requested);
        if (batches.length == 1) {
          return ok({
            ids[0]: item(ids[0], key: oldKey),
            ids[1]: {...item(ids[1]), 'crypt_status': 2},
            ids[3]: {...item(ids[3]), 'code_i32': 403},
          });
        }
        expect(requested, [ids[1]]);
        expect(request.url.queryParameters['key_register_ts'], '29');
        return ok({ids[1]: item(ids[1], key: newKey)});
      }),
    );
    restore(api, key: oldKey);
    addTearDown(api.close);
    final results = await FanqieSource(
      api,
    ).readChapterBatch(book, chapters.take(4).toList());
    expect(results.take(2).every((r) => r.content != null), isTrue);
    expect(results.skip(2).every((r) => r.error is SourceException), isTrue);
    expect(batches.length, 2);
    expect(registrations, 1);
    expect(api.app.toJson()['keyRegisterTs'], 29);
  });

  test('批量响应中错书、错章、试读及不完整正文逐章失败，不影响正常章节', () async {
    final changes = <String, dynamic>{
      chapters[0].id: item(chapters[0].id, bookId: '7143038691944959012'),
      chapters[1].id: item(chapters[2].id),
      chapters[2].id: {...item(chapters[2].id), 'is_preview': true},
      chapters[3].id: {...item(chapters[3].id), 'paragraphs_num': 20},
      chapters[4].id: item(chapters[4].id),
    };
    final api = FanqieApi(client: MockClient((_) async => ok(changes)));
    restore(api);
    addTearDown(api.close);
    final results = await FanqieSource(
      api,
    ).readChapterBatch(book, chapters.take(5).toList());
    expect(results.take(4).every((r) => r.error is SourceException), isTrue);
    expect(
      results.last.content!.paragraphs.single.text,
      '正文 ${chapters[4].id}',
    );
  });

  test('带空图片说明的 App 正文可单章读取和批量下载，保留原始段落编号', () async {
    final chapter = chapters.first;
    final paths = <String>[];
    final data = {
      ...item(chapter.id),
      'paragraphs_num': 4,
      'content':
          '<p idx="0">插图前正文</p>'
          '<div data-fanqie-type="image" idx="30001" p_idx="40000">'
          '<p class="picture" group-id="2" idx="20001" p_idx="30001">'
          '<img src="https://example.com/illustration.jpg"/></p>'
          '<p class="pictureDesc" group-id="2" p_idx="30001"></p></div>'
          '<p idx="1">插图后正文</p>',
    };
    final api = FanqieApi(
      client: MockClient((request) async {
        paths.add(request.url.path);
        switch (request.url.path) {
          case '/reading/reader/full/v/':
            return ok(data);
          case '/reading/reader/batch_full/v/':
            return ok({chapter.id: data});
          default:
            throw StateError('不应调用其他接口');
        }
      }),
    );
    restore(api);
    addTearDown(api.close);
    final source = FanqieSource(api);
    final single = await source.readChapter(book, chapter);
    final batch = await source.readChapterBatch(book, [chapter]);
    expect(batch.single.error, isNull);
    for (final content in [single, batch.single.content!]) {
      expect(content.paragraphs.map((p) => p.text), ['插图前正文', '', '插图后正文']);
      expect(
        content.paragraphs[1].image,
        'https://example.com/illustration.jpg',
      );
      expect(content.paragraphs.map((p) => p.remoteIndex), [0, 20001, 1]);
      expect(
        content.paragraphs.map((p) => p.remoteId),
        everyElement('version-1'),
      );
    }
    expect(paths, ['/reading/reader/full/v/', '/reading/reader/batch_full/v/']);
  });

  test('批量请求过程中切换账号时拒绝缓存返回结果', () async {
    late FanqieApi api;
    api = FanqieApi(
      client: MockClient((_) async {
        api.setCookie('sessionid=changed');
        return ok({chapters.first.id: item(chapters.first.id)});
      }),
    );
    restore(api);
    addTearDown(api.close);
    await expectLater(
      FanqieSource(api).readChapterBatch(book, [chapters.first]),
      throwsA(isA<SourceException>()),
    );
  });
}
