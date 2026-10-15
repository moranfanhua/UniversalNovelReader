import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_fock.dart';
import 'package:unr/sources/qidian/qidian_source.dart';

// Independently generated synthetic vectors were accepted by official Android
// 7.9.480 libfock (all nine cipher pairs and character restoration). They contain
// no real account credentials, reading keys or novel contents.
Map<String, dynamic> fixture() =>
    jsonDecode(File('test/fixtures/qidian_fock.json').readAsStringSync());
QidianCredentials session() => QidianCredentials(
  userId: '123456',
  ywGuid: '654321',
  ywKey: 'synthetic-sdk-key',
  token: 'synthetic-reader-token',
);
http.Response ok(Object data) =>
    http.Response(jsonEncode({'Result': 0, 'Data': data}), 200);
Book book() => Book(
  id: '12',
  source: 'qidian',
  title: '合成作品',
  author: '测试',
  chapters: [Chapter(id: '12347', title: '合成付费章节', vip: true)],
);

void main() {
  final data = fixture();
  String decode(String content, {String? device, String? cid, Map? key}) =>
      QidianFock.decode(
        content,
        chapterId: cid ?? data['chapterId'],
        device: device ?? data['device'],
        readingKey: QidianReadingKey.fromJson(
          Map<String, dynamic>.from(key ?? data['key']),
        ),
      );
  for (final vector in data['vectors']) {
    test('FOCK ${vector['algorithm']}：正文、嵌入头部与官方结果一致', () {
      expect(decode(vector['content']), vector['text']);
    });
  }
  test('FOCK 拒绝损坏、截断、其他设备/章节及过期版本的密钥', () {
    final vector = data['vectors'][7];
    final bytes = base64Decode(vector['content']);
    for (final content in [
      '',
      'not-base64',
      base64Encode(bytes.sublist(0, 255)),
      base64Encode(bytes.sublist(0, bytes.length - 1)),
      base64Encode([...bytes.take(bytes.length - 1), bytes.last ^ 1]),
      base64Encode([...bytes.take(32), bytes[32] ^ 1, ...bytes.skip(33)]),
    ]) {
      expect(() => decode(content), throwsA(isA<SourceException>()));
    }
    expect(
      () => decode(vector['content'], device: 'b' * 36),
      throwsA(isA<SourceException>()),
    );
    expect(
      () => decode(vector['content'], cid: '12348'),
      throwsA(isA<SourceException>()),
    );
    expect(
      () => decode(vector['content'], key: {...data['key'], 'Version': 1}),
      throwsA(isA<SourceException>()),
    );
  });
  test('已购确认后才调用 App VIP 下载与密钥接口，完整正文可读', () async {
    final paths = <String>[];
    final api = QidianApi(
      device: data['device'],
      client: MockClient((r) async {
        expect(r.url.host, 'druidv6.if.qidian.com');
        expect(r.headers['Cookie'], contains('synthetic-reader-token'));
        expect(r.followRedirects, isFalse);
        paths.add(r.url.path);
        switch (r.url.path) {
          case '/argus/api/v2/subscription/getboughtchapterlist':
            expect(r.method, 'POST');
            expect(r.bodyFields, {'bookId': '12'});
            return ok([12347]);
          case '/argus/api/v4/bookcontent/getvipcontent':
            expect(r.method, 'POST');
            expect(r.bodyFields, {
              'b': '12',
              'c': '12347',
              'ui': '0',
              'b-string': '',
            });
            return http.Response.bytes(base64Decode(data['chapter']), 200);
          case '/argus/api/v4/bookcontent/getkey':
            expect(r.method, 'GET');
            expect(r.url.queryParameters, {'bookId': '12', 'ui': '0'});
            return ok(data['key']);
          default:
            throw StateError('Unexpected request');
        }
      }),
    )..credentials = session();
    addTearDown(api.close);
    final b = book();
    final result = await QidianSource(api).readChapter(b, b.chapters.single);
    expect(result.paragraphs.length, 20);
    expect(result.paragraphs.first.text, '测试付费段落。');
    expect(paths, [
      '/argus/api/v2/subscription/getboughtchapterlist',
      '/argus/api/v4/bookcontent/getvipcontent',
      '/argus/api/v4/bookcontent/getkey',
    ]);
  });
  for (final payload in [[], null, 'invalid']) {
    test('未购或权限列表无效（$payload）时不下载、不购买、不取密钥', () async {
      var calls = 0;
      final api = QidianApi(
        client: MockClient((r) async {
          calls++;
          expect(r.url.path, '/argus/api/v2/subscription/getboughtchapterlist');
          return ok(payload ?? {});
        }),
      )..credentials = session();
      addTearDown(api.close);
      final b = book();
      // A caller cannot bypass the directory's VIP flag.
      await expectLater(
        QidianSource(api).readChapter(
          b,
          Chapter(id: b.chapters.single.id, title: '', vip: false),
        ),
        throwsA(isA<SourceException>()),
      );
      expect(calls, 1);
    });
  }
  test('权限检查时账号切换会终止旧账号请求', () async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final api = QidianApi(
      client: MockClient((_) {
        calls++;
        return pending.future;
      }),
    )..credentials = session();
    addTearDown(api.close);
    final b = book();
    final result = QidianSource(api).readChapter(b, b.chapters.single);
    final expectation = expectLater(
      result,
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          'account change',
          contains('账号已切换'),
        ),
      ),
    );
    api.credentials = null;
    pending.complete(ok([12347]));
    await expectation;
    expect(calls, 1);
  });
}
