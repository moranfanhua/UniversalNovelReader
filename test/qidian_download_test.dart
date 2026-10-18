import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_source.dart';

const chapters = [
  Chapter(id: '12345', title: '免费章节'),
  Chapter(id: '12347', title: '已购章节', vip: true),
  Chapter(id: '12348', title: '未购章节', vip: true),
];
const book = Book(
  id: '12',
  source: 'qidian',
  title: '合成作品',
  author: '测试',
  chapters: chapters,
);
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync());
http.Response ok(Object data) =>
    http.Response(jsonEncode({'Result': 0, 'Data': data}), 200);
QidianCredentials session() => QidianCredentials(
  userId: '123456',
  ywGuid: '654321',
  ywKey: 'synthetic-sdk-key',
  token: 'synthetic-reader-token',
);

class DownloadFixture {
  DownloadFixture() {
    api = QidianApi(device: fock['device'], client: MockClient(respond))
      ..credentials = session();
    source = QidianSource(api);
    files = [
      ArchiveFile('12_12345_0.qd', free.length, free),
      ArchiveFile('12_12347_123456.qd', vip.length, vip),
    ];
  }
  final data = fixture('qidian_download');
  final fock = fixture('qidian_fock');
  late final QidianApi api;
  late final QidianSource source;
  late List<ArchiveFile> files;
  List<int> get free => base64Decode(data['freeChapter']);
  List<int> get vip => base64Decode(fock['chapter']);
  final paths = <String>[];
  final requested = <String>[];
  Object bought = [12347];
  String? digest;
  bool changeAccount = false;
  int zipStatus = 200;

  List<int> get zip {
    final archive = Archive();
    for (final file in files) {
      archive.add(file);
    }
    return ZipEncoder().encode(archive);
  }

  Future<http.Response> respond(http.Request r) async {
    paths.add(r.url.path);
    expect(r.followRedirects, isFalse);
    if (r.url.host != 'druidv6.if.qidian.com') {
      expect(r.url.toString(), data['address']);
      expect(r.headers.containsKey('Cookie'), isFalse);
      expect(r.headers.containsKey('QDSign'), isFalse);
      expect(r.headers.containsKey('QDInfo'), isFalse);
      return http.Response.bytes(zip, zipStatus);
    }
    expect(r.headers['QDSign'], isNotEmpty);
    switch (r.url.path) {
      case '/argus/api/v2/subscription/getboughtchapterlist':
        expect(r.method, 'POST');
        return ok(bought);
      case '/argus/newapi/v1/bookcontent/getcontentbatch':
        expect(r.method, 'POST');
        expect(r.bodyFields.keys, unorderedEquals(['b', 'c', 'useImei']));
        expect(r.bodyFields['b'], '12');
        expect(r.bodyFields['useImei'], '0');
        requested.addAll(r.bodyFields['c']!.split(','));
        if (changeAccount) api.credentials = session();
        final bytes = zip;
        return ok({
          'DownloadUrl': data['downloadUrl'],
          'Key': 'synthetic-cache-label',
          'Md5': digest ?? md5.convert(bytes).toString(),
        });
      case '/argus/api/v4/bookcontent/getkey':
        return ok(fock['key']);
      default:
        fail('不应回退逐章读取或调用购买接口：${r.url.path}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DownloadFixture h;
  setUp(() {
    h = DownloadFixture();
    addTearDown(h.api.close);
  });

  test('起点按官方100章批量协议下载ZIP，已购检查和阅读密钥每批一次，不购买未购章节', () async {
    expect(h.source.chapterBatchSize, 100);
    final results = await h.source.readChapterBatch(book, chapters);
    expect(h.requested, ['12345', '12347']);
    expect(h.paths.where((p) => p.endsWith('getboughtchapterlist')).length, 1);
    expect(h.paths.where((p) => p.endsWith('getkey')).length, 1);
    expect(results[0].content!.paragraphs.first.text, '合成免费正文。');
    expect(results[1].content!.paragraphs.first.text, contains('测试付费段落'));
    expect(results[2].error, isA<SourceException>());
  });

  test('匿名与未购VIP不进入批量任务，空任务不请求密钥和ZIP', () async {
    h.api.credentials = null;
    var results = await h.source.readChapterBatch(
      book,
      chapters.skip(1).toList(),
    );
    expect(results.every((r) => r.error is SourceException), isTrue);
    expect(h.paths, isEmpty);
    h.api.credentials = session();
    h.bought = [];
    results = await h.source.readChapterBatch(book, chapters.skip(1).toList());
    expect(results.every((r) => r.error is SourceException), isTrue);
    expect(h.paths, ['/argus/api/v2/subscription/getboughtchapterlist']);
  });

  test('ZIP缺章或某章无法解密时逐章失败，其他完整正文仍成功', () async {
    h.files.removeLast();
    var results = await h.source.readChapterBatch(
      book,
      chapters.take(2).toList(),
    );
    expect(results.first.content, isNotNull);
    expect(results.last.error, isA<SourceException>());
    h.files.add(ArchiveFile('12_12347_1.qd', 4, [1, 2, 3, 4]));
    results = await h.source.readChapterBatch(book, chapters.take(2).toList());
    expect(results.first.content, isNotNull);
    expect(results.last.error, isA<SourceException>());
  });

  test('MD5失败、下载失败、重复章节及错书ZIP不能产生成功章节', () async {
    h.digest = '0' * 32;
    var results = await h.source.readChapterBatch(
      book,
      chapters.take(2).toList(),
    );
    expect(results.every((r) => r.error is SourceException), isTrue);
    h.digest = null;
    h.zipStatus = 503;
    results = await h.source.readChapterBatch(book, chapters.take(2).toList());
    expect(results.every((r) => r.error is SourceException), isTrue);
    h.zipStatus = 200;
    for (final name in [
      '12_12345_1.qd',
      '13_12345_0.qd',
      '../12_12345_0.qd',
      '12_12349_0.qd',
    ]) {
      h.files.add(ArchiveFile(name, h.free.length, h.free));
      results = await h.source.readChapterBatch(
        book,
        chapters.take(2).toList(),
      );
      expect(
        results.every((r) => r.error is SourceException),
        isTrue,
        reason: name,
      );
      h.files.removeLast();
    }
  });

  test('下载请求中切换账号时拒绝结果，不继续请求旧账号密钥和ZIP', () async {
    h.changeAccount = true;
    await expectLater(
      h.source.readChapterBatch(book, chapters.take(2).toList()),
      throwsA(isA<SourceException>()),
    );
    expect(h.paths.any((p) => p.endsWith('getkey')), isFalse);
  });

  test('批量ZIP请求不接受其他域名、明文或携带用户信息的地址', () async {
    for (final url in [
      'https://evil.example/file.zip',
      'http://a.myqcloud.com/file.zip',
      'https://user@a.myqcloud.com/file.zip',
      'https://a.myqcloud.com:8443/file.zip',
    ]) {
      await expectLater(
        h.api.downloadArchive(url, '0' * 32),
        throwsA(isA<SourceException>()),
      );
    }
    expect(h.paths, isEmpty);
  });
}
