import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/data/download_queue.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/chapter_subscription_source.dart';
import 'package:unr/sources/novel_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/chapter_download_dialog.dart';

class _SubscriptionSource implements ChapterSubscriptionSource {
  _SubscriptionSource(this.id);
  @override
  final String id;
  @override
  String get name => '测试平台';
  @override
  bool canSubscribe = true;
  int prepares = 0, purchases = 0;
  String? firstId;
  Object? failure;
  final controller = ChapterSubscriptionController();
  @override
  Future<Book> getBook(String input) async => throw UnimplementedError();
  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async =>
      throw UnimplementedError();
  @override
  Future<ChapterSubscriptionQuote> prepareSubscription(
    Book book,
    Chapter first, {
    int? count = 20,
  }) async {
    prepares++;
    firstId = first.id;
    return controller.quote(
      chapters: [first],
      totalCost: '5 币',
      submit: () async {
        purchases++;
        if (failure != null) throw failure!;
      },
    );
  }
}

class _FreeSource implements NovelSource {
  @override
  String get id => 'fanqie';
  @override
  String get name => '番茄';
  @override
  Future<Book> getBook(String input) async => throw UnimplementedError();
  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async =>
      throw UnimplementedError();
}

class _Library extends Library {
  _Library(NovelSource source)
    : super(
        Directory.systemTemp,
        SfacgSource(SfacgApi()),
        novelSources: [source],
      );
  int downloads = 0;
  Completer<void>? pending;
  final blocked = <String>{'2', '3'};
  @override
  Future<void> downloadChapters(
    Book book,
    List<Chapter> chapters, {
    required void Function(Chapter chapter, Object? error) onProgress,
    bool Function()? isCancelled,
    bool refreshCached = false,
  }) async {
    downloads++;
    if (pending != null) await pending!.future;
    for (final chapter in chapters.reversed) {
      if (isCancelled?.call() == true) break;
      onProgress(
        chapter,
        blocked.contains(chapter.id)
            ? const SubscriptionRequiredException('尚未订阅')
            : null,
      );
    }
  }
}

void main() {
  late _Library library;
  late _SubscriptionSource source;
  setUp(() {
    source = _SubscriptionSource('sfacg');
    library = _Library(source);
  });
  tearDown(() {
    library.dispose();
    library.source.api.close();
  });
  Book book(String id) => Book(
    id: '12',
    source: id,
    title: '下载与订阅测试',
    author: '',
    chapters: [
      for (var i = 1; i <= 4; i++) Chapter(id: '$i', title: '第$i章', vip: i > 1),
    ],
  );
  Future<void> open(
    WidgetTester tester, {
    double width = 360,
    DownloadTask? previousTask,
  }) async {
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
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => DownloadDialog(
                  library: library,
                  book: book(source.id),
                  previousTask: previousTask,
                ),
              ),
              child: const Text('打开下载'),
            ),
          ),
        ),
      ),
    );
    await tap(tester, '打开下载');
  }

  Future<void> replaceSource(NovelSource value) async {
    library.dispose();
    library.source.api.close();
    library = _Library(value);
  }

  for (final platform in ['sfacg', 'qidian', 'ciweimao']) {
    for (final width in [320.0, 1280.0]) {
      testWidgets('$platform / $width 下载前即可选择订阅，取消不购买', (tester) async {
        source = _SubscriptionSource(platform);
        await replaceSource(source);
        await open(tester, width: width);
        expect(
          find.byKey(const ValueKey('download-subscribe')).hitTestable(),
          findsOneWidget,
        );
        await tester.enterText(find.widgetWithText(TextField, '起始章'), '2');
        await tap(tester, '订阅后续章节');
        for (final option in ['20章', '100章', '全部', '自定义']) {
          expect(find.text(option), findsOneWidget);
        }
        await tap(tester, '获取订阅费用');
        expect(source.firstId, '2');
        expect(source.purchases, 0);
        await tap(tester, '取消');
        expect(library.downloads, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('下载遇到未订阅章按目录顺序定位，确认后保留范围并手动重试下载', (tester) async {
    await open(tester);
    await tap(tester, '开始下载');
    expect(library.downloads, 1);
    expect(source.purchases, 0);
    await tap(tester, '订阅后续章节');
    await tap(tester, '获取订阅费用');
    expect(source.firstId, '2');
    await tap(tester, '确认订阅');
    expect(source.purchases, 1);
    expect(library.downloads, 1);
    expect(find.text('订阅成功，请点击下载按钮继续保存章节。'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '起始章'))
          .controller!
          .text,
      '1',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '结束章'))
          .controller!
          .text,
      '4',
    );
    library.blocked.clear();
    await tap(tester, '重新下载');
    expect(library.downloads, 2);
    expect(find.text('下载完成 · 成功 4 章，失败 0 章'), findsOneWidget);
  });
  testWidgets('下载中禁用订阅，范围无效不报价，费用结果不确定不自动重发', (tester) async {
    library.pending = Completer<void>();
    await open(tester);
    await tester.ensureVisible(find.text('开始下载'));
    await tester.tap(find.text('开始下载'));
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('download-subscribe')),
          )
          .onPressed,
      isNull,
    );
    library.pending!.complete();
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '起始章'), '0');
    await tap(tester, '订阅后续章节');
    expect(source.prepares, 0);
    expect(find.text('请输入有效的起止章序号'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '起始章'), '3');
    source.failure = const SubscriptionUncertainException();
    await tap(tester, '订阅后续章节');
    await tap(tester, '获取订阅费用');
    expect(source.firstId, '3');
    await tap(tester, '确认订阅');
    expect(find.textContaining('订阅结果未确认'), findsOneWidget);
    expect(source.purchases, 1);
    await tap(tester, '取消');
    expect(library.downloads, 1);
  });
  testWidgets('后台失败任务的下载设置保留范围并定位首个未订阅章节', (tester) async {
    final selectedBook = book(source.id);
    final task = library.downloadQueue.enqueue(
      selectedBook,
      selectedBook.chapters.sublist(1),
    );
    await tester.pump();
    expect(task.state, DownloadTaskState.failed);
    await open(tester, previousTask: task);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '起始章'))
          .controller!
          .text,
      '2',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '结束章'))
          .controller!
          .text,
      '4',
    );
    await tap(tester, '订阅后续章节');
    await tap(tester, '获取订阅费用');
    expect(source.firstId, '2');
    expect(source.purchases, 0);
    await tap(tester, '取消');
    expect(library.downloads, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('没有订阅能力的平台不显示入口', (tester) async {
    final free = _FreeSource();
    await replaceSource(free);
    // The displayed source is selected by this book's source ID.
    source = _SubscriptionSource(free.id);
    await open(tester);
    expect(find.byKey(const ValueKey('download-subscribe')), findsNothing);
  });
}

Future<void> tap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}
