import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/download_queue.dart';
import 'package:unr/data/library.dart';
import 'package:unr/ui/chapter_download_dialog.dart';
import 'package:unr/ui/downloads.dart';
import 'helpers/downloads.dart' show DownloadsLibrary, sample;
import 'helpers/viewport.dart';

void main() {
  late DownloadsLibrary library;
  setUp(() => library = DownloadsLibrary());
  tearDown(() {
    library.dispose();
    library.source.api.close();
  });

  testWidgets('关闭下载窗口后任务继续，再次提交相同范围复用任务', (tester) async {
    final gate = Completer<void>();
    library.pendingDownload = gate;
    final book = sample('1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showChapterDownloadDialog(
                context,
                library: library,
                book: book,
              ),
              child: const Text('下载章节'),
            ),
          ),
        ),
      ),
    );
    Future<void> start() async {
      await tester.tap(find.text('下载章节'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始下载'));
      await tester.pumpAndSettle();
    }

    await start();
    final task = library.downloadQueue.tasks.single;
    expect(task.state, DownloadTaskState.running);
    await tester.tap(find.text('后台下载'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadDialog), findsNothing);
    expect(task.state, DownloadTaskState.running);
    await start();
    expect(library.downloadQueue.tasks, [task]);
    expect(library.downloadCalls, [book.key]);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DownloadDialog), findsNothing);
    gate.complete();
    library.pendingDownload = null;
    await tester.pumpAndSettle();
    expect(task.state, DownloadTaskState.completed);
    expect(task.success, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('正在下载可取消排队，失败后手动重试并自动刷新已下载列表', (tester) async {
    final gate = Completer<void>();
    library.pendingDownload = gate;
    library.failChapter = true;
    final first = library.downloadQueue.enqueue(
      sample('1'),
      sample('1').chapters,
    );
    final waiting = library.downloadQueue.enqueue(
      sample('2'),
      sample('2').chapters,
    );
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(library: library)));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无已下载的书籍'), findsOneWidget);
    await tester.tap(find.text('正在下载'));
    await tester.pumpAndSettle();
    expect(find.text('排队中 · 第 1 位 · 0 / 3 章'), findsOneWidget);
    await tester.tap(find.text('取消排队'));
    await tester.pumpAndSettle();
    expect(waiting.state, DownloadTaskState.cancelled);
    library.snapshot = DownloadedBooksSnapshot(
      books: [
        DownloadedBook(book: sample('1'), chapterIds: {'1', '3'}),
      ],
    );
    gate.complete();
    library.pendingDownload = null;
    await tester.pumpAndSettle();
    expect(first.failed, 1);
    expect(library.downloadCalls, ['sfacg:1']);
    await tester.tap(find.text('失败详情'));
    await tester.pumpAndSettle();
    expect(find.text('下载失败详情'), findsOneWidget);
    expect(find.textContaining('第二章：'), findsNWidgets(2));
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已下载'));
    await tester.pumpAndSettle();
    expect(find.text('已下载 2 / 3 章 · 部分下载'), findsOneWidget);
    await tester.tap(find.text('正在下载'));
    await tester.pumpAndSettle();
    library.failChapter = false;
    final retry = find.descendant(
      of: find.byKey(ValueKey('download-task-${first.id}')),
      matching: find.text('重试未完成章节'),
    );
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(library.downloadCalls, ['sfacg:1', 'sfacg:1']);
    final retried = library.downloadQueue.tasks.last;
    expect(retried.chapters.map((c) => c.id), ['2']);
    expect(retried.state, DownloadTaskState.completed);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1400.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('正在下载长书名与操作布局（宽$width，缩放$scale）', (tester) async {
        setTestViewport(tester, Size(width, 900));
        library.downloadFailures.add('sfacg:1');
        final book = sample('1', title: '很长很长的后台下载测试书名用于验证手机宽屏与文字缩放不会溢出');
        library.downloadQueue.enqueue(book, book.chapters);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: DownloadsPage(library: library),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('正在下载'));
        await tester.pumpAndSettle();
        expect(find.text('下载设置'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
