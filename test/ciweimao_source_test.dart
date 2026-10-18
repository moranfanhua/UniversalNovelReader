import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_content.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/ciweimao/ciweimao_parser.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';

const first = Chapter(id: '101', title: '第一章');
const owned = Chapter(id: '102', title: '已购', vip: true);
const locked = Chapter(id: '103', title: '未购', vip: true);
const book = Book(
  id: '12',
  source: 'ciweimao',
  title: '合成作品',
  author: '测试',
  chapters: [first, owned, locked],
);
const command = 'synthetic-chapter-command';
http.Response ok(Object data) => http.Response(
  CiweimaoCrypto.encrypt(jsonEncode({'code': '100000', 'data': data})),
  200,
);
CiweimaoApi apiWith(
  Future<http.Response> Function(http.Request) handler, {
  bool guest = false,
}) => CiweimaoApi(client: MockClient(handler))
  ..restoreSession(
    CiweimaoCredentials(
      account: 'synthetic-account',
      token: 'synthetic-token-1234',
      readerId: '106',
      guest: guest,
    ),
  );
Map<String, dynamic> info({String id = '12'}) => {
  'book_id': id,
  'book_name': '合成作品',
  'author_name': '测试',
  'book_type': '1',
  'cover': 'http://e1.kuangxiangit.com/cover.png',
  'description': '简介',
  'total_favor': '20',
  'total_word_count': '12345',
  'last_chapter_info': {'uptime': '2026-10-17 08:00:00'},
};
Map<String, dynamic> chapterInfo({
  String id = '101',
  int access = 1,
  bool cdn = false,
}) => {
  'chapter_id': id,
  'book_id': '12',
  'auth_access': access,
  'use_cdn': cdn ? 1 : 0,
  'txt_content': cdn
      ? 'http://e1.kuangxiangit.com/chapter.gz'
      : CiweimaoCrypto.encrypt('正文一\n正文二', seed: command),
  'author_say': '后记',
};

void main() {
  test('作品 ID 与官方链接解析严格限制域名，不联网解析网页', () {
    for (final value in [
      '12',
      'ciweimao:12',
      'https://www.ciweimao.com/book/12',
      '分享《作品》 https://wap.ciweimao.com/book/12?x=1。',
    ]) {
      expect(CiweimaoSource.bookId(value), '12');
    }
    for (final value in [
      '0',
      '-1',
      'https://www.ciweimao.com.evil.test/book/12',
      'https://user@www.ciweimao.com/book/12',
      'https://www.ciweimao.com:444/book/12',
      'https://www.ciweimao.com/chapter/12',
    ]) {
      expect(
        () => CiweimaoSource.bookId(value),
        throwsA(isA<SourceException>()),
      );
    }
  });
  test('搜索传递 App 分页，过滤其他媒体并按来源隔离作品', () async {
    final api = apiWith((r) async {
      expect(r.url.path, '/bookcity/get_search_book_list_by_bookname');
      expect(r.bodyFields['key'], '合成');
      expect(r.bodyFields['page'], '2');
      return ok({
        'book_list': [
          info(),
          info(),
          {...info(id: '13'), 'book_type': '2'},
        ],
      });
    });
    addTearDown(api.close);
    final result = await CiweimaoSource(api).search(' 合成 ', page: 2);
    expect(result, hasLength(1));
    expect(result.single.key, 'ciweimao:12');
    expect(result.single.favoriteCount, 20);
    expect(result.single.wordCount, 12345);
    expect(result.single.updatedAt, DateTime.utc(2026, 10, 17));
    expect(result.single.cover, 'https://e1.kuangxiangit.com/cover.png');
  });
  test('目录按分卷、章序排序，保留 VIP 和字数并排除无效章节', () {
    final directory = {
      'chapter_list': [
        {
          'division_id': '2',
          'division_index': '2',
          'division_name': '第二卷',
          'chapter_list': [
            {
              'chapter_id': '103',
              'chapter_index': '2',
              'chapter_title': '尾章',
              'is_paid': '1',
              'word_count': '2500',
            },
            {
              'chapter_id': '102',
              'chapter_index': '1',
              'chapter_title': '首章',
              'is_paid': '0',
            },
          ],
        },
        {
          'division_id': '1',
          'division_index': '1',
          'division_name': '第一卷',
          'chapter_list': [
            {
              'chapter_id': '101',
              'chapter_index': '1',
              'chapter_title': '开始',
              'is_paid': '0',
            },
            {
              'chapter_id': '104',
              'chapter_index': '2',
              'chapter_title': '删除',
              'is_valid': '0',
            },
          ],
        },
      ],
    };
    final result = CiweimaoParser.directory(directory);
    expect(result.map((c) => c.id), ['101', '102', '103']);
    expect(result.map((c) => c.volume), ['第一卷', '第二卷', '第二卷']);
    expect(result.last.vip, isTrue);
    expect(result.last.wordCount, 2500);
    final duplicated = jsonDecode(jsonEncode(directory));
    duplicated['chapter_list'][0]['chapter_list'][0]['chapter_id'] = '101';
    expect(
      () => CiweimaoParser.directory(Map<String, dynamic>.from(duplicated)),
      throwsA(isA<SourceException>()),
    );
  });
  test('详情编号不匹配立即失败，不请求错误作品目录', () async {
    var count = 0;
    final api = apiWith((_) async {
      count++;
      return ok({'book_info': info(id: '99')});
    });
    addTearDown(api.close);
    await expectLater(
      CiweimaoSource(api).getBook('12'),
      throwsA(isA<SourceException>()),
    );
    expect(count, 1);
  });
  test('免费正文通过 App 命令解密，保留段号与后记', () async {
    final paths = <String>[];
    final api = apiWith((r) async {
      paths.add(r.url.path);
      if (r.url.path == '/chapter/get_chapter_cmd') {
        return ok({'command': command});
      }
      expect(r.bodyFields['chapter_command'], command);
      return ok({'chapter_info': chapterInfo()});
    }, guest: true);
    addTearDown(api.close);
    final result = await CiweimaoSource(api).readChapter(book, first);
    expect(result.paragraphs.map((p) => p.text), ['正文一', '正文二', '作者的话', '后记']);
    expect(result.paragraphs.map((p) => p.remoteIndex), [1, 2, null, null]);
    expect(paths, ['/chapter/get_chapter_cmd', '/chapter/get_cpt_ifm']);
  });
  test('即使平台开启自动购买，未购章节也不索取正文或调用购买接口', () async {
    final paths = <String>[];
    final api = apiWith((r) async {
      paths.add(r.url.path);
      return ok({
        'is_auto_buy_pub': '1',
        'chapter_permission_list': [
          {'chapter_id': '102', 'auth_access': '1'},
          {'chapter_id': '103', 'auth_access': '0'},
        ],
      });
    });
    addTearDown(api.close);
    await expectLater(
      CiweimaoSource(api).readChapter(book, locked),
      throwsA(isA<SourceException>()),
    );
    expect(paths, ['/chapter/get_chapter_permission_list']);
  });
  test('游客不能请求 VIP 正文，伪造传入章节 VIP 标识也无效', () async {
    var calls = 0;
    final api = apiWith((_) async {
      calls++;
      throw StateError('不应请求');
    }, guest: true);
    addTearDown(api.close);
    await expectLater(
      CiweimaoSource(
        api,
      ).readChapter(book, const Chapter(id: '103', title: '伪造免费')),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 0);
    await expectLater(
      CiweimaoSource(api).readChapter(
        const Book(
          id: '12',
          source: 'sfacg',
          title: '',
          author: '',
          chapters: [first],
        ),
        first,
      ),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 0);
  });
  test('权限撤销或正文错配时不读取 CDN，避免缓存试读或其他章节', () async {
    for (final kind in ['access', 'book', 'chapter']) {
      var downloads = 0;
      final api = apiWith((r) async {
        if (r.method == 'GET') {
          downloads++;
          return http.Response('unexpected', 200);
        }
        if (r.url.path == '/chapter/get_chapter_cmd') {
          return ok({'command': command});
        }
        return ok({
          'chapter_info': {
            ...chapterInfo(cdn: true),
            if (kind == 'access') 'auth_access': '0',
            if (kind == 'book') 'book_id': '99',
            if (kind == 'chapter') 'chapter_id': '999',
          },
        });
      });
      addTearDown(api.close);
      await expectLater(
        CiweimaoSource(api).readChapter(book, first),
        throwsA(isA<SourceException>()),
      );
      expect(downloads, 0);
    }
  });
  for (final gzip in [true, false]) {
    test('正文 CDN 支持 ${gzip ? 'gzip' : 'zlib'}，不转发账号与签名', () async {
      final api = apiWith((r) async {
        if (r.method != 'GET') {
          return r.url.path == '/chapter/get_chapter_cmd'
              ? ok({'command': command})
              : ok({'chapter_info': chapterInfo(cdn: true)});
        }
        expect(r.url.scheme, 'https');
        expect(r.followRedirects, isFalse);
        expect(r.headers['cookie'], isNull);
        expect(r.headers['user-agent'], isNull);
        expect(r.body, isEmpty);
        return http.Response.bytes(
          ZLibCodec(gzip: gzip).encode(utf8.encode('<p>甲</p><p>乙</p>')),
          200,
        );
      });
      addTearDown(api.close);
      final result = await CiweimaoSource(api).readChapter(book, first);
      expect(result.paragraphs.take(2).map((p) => p.text), ['甲', '乙']);
    });
  }
  test('非法 CDN、损坏压缩数据和缺失图片均不能伪装成完整章节', () async {
    var calls = 0;
    final api = apiWith((_) async {
      calls++;
      return http.Response('not-compressed', 200);
    });
    addTearDown(api.close);
    for (final url in [
      'https://e1.kuangxiangit.com.evil.test/x',
      'https://user@e1.kuangxiangit.com/x',
      'https://e1.kuangxiangit.com:444/x',
    ]) {
      await expectLater(
        CiweimaoContent.fetch(api, url),
        throwsA(isA<SourceException>()),
      );
    }
    expect(calls, 0);
    await expectLater(
      CiweimaoContent.fetch(api, 'https://e1.kuangxiangit.com/x'),
      throwsA(isA<SourceException>()),
    );
    expect(
      () => CiweimaoParser.content('<img src="javascript:bad">'),
      throwsA(isA<SourceException>()),
    );
    expect(
      () => CiweimaoParser.content('   \n\n '),
      throwsA(isA<SourceException>()),
    );
  });
  test('插图与文字顺序保留，段号遵循 App 的原始行号，后记不错误绑定段评', () {
    final result = CiweimaoParser.content(
      '\n开头\n\n <img src="http://novel.kuangxiangit.com/pic.png" alt="插图">\n末尾 &amp; 😀',
      authorSay: '<p>附言</p>',
      cdnHost: 'e1.kuangxiangit.com',
      oldHosts: ['novel.kuangxiangit.com'],
    );
    expect(result.paragraphs.map((p) => p.remoteIndex), [2, 3, 4, null, null]);
    expect(result.paragraphs[1].image, 'https://e1.kuangxiangit.com/pic.png');
    expect(result.paragraphs[2].text, '末尾 & 😀');
  });
  test('批量下载过滤未购章节、保持请求顺序，缺失和失败按章报告', () async {
    final paths = <String>[];
    final api = apiWith((r) async {
      paths.add(r.url.path);
      if (r.url.path == '/chapter/get_chapter_permission_list') {
        return ok({
          'chapter_permission_list': [
            {'chapter_id': '102', 'auth_access': '1'},
            {'chapter_id': '103', 'auth_access': '0'},
          ],
        });
      }
      expect(r.bodyFields['chapter_id'], '102,101');
      if (r.url.path == '/chapter/get_chapter_download_cmd') {
        return ok({'command': command});
      }
      return ok({
        'chapter_infos': CiweimaoCrypto.encrypt(
          jsonEncode([
            {'chapter_id': '101', 'auth_access': 1, 'txt_content': '免费正文'},
          ]),
          seed: command,
        ),
      });
    });
    addTearDown(api.close);
    final results = await CiweimaoSource(
      api,
    ).readChapterBatch(book, [owned, locked, first]);
    expect(results.map((r) => r.id), ['102', '103', '101']);
    expect(results[0].error, isA<SourceException>());
    expect(results[1].error, isA<SourceException>());
    expect(results[2].content!.paragraphs.single.text, '免费正文');
    expect(paths, [
      '/chapter/get_chapter_permission_list',
      '/chapter/get_chapter_download_cmd',
      '/chapter/download_cpt',
    ]);
  });
  test('批量响应重复或包含未请求章节时拒绝整批结果', () async {
    for (final ids in [
      ['101', '101'],
      ['999'],
    ]) {
      final api = apiWith(
        (r) async => r.url.path == '/chapter/get_chapter_download_cmd'
            ? ok({'command': command})
            : ok({
                'chapter_infos': CiweimaoCrypto.encrypt(
                  jsonEncode([
                    for (final id in ids)
                      {'chapter_id': id, 'auth_access': 1, 'txt_content': '合成'},
                  ]),
                  seed: command,
                ),
              }),
      );
      addTearDown(api.close);
      await expectLater(
        CiweimaoSource(api).readChapterBatch(book, [first]),
        throwsA(isA<SourceException>()),
      );
    }
  });
}
