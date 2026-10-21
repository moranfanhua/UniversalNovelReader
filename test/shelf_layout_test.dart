import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/home.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/reading_taps.dart';
import 'helpers/memory_library.dart';
import 'helpers/viewport.dart';

const chapters = [
  Chapter(id: '1', title: '第一章'),
  Chapter(id: '2', title: '落幕', wordCount: 4700),
];
Book shelfBook(
  String id,
  String title, {
  String source = 'sfacg',
  DateTime? updated,
}) => Book(
  id: id,
  title: title,
  author: '作者',
  source: source,
  chapters: chapters,
  updatedAt: updated,
);

class LayoutLibrary extends TestLibrary
    with MemoryPersistence, EmptyChapterCache {
  LayoutLibrary()
    : super(
        source: SfacgSource(
          SfacgApi(client: MockClient((_) async => throw StateError('不应访问网络'))),
        ),
        clock: () => DateTime.utc(2026, 10, 14, 12),
      );
  @override
  Future<void> saveShelfUpdateTimes() => save();

  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      const ChapterContent([Paragraph('测试正文')]);
}

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  void viewport(WidgetTester tester, {double? width}) {
    setTestViewport(
      tester,
      Size(
        width ?? (defaultTargetPlatform == TargetPlatform.windows ? 1400 : 390),
        900,
      ),
    );
  }

  LayoutLibrary library() {
    final result = useLibrary(LayoutLibrary());
    return result;
  }

  test('显示方式持久化，旧书库默认宫格，写入失败回滚选择', () async {
    final root = await Directory.systemTemp.createTemp('unr-shelf-layout-');
    addTearDown(() => root.delete(recursive: true));
    final source = SfacgSource(SfacgApi());
    addTearDown(source.api.close);
    final saved = await Library.open(source, directory: root);
    addTearDown(saved.dispose);
    expect(saved.shelfLayout, ShelfLayout.grid);
    await saved.setShelfLayout(ShelfLayout.list);
    final restored = await Library.open(source, directory: root);
    addTearDown(restored.dispose);
    expect(restored.shelfLayout, ShelfLayout.list);
    await File(
      '${root.path}/index.json',
    ).writeAsString(jsonEncode({'books': []}));
    final old = await Library.open(source, directory: root);
    addTearDown(old.dispose);
    expect(old.shelfLayout, ShelfLayout.grid);
    final failing = library()..failSave = true;
    await expectLater(
      failing.setShelfLayout(ShelfLayout.list),
      throwsA(isA<FileSystemException>()),
    );
    expect(failing.shelfLayout, ShelfLayout.grid);
  });

  testWidgets('宫格整体左对齐，卡片文字居中且与封面等宽', (tester) async {
    viewport(tester);
    final model = library()..books.add(shelfBook('1', '长书名需要分两行显示的作品名称'));
    await tester.pumpWidget(UnrApp(library: model));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('shelf-book-sfacg:1'));
    final cover = tester.getRect(
      find.descendant(of: card, matching: find.byType(BookCover)),
    );
    final title = find.descendant(
      of: card,
      matching: find.byWidgetPredicate((w) => w is Text && w.maxLines == 2),
    );
    final text = tester.getRect(title);
    expect(cover.width, closeTo(text.width, .01));
    expect(cover.height / cover.width, closeTo(1.5, .01));
    final selector = tester.getRect(
      find.byKey(const ValueKey('bookshelf-selector')),
    );
    expect(cover.left, closeTo(selector.left, .01));
    for (final label in tester.widgetList<Text>(
      find.descendant(of: card, matching: find.byType(Text)),
    )) {
      expect(label.textAlign, TextAlign.center);
    }
    expect(tester.widget<Text>(title).style!.fontSize, lessThan(14));
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('手机宫格每行三本占满可用宽度，封面和文字等比例缩放', (tester) async {
    viewport(tester, width: 360);
    final model = library()
      ..books.addAll(List.generate(6, (i) => shelfBook('$i', '作品$i')));
    await tester.pumpWidget(UnrApp(library: model));
    for (final width in [320.0, 360.0, 390.0, 412.0, 480.0, 599.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      Rect cover(int index) => tester.getRect(
        find.descendant(
          of: find.byKey(ValueKey('shelf-book-sfacg:$index')),
          matching: find.byType(BookCover),
        ),
      );
      final first = cover(0),
          second = cover(1),
          third = cover(2),
          fourth = cover(3);
      expect(first.top, closeTo(second.top, .01));
      expect(first.top, closeTo(third.top, .01));
      expect(first.left, closeTo(20, .01));
      expect(width - third.right, closeTo(first.left, .01));
      expect(second.left - first.right, closeTo(12, .01));
      expect(third.left - second.right, closeTo(12, .01));
      expect(fourth.top, greaterThan(first.bottom));
      expect(first.width, closeTo((width - 40 - 24) / 3, .01));
      expect(first.height / first.width, closeTo(1.5, .01));
      final title = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('shelf-book-sfacg:0')),
          matching: find.byWidgetPredicate((w) => w is Text && w.maxLines == 2),
        ),
      );
      expect(title.style!.fontSize! / 13, closeTo(first.width / 150, .01));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('手机书架不足三本时保持三列尺寸并左对齐', (tester) async {
    viewport(tester, width: 412);
    final model = library()
      ..books.addAll(List.generate(3, (i) => shelfBook('$i', '作品$i')));
    await tester.pumpWidget(UnrApp(library: model));
    for (final count in [3, 2, 1]) {
      model.books.removeRange(count, model.books.length);
      await model.save();
      await tester.pumpAndSettle();
      for (var i = 0; i < count; i++) {
        final cover = tester.getRect(
          find.descendant(
            of: find.byKey(ValueKey('shelf-book-sfacg:$i')),
            matching: find.byType(BookCover),
          ),
        );
        expect(cover.width, closeTo(116, .01));
        expect(cover.left, closeTo(20 + i * (116 + 12), .01));
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('列表显示阅读状态和真实更新信息，切换和打开作品保留排序', (tester) async {
    viewport(tester);
    final model = library();
    model.books.addAll([
      shelfBook('1', '第一本', updated: DateTime.utc(2026, 10, 13, 17)),
      shelfBook('2', '第二本'),
      shelfBook('3', '本地作品', source: 'local'),
    ]);
    model.progress['sfacg:2'] = [0, 3];
    await tester.pumpWidget(UnrApp(library: model));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换为列表'));
    await tester.pumpAndSettle();
    expect(model.shelfLayout, ShelfLayout.list);
    expect(find.byType(GridView), findsNothing);
    expect(find.text('未读过'), findsNWidgets(2));
    expect(find.text('已读至第 1 章 · 1 章未读'), findsOneWidget);
    expect(find.text('19小时前更新 · 第2章 落幕（4700字）'), findsOneWidget);
    expect(find.text('更新时间未知 · 第2章 落幕（4700字）'), findsOneWidget);
    expect(find.text('本地小说 · 共 2 章'), findsOneWidget);
    final rows = tester
        .widgetList<InkWell>(
          find.byWidgetPredicate(
            (w) => w is InkWell && w.key.toString().contains('shelf-book-'),
          ),
        )
        .map((w) => w.key.toString())
        .toList();
    expect(
      rows,
      containsAllInOrder([
        const ValueKey('shelf-book-sfacg:1').toString(),
        const ValueKey('shelf-book-sfacg:2').toString(),
        const ValueKey('shelf-book-local:3').toString(),
      ]),
    );
    await tester.tap(find.text('第二本'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.text('作品详情'), findsNothing);
    await showReadingControls(tester);
    await tester.tap(find.byType(BackButton).hitTestable());
    await tester.pumpAndSettle();
    expect(model.shelfLayout, ShelfLayout.list);
    await tester.tap(find.byTooltip('切换为宫格'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('设置页可以切换显示方式，返回书库立即生效', (tester) async {
    viewport(tester);
    final model = library()..books.add(shelfBook('1', '作品'));
    await tester.pumpWidget(UnrApp(library: model));
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('软件设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-shelf-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shelf-layout')), findsOneWidget);
    await tester.tap(find.text('列表'));
    await tester.pumpAndSettle();
    expect(model.shelfLayout, ShelfLayout.list);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书库'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsNothing);
    expect(find.text('未读过'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('手机和宽屏放大文字时，长书名在两种显示方式下均不溢出', (tester) async {
    viewport(tester, width: 320);
    final model = library()
      ..books.addAll(
        List.generate(6, (i) => shelfBook('$i', '很长的作品名称需要换行显示并且不造成界面溢出$i')),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: HomePage(library: model),
        ),
      ),
    );
    for (final width in [320.0, 412.0, 599.0, 600.0, 1400.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('切换为列表'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('切换为宫格'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}
