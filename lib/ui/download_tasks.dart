import 'package:flutter/material.dart';
import '../data/download_queue.dart';
import '../data/library.dart';
import 'chapter_download_dialog.dart';

class DownloadTasksView extends StatelessWidget {
  const DownloadTasksView({super.key, required this.library});
  final Library library;

  void _retry(BuildContext context, DownloadTask task) {
    try {
      library.downloadQueue.retry(task);
      library.downloadQueue.remove(task);
    } catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加入队列失败：$error')));
    }
  }

  void _showFailures(BuildContext context, DownloadTask task) {
    final failures = task.failures;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下载失败详情'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Text(
              [
                if (task.error != null) '${task.error}',
                for (final chapter in task.chapters)
                  if (failures.containsKey(chapter.id))
                    '${chapter.title}：${failures[chapter.id]}',
              ].join('\n'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: library.downloadQueue,
    builder: (context, _) {
      final tasks = library.downloadQueue.tasks
          .where((task) => task.state != DownloadTaskState.completed)
          .toList();
      final waiting = tasks
          .where((task) => task.state == DownloadTaskState.queued)
          .toList();
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: tasks.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '暂无下载任务\n完成的书籍可在“已下载”中查看。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(24),
                  itemCount: tasks.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return const Text('任务在应用运行期间按顺序下载，离开页面后会继续。');
                    }
                    final task = tasks[index - 1];
                    final status = switch (task.state) {
                      DownloadTaskState.queued =>
                        '排队中 · 第 ${waiting.indexOf(task) + 1} 位',
                      DownloadTaskState.running => '正在下载',
                      DownloadTaskState.stopping => '正在停止…',
                      DownloadTaskState.cancelled => '已停止',
                      DownloadTaskState.failed => '下载失败',
                      DownloadTaskState.completed => '下载完成',
                    };
                    final failures = task.failures;
                    final firstFailed = failures.isEmpty
                        ? null
                        : task.chapters
                              .where((c) => failures.containsKey(c.id))
                              .firstOrNull;
                    return Card(
                      key: ValueKey('download-task-${task.id}'),
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.book.title,
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${task.book.author} · ${library.sourceName(task.book)}',
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '$status · ${task.done} / ${task.chapters.length} 章',
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: task.done / task.chapters.length,
                            ),
                            const SizedBox(height: 8),
                            Text('成功 ${task.success} 章，失败 ${task.failed} 章'),
                            if (task.chapterTitle.isNotEmpty && task.pending)
                              Text(
                                task.chapterTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if (task.error != null) Text('${task.error}'),
                            if (firstFailed != null)
                              Text(
                                '${firstFailed.title}：${failures[firstFailed.id]}',
                              ),
                            Wrap(
                              spacing: 8,
                              children: [
                                if (failures.isNotEmpty || task.error != null)
                                  TextButton(
                                    onPressed: () =>
                                        _showFailures(context, task),
                                    child: const Text('失败详情'),
                                  ),
                                if (task.pending)
                                  TextButton(
                                    onPressed:
                                        task.state == DownloadTaskState.stopping
                                        ? null
                                        : () => library.downloadQueue.cancel(
                                            task,
                                          ),
                                    child: Text(
                                      task.state == DownloadTaskState.queued
                                          ? '取消排队'
                                          : '停止下载',
                                    ),
                                  )
                                else ...[
                                  if (task.remaining.isNotEmpty)
                                    TextButton(
                                      onPressed: () => _retry(context, task),
                                      child: const Text('重试未完成章节'),
                                    ),
                                  TextButton(
                                    onPressed: () => showChapterDownloadDialog(
                                      context,
                                      library: library,
                                      book: task.book,
                                      previousTask: task,
                                    ),
                                    child: const Text('下载设置'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        library.downloadQueue.remove(task),
                                    child: const Text('移除记录'),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      );
    },
  );
}
