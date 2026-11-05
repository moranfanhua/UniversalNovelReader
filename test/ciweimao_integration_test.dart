import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/formats/ebook.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/account.dart';
import 'package:unr/ui/book_page.dart';
import 'package:unr/ui/ciweimao_account.dart';
import 'package:unr/ui/import_shelf.dart';

http.Response ok(Object data) => http.Response(
  CiweimaoCrypto.encrypt(jsonEncode({'code': 100000, 'data': data})),
  200,
);
CiweimaoCredentials credentials({bool guest = false}) => CiweimaoCredentials(
  account: 'synthetic-account',
  token: 'synthetic-token-1234',
  readerId: '106',
  guest: guest,
);

class MemoryLibrary extends Library {
  MemoryLibrary(super.root, super.source, {required super.novelSources});
  @override
  Future<void> save() async => notifyListeners();
}

void main() {
  test('批量缓存、进度、来源隔离和离线导出保留封面插图，缺权章节明确失败', () async {
    final root = await Directory.systemTemp.createTemp('unr-ciweimao-');
    addTearDown(() => root.delete(recursive: true));
    var offline = false, calls = 0;
    const chapters = [
      Chapter(id: '101', title: '第一章', volume: '第一卷'),
      Chapter(id: '102', title: '第二章', volume: '第二卷'),
      Chapter(id: '103', title: '未购', vip: true),
    ];
    const book = Book(
      id: '12',
      source: 'ciweimao',
      title: '合成作品',
      author: '测试',
      cover: 'https://e1.kuangxiangit.com/cover.png',
      chapters: chapters,
    );
    const other = Book(
      id: '12',
      source: 'sfacg',
      title: '另一平台同编号',
      author: '测试',
      chapters: chapters,
    );
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lL8AAAAASUVORK5CYII=',
    );
    final api = CiweimaoApi(
      client: MockClient((r) async {
        calls++;
        if (offline) throw const SocketException('offline');
        if (r.url.path == '/chapter/get_chapter_permission_list') {
          return ok({
            'chapter_permission_list': [
              {'chapter_id': '103', 'auth_access': '0'},
            ],
          });
        }
        if (r.url.path == '/chapter/get_chapter_download_cmd') {
          return ok({'command': 'synthetic-command'});
        }
        expect(r.url.path, '/chapter/download_cpt');
        expect(r.bodyFields['chapter_id'], '101,102');
        return ok({
          'chapter_infos': CiweimaoCrypto.encrypt(
            jsonEncode([
              {'chapter_id': '102', 'txt_content': '第二章正文', 'auth_access': '1'},
              {
                'chapter_id': '101',
                'txt_content':
                    '第一段\n<img src="https://e1.kuangxiangit.com/picture.png" alt="插图">\n第二段',
                'auth_access': '1',
              },
            ]),
            seed: 'synthetic-command',
          ),
        });
      }),
    )..restoreSession(credentials());
    addTearDown(api.close);
    final imageApi = SfacgApi(
      client: MockClient((r) async {
        calls++;
        if (offline) throw const SocketException('offline');
        expect(r.url.host, 'e1.kuangxiangit.com');
        expect(r.headers['cookie'], isNull);
        return http.Response.bytes(png, 200);
      }),
    );
    addTearDown(imageApi.close);
    final defaultSource = SfacgSource(imageApi), source = CiweimaoSource(api);
    final library = Library(root, defaultSource, novelSources: [source]);
    addTearDown(library.dispose);
    await library.add(book);
    await library.store(
      other,
      chapters.first,
      const ChapterContent([Paragraph('其他平台缓存')]),
    );
    final progress = <String, Object?>{};
    await library.downloadChapters(
      book,
      chapters,
      onProgress: (c, error) => progress[c.id] = error,
    );
    expect(progress['101'], isNull);
    expect(progress['102'], isNull);
    expect(progress['103'], isA<SourceException>());
    expect(await library.cached(book, chapters.last), isNull);
    await library.remember(book, 1, 0);
    await library.setSearchSourceEnabled(source.id, false);
    offline = true;
    api.restoreSession(null);
    final count = calls;
    final restored = await Library.open(
      defaultSource,
      directory: root,
      novelSources: [source],
    );
    addTearDown(restored.dispose);
    expect(restored.progress[book.key], [1, 0]);
    expect(restored.isSearchSourceEnabled(source.id), isFalse);
    expect(restored.commentsFor(book), same(source));
    final first = await restored.read(book, chapters.first);
    expect(
      first.paragraphs[1].image,
      'https://e1.kuangxiangit.com/picture.png',
    );
    expect(
      (await restored.read(other, chapters.first)).paragraphs.single.text,
      '其他平台缓存',
    );
    final contents = {
      for (final chapter in chapters.take(2))
        chapter.id: await restored.read(book, chapter),
    };
    final epub = await Ebook.exportEpub(
      book,
      contents,
      (key) => restored.loadImage(book, key),
    );
    final archive = ZipDecoder().decodeBytes(epub);
    final opf = utf8.decode(archive.findFile('OEBPS/content.opf')!.content);
    expect(opf, contains('urn:unr:ciweimao:12'));
    expect(
      opf,
      contains('<dc:source>https://www.ciweimao.com/book/12</dc:source>'),
    );
    final imported = Ebook.importEpub(epub);
    expect(imported.book.title, contains('节选'));
    expect(imported.book.chapters.map((c) => c.title), ['第一章', '第二章']);
    expect(imported.book.cover, isNotEmpty);
    expect(imported.images[imported.book.cover], png);
    final importedPicture = imported.contents.values
        .expand((c) => c.paragraphs)
        .firstWhere((p) => p.image != null)
        .image!;
    expect(imported.images[importedPicture], png);
    final txt = utf8.decode(Ebook.exportTxt(book, contents));
    expect(txt, contains('来源：https://www.ciweimao.com/book/12'));
    expect(txt.indexOf('第一章'), lessThan(txt.indexOf('第二章')));
    expect(txt, contains('[插图] https://e1.kuangxiangit.com/picture.png'));
    expect(calls, count);
    await expectLater(
      Ebook.exportEpub(
        book,
        contents,
        (_) async => throw const SourceException('图片不可用'),
      ),
      throwsA(isA<SourceException>()),
    );
  });

  for (final size in [const Size(390, 844), const Size(1400, 900)]) {
    testWidgets('四平台账号与书架入口正确显示刺猬猫图标，适配 $size 两倍字体', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sfacg = SfacgApi(),
          api = CiweimaoApi(),
          fanqie = FanqieApi(),
          qidian = QidianApi();
      addTearDown(sfacg.close);
      addTearDown(api.close);
      addTearDown(fanqie.close);
      addTearDown(qidian.close);
      final library = MemoryLibrary(
        Directory.systemTemp,
        SfacgSource(sfacg),
        novelSources: [
          FanqieSource(fanqie),
          QidianSource(qidian),
          CiweimaoSource(api),
        ],
      );
      addTearDown(library.dispose);
      Widget app(Widget home) => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: home,
      );
      await tester.pumpWidget(app(AccountSettingsPage(library: library)));
      await tester.pumpAndSettle();
      final accountCard = find.byKey(const ValueKey('account-card-ciweimao'));
      expect(accountCard, findsOneWidget);
      expect(find.byTooltip('刺猬猫阅读'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              w.image is AssetImage &&
              (w.image as AssetImage).assetName == 'assets/ciweimao_icon.png',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(accountCard);
      await tester.pumpAndSettle();
      await tester.tap(accountCard);
      await tester.pumpAndSettle();
      expect(find.byType(CiweimaoAccountPage), findsOneWidget);
      expect(find.text('账号密码登录'), findsOneWidget);
      expect(find.text('手机号验证码登录'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app(ImportShelfPage(library: library)));
      await tester.pumpAndSettle();
      expect(find.text('刺猬猫阅读'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              w.image is AssetImage &&
              (w.image as AssetImage).assetName == 'assets/ciweimao_icon.png',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('书源入口支持官方分享链接和带平台前缀的 ID，不误路由至菠萝包', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var sfacgCalls = 0, details = 0;
    final sfacg = SfacgApi(
      client: MockClient((_) async {
        sfacgCalls++;
        throw StateError('错误路由');
      }),
    );
    final api = CiweimaoApi(
      client: MockClient((r) async {
        if (r.url.path == '/book/get_info_by_id') {
          details++;
          expect(r.bodyFields['book_id'], '12');
          return ok({
            'book_info': {
              'book_id': '12',
              'book_name': '合成作品的长书名用于验证手机页面展示',
              'author_name': '测试',
            },
          });
        }
        return ok({
          'chapter_list': [
            {
              'division_id': '1',
              'division_index': '1',
              'division_name': '第一卷',
              'chapter_list': [
                {
                  'chapter_id': '101',
                  'chapter_index': '1',
                  'chapter_title': '第一章',
                },
              ],
            },
          ],
        });
      }),
    )..restoreSession(credentials(guest: true));
    addTearDown(sfacg.close);
    addTearDown(api.close);
    final library = MemoryLibrary(
      Directory.systemTemp,
      SfacgSource(sfacg),
      novelSources: [CiweimaoSource(api)],
    );
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await tester.tap(find.text('书源').last);
    await tester.pumpAndSettle();
    for (final text in [
      'ciweimao:12',
      'https://www.ciweimao.com/book/12',
      '分享链接 https://wap.ciweimao.com/book/12。',
    ]) {
      await tester.enterText(find.byType(TextField), text);
      await tester.tap(find.byTooltip('搜索或添加作品'));
      await tester.pumpAndSettle();
      expect(find.byType(BookPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
    }
    expect(details, 3);
    expect(sfacgCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
