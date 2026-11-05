import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/app_log.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/novel_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_auth.dart';
import 'package:unr/sources/qidian/qidian_cache.dart';
import 'package:unr/sources/qidian/qidian_session.dart';
import 'package:unr/sources/qidian/qidian_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/log_entry.dart';

import 'qidian_download_test.dart' as download;
import 'qidian_source_regression_test.dart' as binary;

http.Response response(Object? data, {int code = 0}) => http.Response.bytes(
  utf8.encode(jsonEncode({'Result': code, 'Data': data})),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HTTP 200 风控记录阶段与业务码，暂停其他操作且不清除或泄露会话', () async {
    await AppLog.instance.clear();
    var now = DateTime.utc(2026, 10, 19);
    var requests = 0;
    final api = QidianApi(
      clock: () => now,
      client: MockClient((_) async {
        requests++;
        return requests == 1
            ? response({'private': 'synthetic-secret'}, code: -4403)
            : response({});
      }),
    )..credentials = download.session();
    addTearDown(api.close);
    final session = api.credentials;
    await expectLater(
      api.request('/argus/newapi/v1/bookcontent/getcontentbatch', {
        'b': '12',
        'c': '12345',
        'useImei': '0',
      }, post: true),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(api.credentials, same(session));
    await expectLater(
      api.checkSession(),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    api.credentials = download.session();
    await expectLater(
      QidianAuth(api).sendCode('13800138000'),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(requests, 1);
    final log = (await AppLog.instance.snapshot()).text;
    final rejection = parseLogEntries(
      log,
    ).entries.singleWhere((e) => e.event == 'qidian.batch_rejected');
    expect(rejection.httpStatus, 200);
    expect(rejection.code, -4403);
    expect(rejection.message, '起点批量下载请求被拒绝');
    for (final secret in [
      'synthetic-secret',
      session!.ywKey,
      session.token,
      '13800138000',
    ]) {
      expect(log, isNot(contains(secret)));
    }
    now = now.add(QidianApi.riskPause);
    expect(requests, 1); // No timer or automatic retry at the deadline.
    await api.request('/argus/api/v3/bookdetail/get', {'bookId': '12'});
    expect(requests, 2);
  });

  test('201 章在首批风控后停止，仅报告已启动批次且原缓存仍可读', () async {
    var requests = 0;
    final api = QidianApi(
      client: MockClient((_) async {
        requests++;
        return response(null, code: -4403);
      }),
    );
    final fallback = SfacgApi(
      client: MockClient((_) async => fail('不应访问其他书源')),
    );
    final root = await Directory.systemTemp.createTemp('unr-qidian-risk-');
    final library = Library(
      root,
      SfacgSource(fallback),
      novelSources: [QidianSource(api)],
    );
    addTearDown(() async {
      library.dispose();
      api.close();
      fallback.close();
      await root.delete(recursive: true);
    });
    final chapters = List.generate(
      201,
      (i) => Chapter(id: '${i + 1}', title: '合成章节'),
    );
    final book = Book(
      id: '12',
      source: 'qidian',
      title: '合成作品',
      author: '测试',
      chapters: chapters,
    );
    await library.store(
      book,
      chapters.last,
      const ChapterContent([Paragraph('原缓存')]),
    );
    final completed = <String>[];
    await expectLater(
      library.downloadChapters(
        book,
        chapters,
        onProgress: (chapter, error) {
          completed.add(chapter.id);
          expect(error, isA<SourceAccessRestrictedException>());
        },
      ),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(requests, 1);
    expect(completed.length, 100);
    expect(
      (await library.read(book, chapters.last)).paragraphs.single.text,
      '原缓存',
    );
    await expectLater(
      library.downloadChapters(
        book,
        chapters.take(100).toList(),
        onProgress: (_, _) {},
      ),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(requests, 1);
  });

  test('VIP 权限检查风控不继续下载同批免费章节', () async {
    final paths = <String>[];
    final api = QidianApi(
      client: MockClient((r) async {
        paths.add(r.url.path);
        return response(null, code: -4403);
      }),
    )..credentials = download.session();
    addTearDown(api.close);
    await expectLater(
      QidianSource(api).readChapterBatch(download.book, download.chapters),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(paths, ['/argus/api/v2/subscription/getboughtchapterlist']);
  });

  test('密钥风控不下载 ZIP，独立操作也不能继续发请求', () async {
    final h = download.DownloadFixture();
    final paths = <String>[];
    final api = QidianApi(
      device: h.fock['device'],
      client: MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path.endsWith('/getkey')) return response(null, code: -4403);
        return h.respond(r);
      }),
    )..credentials = download.session();
    addTearDown(api.close);
    addTearDown(h.api.close);
    final source = QidianSource(api);
    final results = await source.readChapterBatch(
      download.book,
      download.chapters.take(2).toList(),
    );
    expect(
      results.every((r) => r.error is SourceAccessRestrictedException),
      isTrue,
    );
    expect(paths.any((p) => p.endsWith('.zip')), isFalse);
    await expectLater(
      api.checkSession(),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(paths.length, 3);
  });

  test('二进制正文中的业务风控也停止后续访问', () async {
    var calls = 0;
    final api = QidianApi(
      device: binary.device,
      client: MockClient((_) async {
        calls++;
        return binary.chapterResponse({'code': -4403});
      }),
    );
    addTearDown(api.close);
    final source = QidianSource(api);
    await expectLater(
      source.readChapter(binary.book, binary.chapter),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    await expectLater(
      source.readChapter(binary.book, binary.chapter),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(calls, 1);
  });

  test('SDK 返回风控时与正文共用暂停状态，不重发短信', () async {
    var calls = 0;
    final api = QidianApi(
      client: MockClient((_) async {
        calls++;
        return http.Response('{"code":-4403}', 200);
      }),
    );
    addTearDown(api.close);
    await expectLater(
      QidianAuth(api).sendCode('13800138000'),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    await expectLater(
      api.request('/argus/api/v3/bookdetail/get', {}),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(calls, 1);
  });

  test('两批复用密钥与已购列表，订阅确认及缓存失效仍实时取权限', () async {
    final h = download.DownloadFixture();
    addTearDown(h.api.close);
    for (var i = 0; i < 2; i++) {
      final results = await h.source.readChapterBatch(
        download.book,
        download.chapters.take(2).toList(),
      );
      expect(results.every((r) => r.error == null), isTrue);
    }
    expect(h.paths.where((p) => p.endsWith('/getkey')).length, 1);
    expect(h.paths.where((p) => p.endsWith('/getboughtchapterlist')).length, 1);
    h.bought = [12347, 12348];
    expect(await h.api.ownedChapters('12', refresh: true), {'12347', '12348'});
    h.api.credentials = download.session();
    await h.api.readingKey('12');
    await h.api.ownedChapters('12');
    expect(h.paths.where((p) => p.endsWith('/getkey')).length, 2);
    expect(h.paths.where((p) => p.endsWith('/getboughtchapterlist')).length, 3);
  });

  test('密钥和权限分别过期，失败响应不进入缓存', () async {
    final key = download.fixture('qidian_fock')['key'];
    var now = DateTime.utc(2026, 10, 19);
    var keys = 0, owned = 0;
    var failKey = true;
    final api = QidianApi(
      clock: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/getkey')) {
          keys++;
          return failKey ? response(null, code: -1) : response(key);
        }
        owned++;
        return response([12347]);
      }),
    )..credentials = download.session();
    addTearDown(api.close);
    await expectLater(api.readingKey('12'), throwsA(isA<SourceException>()));
    failKey = false;
    await Future.wait([api.readingKey('12'), api.readingKey('12')]);
    await Future.wait([api.ownedChapters('12'), api.ownedChapters('12')]);
    expect(keys, 2);
    expect(owned, 1);
    now = now.add(const Duration(minutes: 1));
    await api.readingKey('12');
    await api.ownedChapters('12');
    expect(keys, 2);
    expect(owned, 2);
    now = now.add(const Duration(minutes: 9));
    await api.readingKey('12');
    expect(keys, 3);
  });

  test('缓存密钥不匹配时使其失效，不自动重取正文或密钥，手动重试可恢复', () async {
    final h = download.DownloadFixture();
    var keyCalls = 0, batches = 0;
    final api = QidianApi(
      device: h.fock['device'],
      client: MockClient((r) async {
        if (r.url.path.endsWith('/getkey')) {
          keyCalls++;
          return response({
            ...h.fock['key'] as Map,
            if (keyCalls == 1) 'Version': '999',
          });
        }
        if (r.url.path.endsWith('/getcontentbatch')) batches++;
        return h.respond(r);
      }),
    )..credentials = download.session();
    addTearDown(api.close);
    addTearDown(h.api.close);
    final source = QidianSource(api);
    final selected = download.chapters.take(2).toList();
    final failed = await source.readChapterBatch(download.book, selected);
    expect(failed.every((r) => r.error is SourceException), isTrue);
    expect(keyCalls, 1);
    expect(batches, 1);
    final retried = await source.readChapterBatch(download.book, selected);
    expect(retried.every((r) => r.error == null), isTrue);
    expect(keyCalls, 2);
    expect(batches, 2);
  });

  test('旧会话的迟到权限结果不写入新账号缓存', () async {
    final gate = Completer<http.Response>();
    var calls = 0;
    final api = QidianApi(
      client: MockClient((_) async {
        calls++;
        return calls == 1 ? gate.future : response([12348]);
      }),
    )..credentials = download.session();
    addTearDown(api.close);
    final old = api.ownedChapters('12');
    final oldCheck = expectLater(old, throwsA(isA<SourceException>()));
    api.credentials = download.session();
    expect(await api.ownedChapters('12'), {'12348'});
    gate.complete(response([12347]));
    await oldCheck;
    expect(await api.ownedChapters('12'), {'12348'});
    expect(calls, 2);
  });

  test('读取缓存失效后，旧请求不覆盖新值，也不移除新请求', () async {
    final cache = QidianCache<int>(
      lifetime: const Duration(minutes: 1),
      clock: DateTime.now,
    );
    final first = Completer<int>(), second = Completer<int>();
    final old = cache.get('12', () => first.future);
    final fresh = cache.get('12', () => second.future, refresh: true);
    first.complete(1);
    expect(await old, 1);
    final joined = cache.get('12', () async => fail('必须合并到新请求'));
    second.complete(2);
    expect(await fresh, 2);
    expect(await joined, 2);
    expect(await cache.get('12', () async => 3), 2);
  });

  test('搜索补查复用短时缓存，显式作品更新绕过缓存', () async {
    var details = 0;
    var now = DateTime.utc(2026, 10, 19);
    final api = QidianApi(
      clock: () => now,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/searchbooks')) {
          return response({
            'CardList': [
              {
                'Body': [
                  {
                    'ItemData': {
                      'BookId': 12,
                      'BookName': '合成作品',
                      'BookType': 1,
                    },
                  },
                ],
              },
            ],
          });
        }
        details++;
        return response({
          'BaseBookInfo': {
            'BookId': 12,
            'BookName': '合成作品',
            'BssRecomTotal': details,
          },
        });
      }),
    );
    addTearDown(api.close);
    final source = QidianSource(api);
    expect((await source.search('合成')).single.favoriteCount, 1);
    expect((await source.search('其他')).single.favoriteCount, 1);
    expect((await source.getBookUpdate('12')).favoriteCount, 2);
    now = now.add(const Duration(minutes: 10));
    expect((await source.search('合成')).single.favoriteCount, 3);
    expect(details, 3);
  });

  test('匿名首次使用立即持久化设备标识，恢复损坏存储时不覆盖原数据', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final first = await QidianSession.open();
    final second = await QidianSession.open();
    addTearDown(first.close);
    addTearDown(second.close);
    expect(first.device, second.device);
    expect(second.credentials, isNull);
    FlutterSecureStorage.setMockInitialValues({
      QidianSession.key: 'corrupt-original',
    });
    final failed = await QidianSession.open();
    addTearDown(failed.close);
    expect(
      await const FlutterSecureStorage().read(key: QidianSession.key),
      'corrupt-original',
    );
  });

  test('搜索补查遇到风控停止后续详情请求，保留已成功获得的搜索结果', () async {
    var calls = 0;
    final api = QidianApi(
      client: MockClient((r) async {
        calls++;
        if (!r.url.path.endsWith('/searchbooks')) {
          return response(null, code: -4403);
        }
        return response({
          'CardList': [
            {
              'Body': List.generate(
                20,
                (i) => {
                  'ItemData': {
                    'BookId': i + 1,
                    'BookName': '合成作品',
                    'BookType': 1,
                  },
                },
              ),
            },
          ],
        });
      }),
    );
    addTearDown(api.close);
    expect((await QidianSource(api).search('合成')).length, 20);
    expect(calls, 2);
  });
}
