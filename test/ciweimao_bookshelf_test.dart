import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/bookshelf_source.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';

http.Response ok(Object data) => http.Response(
  CiweimaoCrypto.encrypt(jsonEncode({'code': 100000, 'data': data})),
  200,
);
Map<String, Object> preview(String id, {bool comic = false}) => {
  'book_id': id,
  'book_name': '合成作品$id',
  'author_name': '测试',
  'book_type': comic ? '2' : '1',
  'total_favor': '1',
};
CiweimaoCredentials credentials({bool guest = false, String id = '106'}) =>
    CiweimaoCredentials(
      account: 'synthetic-account',
      token: 'synthetic-token-1234',
      readerId: id,
      guest: guest,
    );

void main() {
  test('游客不提供书架导入，列表按官方字段获取且校验所属账号', () async {
    var count = 0;
    final api = CiweimaoApi(
      client: MockClient((r) async {
        count++;
        expect(r.url.path, '/bookshelf/get_shelf_list');
        return ok({
          'shelf_list': [
            {'shelf_id': '10', 'shelf_name': '书架一', 'reader_id': '106'},
          ],
        });
      }),
    )..restoreSession(credentials(guest: true));
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    expect(source, isA<BookshelfSource>());
    await expectLater(source.getShelves(), throwsA(isA<SourceException>()));
    expect(count, 0);
    api.restoreSession(credentials());
    expect((await source.getShelves()).single.name, '书架一');
    expect(count, 1);
  });
  test('书架逐页读取，去重、跳过漫画并复用预览，未下载目录', () async {
    final pages = <String>[];
    final api = CiweimaoApi(
      client: MockClient((r) async {
        if (r.url.path == '/bookshelf/get_shelf_list') {
          return ok({
            'shelf_list': [
              {'shelf_id': '10', 'shelf_name': '书架一'},
            ],
          });
        }
        expect(r.url.path, '/bookshelf/get_shelf_book_list_new');
        expect(r.bodyFields['count'], '20');
        pages.add(r.bodyFields['page']!);
        final page = int.parse(r.bodyFields['page']!);
        return ok({
          'book_list': page == 0
              ? [
                  for (var i = 1; i <= 20; i++)
                    {'book_info': preview('$i', comic: i == 20)},
                ]
              : [
                  {'book_info': preview('19')},
                  {'book_info': preview('21')},
                ],
        });
      }),
    )..restoreSession(credentials());
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    final shelf = (await source.getShelves()).single;
    final ids = await source.getShelfBookIds(shelf);
    expect(ids, [...List.generate(19, (i) => '${i + 1}'), '21']);
    expect(pages, ['0', '1']);
    final previews = await source.getShelfBooks(['1', '2']);
    expect(previews.map((r) => r.book!.key), ['ciweimao:1', 'ciweimao:2']);
    expect(previews.every((r) => r.book!.chapters.isEmpty), isTrue);
    expect(pages, ['0', '1']);
  });
  for (final comic in [false, true]) {
    test('重复满页不会静默截断或无限请求（漫画=$comic）', () async {
      var pages = 0;
      final api = CiweimaoApi(
        client: MockClient((r) async {
          if (r.url.path == '/bookshelf/get_shelf_list') {
            return ok({
              'shelf_list': [
                {'shelf_id': '10', 'shelf_name': '书架'},
              ],
            });
          }
          pages++;
          return ok({
            'book_list': [
              for (var i = 1; i <= 20; i++)
                {'book_info': preview('$i', comic: comic)},
            ],
          });
        }),
      )..restoreSession(credentials());
      addTearDown(api.close);
      final source = CiweimaoSource(api);
      final shelf = (await source.getShelves()).single;
      await expectLater(
        source.getShelfBookIds(shelf),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'message',
            contains('分页重复'),
          ),
        ),
      );
      expect(pages, 2);
    });
  }
  test('切换账号后拒绝旧书架，不使用前一账号的预览', () async {
    var details = 0;
    final api = CiweimaoApi(
      client: MockClient((r) async {
        if (r.url.path == '/bookshelf/get_shelf_list') {
          return ok({
            'shelf_list': [
              {'shelf_id': '10', 'shelf_name': '书架'},
            ],
          });
        }
        if (r.url.path == '/bookshelf/get_shelf_book_list_new') {
          return ok({
            'book_list': [
              {'book_info': preview('1')},
            ],
          });
        }
        details++;
        return ok({
          'book_info': {...preview('1'), 'book_name': '新账号可见详情'},
        });
      }),
    )..restoreSession(credentials());
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    final shelf = (await source.getShelves()).single;
    await source.getShelfBookIds(shelf);
    api.restoreSession(credentials(id: '107'));
    await expectLater(
      source.getShelfBookIds(shelf),
      throwsA(isA<SourceException>()),
    );
    expect((await source.getShelfBooks(['1'])).single.book!.title, '新账号可见详情');
    expect(details, 1);
  });
  test('缺失或下架的预览按作品报告失败，其余作品可继续导入', () async {
    final api = CiweimaoApi(
      client: MockClient((r) async {
        final id = r.bodyFields['book_id']!;
        return ok({'book_info': id == '2' ? null : preview(id)});
      }),
    )..restoreSession(credentials());
    addTearDown(api.close);
    final results = await CiweimaoSource(api).getShelfBooks(['1', '2', '3']);
    expect(results.map((r) => r.id), ['1', '2', '3']);
    expect(results[0].book!.source, 'ciweimao');
    expect(results[1].error, isA<SourceException>());
    expect(results[2].book!.title, '合成作品3');
  });
}
