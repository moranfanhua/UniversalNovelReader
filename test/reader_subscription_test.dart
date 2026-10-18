import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/chapter_subscription_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/reader.dart';
import 'package:unr/ui/paged_chapter.dart';

class _Source extends SfacgSource {
  _Source() : super(SfacgApi());
  @override
  bool get canSubscribe => true;
  bool purchased = false;
  int prepares = 0, submissions = 0;
  int? count;
  Object? failure;
  Object? readError;
  Completer<void>? submitting;
  final controller = ChapterSubscriptionController();
  String blocked = '1';
  ChapterContent? firstContent;
  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async {
    if (chapter.id == blocked && !purchased) {
      throw readError ?? const SubscriptionRequiredException('尚未订阅本章');
    }
    if (chapter.id == '1' && firstContent != null) return firstContent!;
    return ChapterContent([
      for (var i = 0; i < 12; i++) Paragraph('正文${chapter.id}段落$i'),
    ]);
  }

  @override
  Future<ChapterSubscriptionQuote> prepareSubscription(
    Book book,
    Chapter first, {
    int? count = 20,
  }) async {
    prepares++;
    this.count = count;
    return controller.quote(
      chapters: [first],
      totalCost: '5 火券',
      submit: () async {
        submissions++;
        if (submitting != null) await submitting!.future;
        if (failure != null) throw failure!;
        purchased = true;
      },
    );
  }
}

class _Library extends Library {
  _Library(SfacgSource source) : super(Directory.systemTemp, source) {
    showParagraphComments = false;
  }
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) =>
      source.readChapter(book, chapter);
  @override
  Future<void> save() async {}
  @override
  Future<void> recordReading(Book book) async {}
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

void main() {
  final book = Book(
    id: '123',
    title: '很长的书名用于手机宽屏和文字缩放下的订阅提示',
    author: '',
    chapters: [
      for (var i = 1; i <= 3; i++) Chapter(id: '$i', title: '章节$i', vip: true),
    ],
  );
  late _Source source;
  late _Library library;
  setUp(() {
    source = _Source();
    library = _Library(source);
  });
  tearDown(() {
    library.dispose();
    source.api.close();
  });
  Future<void> open(WidgetTester tester, {double width = 360}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.7)),
          child: child!,
        ),
        home: ReaderPage(library: library, book: book),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).last);
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  for (final mode in ReadingMode.values) {
    for (final width in [320.0, 1280.0]) {
      testWidgets('${mode.name} / $width 未订阅章节主动选量并确认后继续阅读', (tester) async {
        library.readingMode = mode;
        await open(tester, width: width);
        await tap(tester, '订阅后续章节');
        expect(source.submissions, 0);
        for (final option in ['20章', '100章', '全部', '自定义']) {
          expect(find.text(option), findsOneWidget);
        }
        await tap(tester, '100章');
        await tap(tester, '获取订阅费用');
        expect(source.count, 100);
        expect(find.text('合计：5 火券'), findsOneWidget);
        expect(source.submissions, 0);
        await tap(tester, '确认订阅');
        expect(source.submissions, 1);
        expect(find.textContaining('正文1段落'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('自定义数量校验，修改选项后重新报价；取消不购买', (tester) async {
    await open(tester);
    await tap(tester, '订阅后续章节');
    await tap(tester, '自定义');
    await tap(tester, '获取订阅费用');
    expect(source.prepares, 0);
    expect(find.text('请输入大于 0 的章节数量'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '7');
    await tap(tester, '获取订阅费用');
    expect(source.count, 7);
    await tap(tester, '全部');
    expect(find.text('确认订阅'), findsNothing);
    await tap(tester, '获取订阅费用');
    expect(source.count, null);
    await tap(tester, '取消');
    expect(source.submissions, 0);
  });
  testWidgets('订阅结果不确定不自动重发，必须重新获取费用', (tester) async {
    source.failure = const SubscriptionUncertainException();
    await open(tester);
    await tap(tester, '订阅后续章节');
    await tap(tester, '获取订阅费用');
    await tap(tester, '确认订阅');
    expect(source.submissions, 1);
    expect(find.textContaining('订阅结果未确认'), findsOneWidget);
    expect(find.text('确认订阅'), findsNothing);
    await tap(tester, '取消');
    expect(source.submissions, 1);
  });
  testWidgets('正在提交时阻止重复点击与返回退出，不发送第二次购买', (tester) async {
    source.submitting = Completer<void>();
    await open(tester);
    await tap(tester, '订阅后续章节');
    await tap(tester, '获取订阅费用');
    await tester.ensureVisible(find.text('确认订阅'));
    await tester.tap(find.text('确认订阅'));
    await tester.pump();
    expect(source.submissions, 1);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '获取订阅费用'))
          .onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('订阅后续章节').last, findsOneWidget);
    source.submitting!.complete();
    await tester.pumpAndSettle();
    expect(source.submissions, 1);
    expect(find.textContaining('正文1段落'), findsWidgets);
  });
  testWidgets('一般网络错误不显示订阅按钮', (tester) async {
    source.readError = const SourceException('连接失败');
    await open(tester);
    expect(find.text('订阅后续章节'), findsNothing);
  });
  testWidgets('连续滚动下一章未订阅可订阅并保留当前正文', (tester) async {
    source.blocked = '2';
    library.readingMode = ReadingMode.scroll;
    await open(tester);
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -1600),
    );
    await tester.pumpAndSettle();
    await tap(tester, '订阅后续章节');
    await tap(tester, '获取订阅费用');
    await tap(tester, '确认订阅');
    expect(source.submissions, 1);
    expect(find.textContaining('正文1段落'), findsWidgets);
    expect(find.textContaining('正文2段落'), findsWidgets);
  });
  testWidgets('宽屏右页预读未订阅章节可以订阅，保留左页和当前章节进度', (tester) async {
    source.blocked = '2';
    source.firstContent = const ChapterContent([Paragraph('左页当前正文')]);
    library.readingMode = ReadingMode.paged;
    library.progress[book.key] = [0, 0];
    await open(tester, width: 1920);
    final before = library.progress[book.key]?.toList();
    expect(
      tester.state<PagedChapterState>(find.byType(PagedChapter)).columns,
      2,
    );
    expect(find.textContaining('下一章加载失败'), findsOneWidget);
    await tap(tester, '订阅后续章节');
    await tap(tester, '获取订阅费用');
    await tap(tester, '确认订阅');
    expect(source.submissions, 1);
    expect(find.textContaining('左页当前正文'), findsWidgets);
    expect(find.textContaining('正文2段落'), findsWidgets);
    expect(library.progress[book.key], before);
  });
}
