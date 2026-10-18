import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/novel_search.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_crypto.dart';
import 'package:unr/sources/qidian/qidian_source.dart';

const device = 'aabbccddeeff001122334455667788990000';
Map<String, dynamic> fixture() =>
    jsonDecode(File('test/fixtures/qidian_protocol.json').readAsStringSync())
        as Map<String, dynamic>;
http.Response ok(Object data) => http.Response(
  jsonEncode({'Result': 0, 'Data': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Map<String, dynamic> directory() => {
  'BookId': 12,
  'Volumes': [
    {'VolumeCode': '200', 'VolumeName': '第一卷'},
    {'VolumeCode': '80000', 'VolumeName': '第二卷'},
  ],
  'Chapters': [
    {'C': -10000, 'N': '版权', 'O': 0, 'Vc': '200'},
    {'C': 12346, 'N': '第二章', 'O': 2000, 'Vc': '200', 'V': 0, 'W': 100},
    {'C': 12345, 'N': '第一章', 'O': 1000, 'Vc': '200', 'V': 0, 'W': 200},
    {'C': 12347, 'N': '第三章', 'O': 1000, 'Vc': '80000', 'V': 1, 'W': 300},
  ],
};

void main() {
  test('App 请求签名与独立协议向量一致；SDK DES 与官方 APK 向量一致', () {
    final data = fixture();
    final headers = QidianCrypto.headers(
      Map<String, String>.from(data['parameters']),
      device: device,
      timestamp: data['timestamp'],
    );
    expect(headers['QDSign']!.replaceAll(' ', ''), data['signature']);
    expect(
      QidianCrypto.des(
        utf8.encode(data['sdkInput']),
        'sewxf03hhz3ew9qcCXMHiDMk',
        iv: 'sh331nt1',
      ),
      base64Decode(data['sdkCipher']),
    );
    expect(
      QidianCrypto.headers(
        {'PAGEINDEX': '1', 'keyword': '中文'},
        device: device,
        timestamp: 1,
      )['QDSign'],
      QidianCrypto.headers(
        {'keyword': '中文', 'pageIndex': '1'},
        device: device,
        timestamp: 1,
      )['QDSign'],
    );
    expect(headers.containsKey('Cookie'), isFalse);
  });

  test('独立生成的双层正文解密向量；损坏、截断和其他设备不能产生成功正文', () {
    final bytes = base64Decode(fixture()['chapter']);
    Map<String, dynamic> decode(Uint8List b, {String d = device}) =>
        QidianCrypto.decodeChapter(
          b,
          chapterId: '12345',
          device: d,
          userId: '0',
        );
    expect(decode(bytes)['Content'], '第一段。\r\r\n第二段。');
    for (final corrupted in [
      bytes.sublist(0, bytes.length - 1),
      Uint8List.fromList([...bytes, 0]),
      Uint8List.fromList([255, 255, 255, 127, ...bytes.skip(4)]),
    ]) {
      expect(() => decode(corrupted), throwsA(isA<SourceException>()));
    }
    expect(
      () => decode(bytes, d: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb0000'),
      throwsA(isA<SourceException>()),
    );
  });

  test('作品链接仅解析起点主机；同名其他平台、伪造域名及凭据 URL 不混用', () {
    expect(QidianSource.bookId('https://book.qidian.com/info/12/'), '12');
    expect(QidianSource.bookId('https://www.qidian.com/book/12/'), '12');
    for (final input in [
      '0',
      '-1',
      'https://qidian.com.evil.test/book/12/',
      'https://user:pass@qidian.com/book/12/',
      'https://fanqienovel.com/page/12',
      'https://qidian.com:9999/book/12/',
    ]) {
      expect(() => QidianSource.bookId(input), throwsA(isA<SourceException>()));
    }
  });

  test('权限期限取逗号分隔的最后时间；过期章节不返回正文', () {
    final bytes = base64Decode(fixture()['chapter']);
    Map<String, dynamic> decode(String expiry) {
      final encrypted = QidianCrypto.des(
        utf8.encode(expiry),
        '0821CAAD409B8402',
      );
      final length = ByteData(4)..setUint32(0, encrypted.length, Endian.little);
      return QidianCrypto.decodeChapter(
        Uint8List.fromList([
          ...length.buffer.asUint8List(),
          ...encrypted,
          ...bytes.skip(4),
        ]),
        chapterId: '12345',
        device: device,
        userId: '0',
      );
    }

    expect(decode('metadata,4102444800000')['Content'], contains('第一段'));
    expect(() => decode('metadata,1'), throwsA(isA<SourceException>()));
  });

  test('正文插图按 Attach、Sort 顺序保留，未知格式不能伪装为完整章节', () {
    final content = QidianSource.parseContent('第一段\r\r\n第二段', [
      {
        'Type': 'image',
        'Attach': 1,
        'Sort': 2,
        'Url': 'https://example.test/2.jpg',
      },
      {
        'Type': '1',
        'Attach': 1,
        'Sort': 1,
        'Url': 'https://example.test/1.jpg',
      },
      {'Type': 'image', 'Attach': 0, 'Url': 'https://example.test/cover.jpg'},
    ]);
    expect(content.paragraphs.map((p) => p.image ?? p.text), [
      'https://example.test/cover.jpg',
      '第一段',
      'https://example.test/1.jpg',
      'https://example.test/2.jpg',
      '第二段',
    ]);
    for (final blocks in [
      [
        {'Type': '2', 'Attach': 1, 'Url': 'https://example.test/video'},
      ],
      [
        {'Type': 'image', 'Attach': 99, 'Url': 'https://example.test/1.jpg'},
      ],
      [
        {'Type': 'image', 'Attach': 1, 'Url': 'file:///private/image'},
      ],
    ]) {
      expect(
        () => QidianSource.parseContent('段落', blocks),
        throwsA(isA<SourceException>()),
      );
    }
  });

  test('目录先按分卷再按卷内顺序，保留 VIP 与字数，移除版权伪章节', () {
    final chapters = QidianSource.parseDirectory(directory());
    expect(chapters.map((c) => c.id), ['12345', '12346', '12347']);
    expect(chapters.map((c) => c.volume), ['第一卷', '第一卷', '第二卷']);
    expect(chapters.last.vip, isTrue);
    expect(chapters.first.wordCount, 200);
    final repeated = directory();
    (repeated['Chapters'] as List).add((repeated['Chapters'] as List).last);
    expect(
      () => QidianSource.parseDirectory(repeated),
      throwsA(isA<SourceException>()),
    );
    final missingVolume = directory();
    missingVolume['Volumes'] = [];
    expect(
      () => QidianSource.parseDirectory(missingVolume),
      throwsA(isA<SourceException>()),
    );
  });

  test('搜索、详情、目录和免费正文只访问 App 接口，空目录参数保留等号', () async {
    final paths = <String>[];
    final api = QidianApi(
      device: device,
      client: MockClient((request) async {
        expect(request.url.host, 'druidv6.if.qidian.com');
        expect(request.followRedirects, isFalse);
        expect(request.headers['Cookie'], isNull);
        paths.add(request.url.path);
        switch (request.url.path) {
          case '/argus/api/v2/booksearch/searchbooks':
            expect(request.method, 'POST');
            expect(request.bodyFields['keyword'], '测试');
            expect(request.bodyFields['pageIndex'], '2');
            return ok({
              'CardList': [
                {
                  'Body': [
                    {
                      'ItemData': {
                        'BookId': 12,
                        'BookName': '作品',
                        'BookType': 1,
                        'AuthorName': '作者',
                      },
                    },
                    {
                      'ItemData': {
                        'BookId': 13,
                        'BookName': '有声书',
                        'BookType': 2,
                      },
                    },
                  ],
                },
              ],
            });
          case '/argus/api/v3/bookdetail/get':
            return ok({
              'BaseBookInfo': {
                'BookId': 12,
                'BookName': '作品',
                'WordsCnt': 600,
                'BssRecomTotal': 56534,
              },
              'AuthorInfo': {'Author': '作者'},
            });
          case '/argus/api/v3/chapterlist/chapterlist':
            expect(request.url.query, contains('md5Signature='));
            expect(request.url.query, contains('extendchapterIds='));
            return ok(directory());
          case '/argus/api/v2/bookcontent/safegetcontent':
            return http.Response.bytes(base64Decode(fixture()['chapter']), 200);
          default:
            throw StateError('Unexpected request');
        }
      }),
    );
    addTearDown(api.close);
    final source = QidianSource(api);
    final found = await source.search('测试', page: 1);
    expect(found.map((b) => b.key), ['qidian:12']);
    expect(found.single.favoriteCount, 56534);
    final book = await source.getBook('12');
    expect(book.key, 'qidian:12');
    expect(book.wordCount, 600);
    expect(book.favoriteCount, 56534);
    final content = await source.readChapter(book, book.chapters.first);
    expect(content.paragraphs.map((p) => p.text), ['第一段。', '第二段。']);
    final count = paths.length;
    await expectLater(
      source.readChapter(book, book.chapters.last),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.readChapter(
        Book(
          id: '12',
          title: '',
          author: '',
          source: 'sfacg',
          chapters: book.chapters,
        ),
        book.chapters.first,
      ),
      throwsA(isA<SourceException>()),
    );
    expect(paths.length, count);
  });

  test('搜索补查 BssRecomTotal 后按收藏排序，限制并发且单本失败不丢失结果', () async {
    final lookups = <String>[];
    var active = 0, peak = 0;
    final counts = <Object?>[56534, '273332', 0, -1, 'invalid', null];
    final api = QidianApi(
      client: MockClient((request) async {
        if (request.url.path == '/argus/api/v2/booksearch/searchbooks') {
          Map<String, dynamic> hit(int id, {int type = 1, Object? count}) => {
            'ItemData': {
              'BookId': id,
              'BookName': '魔女$id',
              'BookType': type,
              'BssRecomTotal': count,
              'WordsCount': 1000,
            },
          };
          return ok({
            'CardList': [
              {
                'Body': [
                  for (var i = 1; i <= 8; i++) hit(i),
                  hit(1),
                  hit(9, count: '100000'),
                  hit(10, type: 2),
                ],
              },
            ],
          });
        }
        expect(request.url.path, '/argus/api/v3/bookdetail/get');
        final bid = request.url.queryParameters['bookId']!;
        lookups.add(bid);
        active++;
        if (active > peak) peak = active;
        try {
          await Future<void>.delayed(Duration.zero);
          if (bid == '8') return http.Response('unavailable', 503);
          return ok({
            'BaseBookInfo': {
              'BookId': bid == '7' ? '999' : bid,
              'BookName': '魔女$bid',
              'BssRecomTotal': bid == '7'
                  ? 9999999
                  : counts[int.parse(bid) - 1],
              'RecommendAll': 9999999,
              'FansInfo': {'TotalFansCount': 9999999},
            },
          });
        } finally {
          active--;
        }
      }),
    );
    addTearDown(api.close);
    final result = await searchNovels([QidianSource(api)], '魔女');
    expect(result.failedSources, isEmpty);
    expect(result.books.map((b) => b.id), [
      '2',
      '9',
      '1',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
    ]);
    expect(result.books.map((b) => b.favoriteCount), [
      273332,
      100000,
      56534,
      0,
      null,
      null,
      null,
      null,
      null,
    ]);
    expect(result.books.every((b) => b.source == 'qidian'), isTrue);
    expect(result.books.every((b) => b.wordCount == 1000), isTrue);
    expect(lookups, unorderedEquals(['1', '2', '3', '4', '5', '6', '7', '8']));
    expect(peak, 4);
  });

  for (final value in <Object?>[0, '273332', -1, 'invalid', null]) {
    test('详情收藏解析保留零并将无效值视为未知：$value', () async {
      final api = QidianApi(
        client: MockClient((request) async {
          expect(request.headers['Cookie'], isNull);
          if (request.url.path == '/argus/api/v3/chapterlist/chapterlist') {
            return ok(directory());
          }
          return ok({
            'BaseBookInfo': {
              'BookId': 12,
              'BookName': '作品',
              'BssRecomTotal': value,
              'RecommendAll': 9999999,
            },
          });
        }),
      );
      addTearDown(api.close);
      api.credentials = QidianCredentials(
        userId: '1',
        ywGuid: '2',
        ywKey: 'synthetic',
        token: 'synthetic',
      );
      final source = QidianSource(api);
      final book = await source.getBook('12');
      expect(
        book.favoriteCount,
        value == 0
            ? 0
            : value == '273332'
            ? 273332
            : null,
      );
      final update = await source.getBookUpdate('12');
      expect(update.favoriteCount, book.favoriteCount);
      expect(update.chapters, isEmpty);
    });
  }

  test('服务端失败、缺失正文和错误作品编号不会保存成功结果', () async {
    final client = MockClient(
      (r) async => ok({
        'BaseBookInfo': {'BookId': 99, 'BookName': '错误作品'},
      }),
    );
    final api = QidianApi(client: client);
    addTearDown(api.close);
    await expectLater(
      QidianSource(api).getBook('12'),
      throwsA(isA<SourceException>()),
    );
    expect(
      () => api.responseData(http.Response('<html>error</html>', 502)),
      throwsA(isA<SourceException>()),
    );
    expect(
      () => api.responseData(http.Response('{"Result":-2}', 200)),
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          'login',
          contains('重新登录'),
        ),
      ),
    );
  });
}
