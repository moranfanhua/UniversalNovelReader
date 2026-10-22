import 'dart:async';
import 'package:flutter/foundation.dart';
import '../domain/models.dart';

typedef DownloadExecutor =
    Future<void> Function(
      Book book,
      List<Chapter> chapters, {
      required void Function(Chapter chapter, Object? error) onProgress,
      bool Function()? isCancelled,
      bool refreshCached,
    });

enum DownloadTaskState {
  queued,
  running,
  stopping,
  completed,
  failed,
  cancelled,
}

class DownloadTask {
  DownloadTask._(this.id, this.book, this.chapters, this.refreshCached);
  final int id;
  final Book book;
  final List<Chapter> chapters;
  final bool refreshCached;
  final _results = <String, Object?>{};
  final _failures = <String, Object>{};
  final _finished = Completer<void>();
  DownloadTaskState _state = DownloadTaskState.queued;
  Object? _error;
  String _chapterTitle = '';
  bool _cancelled = false;
  int _revision = 0;
  DownloadTaskState get state => _state;
  Object? get error => _error;
  String get chapterTitle => _chapterTitle;
  int get revision => _revision;
  int get done => _results.length;
  int get failed => _failures.length;
  int get success => done - failed;
  Map<String, Object> get failures => Map.unmodifiable(_failures);
  List<Chapter> get remaining => chapters
      .where(
        (chapter) =>
            !_results.containsKey(chapter.id) || _results[chapter.id] != null,
      )
      .toList();
  bool get pending =>
      state == DownloadTaskState.queued ||
      state == DownloadTaskState.running ||
      state == DownloadTaskState.stopping;
  Future<void> get whenFinished => _finished.future;
}

class DownloadQueue extends ChangeNotifier {
  DownloadQueue({required this.execute, required this.validate});
  final DownloadExecutor execute;
  final void Function(Book) validate;
  final _tasks = <DownloadTask>[];
  bool _draining = false, _disposed = false;
  int _nextId = 0, _cacheRevision = 0;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  int get cacheRevision => _cacheRevision;
  bool hasPendingBook(String key) =>
      _tasks.any((task) => task.book.key == key && task.pending);

  DownloadTask enqueue(
    Book book,
    List<Chapter> chapters, {
    bool refreshCached = false,
  }) {
    if (_disposed) throw const SourceException('下载队列已关闭');
    validate(book);
    final directory = {
      for (final chapter in book.chapters) chapter.id: chapter,
    };
    final selected = <String, Chapter>{};
    for (final chapter in chapters) {
      final actual = directory[chapter.id];
      if (actual == null) throw const SourceException('下载章节不属于当前作品');
      selected[chapter.id] = actual;
    }
    if (selected.isEmpty) throw const SourceException('请选择需要下载的章节');
    for (final task in _tasks) {
      if (task.pending &&
          task.book.key == book.key &&
          task.refreshCached == refreshCached &&
          setEquals(
            task.chapters.map((c) => c.id).toSet(),
            selected.keys.toSet(),
          )) {
        return task;
      }
    }
    final task = DownloadTask._(
      ++_nextId,
      book,
      List.unmodifiable(selected.values),
      refreshCached,
    );
    _tasks.add(task);
    notifyListeners();
    unawaited(Future<void>.microtask(_drain));
    return task;
  }

  void cancel(DownloadTask task) {
    if (_disposed || !_tasks.contains(task) || !task.pending) return;
    task._cancelled = true;
    if (task.state == DownloadTaskState.queued) {
      task._state = DownloadTaskState.cancelled;
      task._finished.complete();
    } else {
      task._state = DownloadTaskState.stopping;
    }
    task._revision++;
    notifyListeners();
  }

  DownloadTask retry(DownloadTask task) {
    if (task.pending) throw const SourceException('请等待当前任务结束');
    return enqueue(
      task.book,
      task.remaining,
      refreshCached: task.refreshCached,
    );
  }

  void remove(DownloadTask task) {
    if (_disposed || task.pending) return;
    if (_tasks.remove(task)) notifyListeners();
  }

  Future<void> _drain() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (!_disposed) {
        final task = _tasks
            .where((task) => task.state == DownloadTaskState.queued)
            .firstOrNull;
        if (task == null) break;
        task._state = DownloadTaskState.running;
        task._revision++;
        notifyListeners();
        try {
          await execute(
            task.book,
            task.chapters,
            refreshCached: task.refreshCached,
            isCancelled: () => _disposed || task._cancelled,
            onProgress: (chapter, error) {
              if (_disposed) return;
              task._results[chapter.id] = error;
              if (error == null) {
                task._failures.remove(chapter.id);
              } else {
                task._failures[chapter.id] = error;
              }
              task._chapterTitle = chapter.title;
              task._revision++;
              notifyListeners();
            },
          );
        } catch (error) {
          task._error = error;
        }
        task._state = _disposed || task._cancelled
            ? DownloadTaskState.cancelled
            : task.error != null ||
                  task.failed > 0 ||
                  task.done != task.chapters.length
            ? DownloadTaskState.failed
            : DownloadTaskState.completed;
        task._revision++;
        _cacheRevision++;
        if (!task._finished.isCompleted) task._finished.complete();
        if (!_disposed) {
          final completed = _tasks
              .where((t) => t.state == DownloadTaskState.completed)
              .toList();
          for (final old in completed.take(
            (completed.length - 50).clamp(0, completed.length),
          )) {
            _tasks.remove(old);
          }
          notifyListeners();
        }
      }
    } finally {
      _draining = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final task in _tasks.where((task) => task.pending)) {
      task._cancelled = true;
      if (task.state == DownloadTaskState.queued) {
        task._state = DownloadTaskState.cancelled;
        task._finished.complete();
      }
    }
    super.dispose();
  }
}
