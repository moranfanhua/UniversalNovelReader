import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_crypto.dart';
import 'package:unr/sources/qidian/qidian_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

const device = 'aabbccddeeff001122334455667788990000';
const chapter = Chapter(id: '12345', title: '插图');
const book = Book(
  id: '12',
  source: 'qidian',
  title: '合成作品',
  author: '测试',
  chapters: [chapter],
);
const images = [
  {
    'Type': 'image',
    'Attach': 0,
    'Sort': 2,
    'Url': 'https://example.test/2.png',
  },
  {
    'Type': 'image',
    'Attach': 0,
    'Sort': 1,
    'Url': 'https://example.test/1.png',
  },
];

// Synthetic App binary response; no account data or copyrighted book contents.
http.Response chapterResponse(
  Map<String, dynamic> payload, {
  List<Map<String, Object>> blocks = images,
  String userId = '0',
}) {
  final first = base64Encode(
    crypto.Hmac(crypto.sha1, utf8.encode(device))
        .convert(
          utf8.encode(
            '$userId$device${chapter.id}2EEE1433A152E84B3756301D8FA3E69A',
          ),
        )
        .bytes,
  ).substring(0, 24);
  final second = base64Encode(
    crypto.Hmac(
      crypto.md5,
      utf8.encode(userId),
    ).convert(utf8.encode('$first$device')).bytes,
  );
  final encrypted = QidianCrypto.des(
    QidianCrypto.des(utf8.encode(jsonEncode(payload)), first),
    second,
  );
  final parts = [
    <int>[],
    encrypted,
    <int>[],
    <int>[0, 0, 0, 0],
    utf8.encode(jsonEncode(blocks)),
  ];
  final bytes = BytesBuilder();
  for (final part in parts) {
    bytes.add(
      (ByteData(
        4,
      )..setUint32(0, part.length, Endian.little)).buffer.asUint8List(),
    );
    bytes.add(part);
  }
  return http.Response.bytes(bytes.takeBytes(), 200);
}

http.Response ok(Object data) => http.Response.bytes(
  utf8.encode(jsonEncode({'Result': 0, 'Data': data})),
  200,
);

void main() {
  for (final text in ['', ' \r\n\t ', null]) {
    test('纯插图章节（Content=${jsonEncode(text)}）可下载、缓存并离线重读', () async {
      final root = await Directory.systemTemp.createTemp('unr-qidian-images-');
      addTearDown(() => root.delete(recursive: true));
      var offline = false, chapterRequests = 0, imageRequests = 0;
      final api = QidianApi(
        device: device,
        client: MockClient((r) async {
          chapterRequests++;
          if (offline) throw const SocketException('离线');
          expect(r.url.path, '/argus/api/v2/bookcontent/safegetcontent');
          return chapterResponse({'Content': text});
        }),
      );
      addTearDown(api.close);
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1QAAAAASUVORK5CYII=',
      );
      final imageApi = SfacgApi(
        client: MockClient((r) async {
          imageRequests++;
          if (offline) throw const SocketException('离线');
          expect(r.url.host, 'example.test');
          return http.Response.bytes(png, 200);
        }),
      );
      addTearDown(imageApi.close);
      final source = QidianSource(api), defaultSource = SfacgSource(imageApi);
      final library = Library(root, defaultSource, novelSources: [source]);
      addTearDown(library.dispose);
      await library.updateBook(book);
      final content = await library.read(book, chapter);
      expect(content.paragraphs.map((p) => p.image), [
        'https://example.test/1.png',
        'https://example.test/2.png',
      ]);
      expect(content.paragraphs.every((p) => p.text.isEmpty), isTrue);
      await library.cacheImages(book, content);
      offline = true;
      final reopened = await Library.open(
        defaultSource,
        directory: root,
        novelSources: [source],
      );
      addTearDown(reopened.dispose);
      final cached = await reopened.read(book, chapter);
      expect(cached.toJson(), content.toJson());
      for (final p in cached.paragraphs) {
        expect(await reopened.loadImage(book, p.image!), png);
      }
      expect(chapterRequests, 1);
      expect(imageRequests, 2);
    });
  }

  for (final type in [0, 1]) {
    test('已购 VIP 纯插图章节（type=$type）不要求存在加密文字', () async {
      final paths = <String>[];
      final api =
          QidianApi(
              device: device,
              client: MockClient((r) async {
                paths.add(r.url.path);
                if (r.url.path ==
                    '/argus/api/v2/subscription/getboughtchapterlist') {
                  return ok([12345]);
                }
                expect(r.url.path, '/argus/api/v4/bookcontent/getvipcontent');
                return chapterResponse({
                  'content': '',
                  'type': type,
                }, userId: '10');
              }),
            )
            ..credentials = QidianCredentials(
              userId: '10',
              ywGuid: '20',
              ywKey: 'synthetic',
              token: 'synthetic',
            );
      addTearDown(api.close);
      const vip = Chapter(id: '12345', title: '插图', vip: true);
      final vipBook = Book(
        id: book.id,
        source: book.source,
        title: book.title,
        author: book.author,
        chapters: [vip],
      );
      final content = await QidianSource(api).readChapter(vipBook, vip);
      expect(content.paragraphs.length, 2);
      expect(paths, [
        '/argus/api/v2/subscription/getboughtchapterlist',
        '/argus/api/v4/bookcontent/getvipcontent',
      ]);
    });
  }

  test('空正文缺少有效插图时仍拒绝，未知加密类型不会因有插图而跳过校验', () async {
    final invalid = [
      chapterResponse({'Content': ''}, blocks: []),
      chapterResponse({'Content': ' \n\t'}, blocks: []),
      chapterResponse({'Content': '', 'type': 99}),
      chapterResponse({'Content': 123}),
      chapterResponse(
        {'Content': ''},
        blocks: [
          {'Type': 'image', 'Attach': 0, 'Url': 'file:///missing.png'},
        ],
      ),
    ];
    for (final response in invalid) {
      final api = QidianApi(
        device: device,
        client: MockClient((_) async => response),
      );
      addTearDown(api.close);
      await expectLater(
        QidianSource(api).readChapter(book, chapter),
        throwsA(isA<SourceException>()),
      );
    }
  });

  test('VIP 带插图但加密文字损坏时仍拒绝返回不完整章节', () async {
    final key = jsonDecode(
      File('test/fixtures/qidian_fock.json').readAsStringSync(),
    )['key'];
    final paths = <String>[];
    final api =
        QidianApi(
            device: device,
            client: MockClient((r) async {
              paths.add(r.url.path);
              switch (r.url.path) {
                case '/argus/api/v2/subscription/getboughtchapterlist':
                  return ok([12345]);
                case '/argus/api/v4/bookcontent/getvipcontent':
                  return chapterResponse({
                    'content': 'broken-fock-content',
                    'type': 1,
                  }, userId: '10');
                case '/argus/api/v4/bookcontent/getkey':
                  return ok(key);
                default:
                  throw StateError('Unexpected request');
              }
            }),
          )
          ..credentials = QidianCredentials(
            userId: '10',
            ywGuid: '20',
            ywKey: 'synthetic',
            token: 'synthetic',
          );
    addTearDown(api.close);
    const vip = Chapter(id: '12345', title: '插图', vip: true);
    const vipBook = Book(
      id: '12',
      source: 'qidian',
      title: '合成作品',
      author: '测试',
      chapters: [vip],
    );
    await expectLater(
      QidianSource(api).readChapter(vipBook, vip),
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          'decrypt',
          contains('解密失败'),
        ),
      ),
    );
    expect(paths, [
      '/argus/api/v2/subscription/getboughtchapterlist',
      '/argus/api/v4/bookcontent/getvipcontent',
      '/argus/api/v4/bookcontent/getkey',
    ]);
  });

  final updates = <(Object?, Object?, int?)>[
    (1000, 2000, 2000),
    (3000, 2000, 3000),
    (null, '4000', 4000),
    ('invalid', 5000, 5000),
    (6000, 'invalid', 6000),
    (0, -1, null),
    (null, null, null),
  ];
  for (final (regular, vip, expected) in updates) {
    test('作品更新时间取有效的最新章节时间（普通=$regular，VIP=$vip）', () async {
      final api = QidianApi(
        client: MockClient((r) async {
          if (r.url.path == '/argus/api/v3/bookdetail/get') {
            return ok({
              'BaseBookInfo': {
                'BookId': 12,
                'BookName': '合成作品',
                'ChapterInfo': {
                  'LastChapterUpdateTime': regular,
                  'LastVipChapterUpdateTime': vip,
                },
              },
            });
          }
          expect(r.url.path, '/argus/api/v3/chapterlist/chapterlist');
          return ok({
            'BookId': 12,
            'Volumes': [
              {'VolumeCode': 200},
            ],
            'Chapters': [
              {'C': 12345, 'N': '插图', 'O': 1, 'Vc': 200},
            ],
          });
        }),
      );
      addTearDown(api.close);
      final result = await QidianSource(api).getBook('12');
      expect(
        result.updatedAt,
        expected == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(expected, isUtc: true),
      );
    });
  }
}
