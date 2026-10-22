import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/download_queue.dart';
import 'package:unr/domain/models.dart';

const chapters = [
  Chapter(id: '1', title: '第一章'),
  Chapter(id: '2', title: '第二章'),
  Chapter(id: '3', title: '第三章'),
];
Book book(String id, {String source = 'test'}) => Book(
  id: id,
  source: source,
  title: '作品$id',
  author: '作者',
  chapters: chapters,
);

void main() {
  test('全局顺序执行，跨书源、同书不同范围排队，重复任务复用', () async {
    final gate = Completer<void>();
    final calls = <String>[];
    var active = 0, maximum = 0;
    final queue = DownloadQueue(
      validate: (_) {},
      execute:
          (
            book,
            chapters, {
            required onProgress,
            isCancelled,
            refreshCached = false,
          }) async {
            calls.add('${book.key}/${chapters.first.id}');
            active++;
            if (active > maximum) maximum = active;
            if (calls.length == 1) await gate.future;
            for (final chapter in chapters) {
              onProgress(chapter, null);
            }
            active--;
          },
    );
    addTearDown(queue.dispose);
    final first = queue.enqueue(book('1'), chapters.take(1).toList());
    expect(queue.enqueue(book('1'), [chapters.first]), same(first));
    final second = queue.enqueue(book('1'), chapters.skip(1).toList());
    final third = queue.enqueue(book('1', source: 'other'), chapters);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['test:1/1']);
    expect(second.state, DownloadTaskState.queued);
    gate.complete();
    await Future.wait([
      first.whenFinished,
      second.whenFinished,
      third.whenFinished,
    ]);
    expect(calls, ['test:1/1', 'test:1/2', 'other:1/1']);
    expect(maximum, 1);
    expect(
      queue.tasks.every((task) => task.state == DownloadTaskState.completed),
      isTrue,
    );
    expect(queue.cacheRevision, 3);
  });

  test('取消排队不发请求，停止当前任务会等待现有请求结束再调度后续任务', () async {
    final gate = Completer<void>();
    final calls = <String>[];
    final queue = DownloadQueue(
      validate: (_) {},
      execute:
          (
            book,
            chapters, {
            required onProgress,
            isCancelled,
            refreshCached = false,
          }) async {
            calls.add(book.id);
            if (calls.length == 1) await gate.future;
            for (final chapter in chapters) {
              if (isCancelled?.call() == true) break;
              onProgress(chapter, null);
            }
          },
    );
    addTearDown(queue.dispose);
    final first = queue.enqueue(book('1'), chapters);
    final skipped = queue.enqueue(book('2'), chapters);
    final last = queue.enqueue(book('3'), chapters);
    queue.cancel(skipped);
    await skipped.whenFinished;
    await Future<void>.delayed(Duration.zero);
    queue.cancel(first);
    expect(first.state, DownloadTaskState.stopping);
    expect(calls, ['1']);
    gate.complete();
    await last.whenFinished;
    expect(calls, ['1', '3']);
    expect(first.state, DownloadTaskState.cancelled);
    expect(first.remaining, chapters);
    expect(last.state, DownloadTaskState.completed);
  });

  test('逐章失败和任务异常保留，后续任务继续；仅手动重试未成功章节并排到末尾', () async {
    var fail = true;
    final requests = <({String id, List<String> chapters, bool refresh})>[];
    final queue = DownloadQueue(
      validate: (_) {},
      execute:
          (
            book,
            chapters, {
            required onProgress,
            isCancelled,
            refreshCached = false,
          }) async {
            requests.add((
              id: book.id,
              chapters: chapters.map((c) => c.id).toList(),
              refresh: refreshCached,
            ));
            if (book.id == 'error') throw StateError('暂时失败');
            for (final chapter in chapters) {
              onProgress(
                chapter,
                fail && chapter.id == '2' ? const SourceException('无权限') : null,
              );
            }
          },
    );
    addTearDown(queue.dispose);
    final first = queue.enqueue(book('1'), chapters, refreshCached: true);
    final error = queue.enqueue(book('error'), chapters);
    await error.whenFinished;
    expect(first.state, DownloadTaskState.failed);
    expect(first.success, 2);
    expect(first.failures.keys, ['2']);
    expect(error.error, isA<StateError>());
    fail = false;
    final ahead = queue.enqueue(book('ahead'), chapters);
    final retry = queue.retry(first);
    await retry.whenFinished;
    expect(requests.map((request) => request.id), ['1', 'error', 'ahead', '1']);
    expect(requests.last.chapters, ['2']);
    expect(requests.last.refresh, isTrue);
    expect(ahead.state, DownloadTaskState.completed);
    expect(retry.state, DownloadTaskState.completed);
  });

  test('拒绝空范围、目录外章节及不可用书源，关闭队列停止后续任务', () async {
    final gate = Completer<void>();
    final calls = <String>[];
    final queue = DownloadQueue(
      validate: (book) {
        if (book.source == 'local') throw const SourceException('不可下载');
      },
      execute:
          (
            book,
            chapters, {
            required onProgress,
            isCancelled,
            refreshCached = false,
          }) async {
            calls.add(book.id);
            await gate.future;
            if (isCancelled?.call() != true) onProgress(chapters.first, null);
          },
    );
    expect(() => queue.enqueue(book('1'), []), throwsA(isA<SourceException>()));
    expect(
      () => queue.enqueue(book('1'), [const Chapter(id: 'foreign', title: '')]),
      throwsA(isA<SourceException>()),
    );
    expect(
      () => queue.enqueue(book('1', source: 'local'), chapters),
      throwsA(isA<SourceException>()),
    );
    final first = queue.enqueue(book('1'), chapters);
    final waiting = queue.enqueue(book('2'), chapters);
    await Future<void>.delayed(Duration.zero);
    queue.dispose();
    await waiting.whenFinished;
    gate.complete();
    await first.whenFinished;
    expect(calls, ['1']);
    expect(first.state, DownloadTaskState.cancelled);
    expect(waiting.state, DownloadTaskState.cancelled);
    expect(
      () => queue.enqueue(book('3'), chapters),
      throwsA(isA<SourceException>()),
    );
  });
}
