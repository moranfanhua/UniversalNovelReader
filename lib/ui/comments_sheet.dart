import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../sources/sfacg_source.dart';
import 'comment_content.dart';

Future<void> showComments(
  BuildContext context,
  SfacgSource source,
  Chapter chapter,
  Paragraph paragraph,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => FractionallySizedBox(
    heightFactor: .85,
    child: CommentsSheet(
      source: source,
      chapter: chapter,
      paragraph: paragraph,
    ),
  ),
);

class CommentsSheet extends StatefulWidget {
  const CommentsSheet({
    super.key,
    required this.source,
    required this.chapter,
    required this.paragraph,
  });
  final SfacgSource source;
  final Chapter chapter;
  final Paragraph paragraph;
  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final items = <ParagraphComment>[];
  CommentSort sort = CommentSort.hot;
  int page = 0;
  bool loading = false, more = true;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.source.comments(
        widget.chapter,
        widget.paragraph.remoteIndex!,
        page: page,
        sort: sort,
      );
      if (!mounted) return;
      setState(() {
        final known = items.map((item) => item.id).toSet();
        items.addAll(result.where((item) => known.add(item.id)));
        page++;
        more = result.length == 20;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _replies(ParagraphComment comment) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: .85,
      child: RepliesSheet(source: widget.source, comment: comment),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('菠萝包 · 段评', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                IconButton(
                  tooltip: '关闭段评',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(
              widget.paragraph.text.isEmpty ? '本段插图' : widget.paragraph.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 14),
            SegmentedButton<CommentSort>(
              segments: const [
                ButtonSegment(value: CommentSort.hot, label: Text('最热')),
                ButtonSegment(value: CommentSort.latest, label: Text('最新')),
              ],
              selected: {sort},
              onSelectionChanged: loading
                  ? null
                  : (value) {
                      setState(() {
                        sort = value.single;
                        items.clear();
                        page = 0;
                        more = true;
                      });
                      _load();
                    },
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: items.length + 1,
          itemBuilder: (context, index) {
            if (index == items.length) {
              return _LoadStatus(
                loading: loading,
                error: error,
                empty: items.isEmpty,
                more: more,
                load: _load,
                emptyText: '这一段还没有吐槽',
              );
            }
            final item = items[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CommentCard(comment: item),
                  if (item.replies.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(left: 20, top: 10),
                      padding: const EdgeInsets.only(left: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            width: 2,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('回复预览'),
                          const SizedBox(height: 8),
                          for (final reply in SfacgSource.oldestFirst(
                            item.replies,
                          ).take(3))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: CommentCard(comment: reply),
                            ),
                        ],
                      ),
                    ),
                  if (item.replyCount > 0 || item.replies.isNotEmpty)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => _replies(item),
                        child: Text('查看 ${item.replyCount} 条回复'),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );
}

class RepliesSheet extends StatefulWidget {
  const RepliesSheet({super.key, required this.source, required this.comment});
  final SfacgSource source;
  final ParagraphComment comment;
  @override
  State<RepliesSheet> createState() => _RepliesSheetState();
}

class _RepliesSheetState extends State<RepliesSheet> {
  List<ParagraphComment> items = [];
  bool loading = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.source.allReplies(
        widget.comment.id,
        cancelled: () => !mounted,
      );
      if (mounted) setState(() => items = result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('回复', style: Theme.of(context).textTheme.titleLarge),
                  const Text('从旧到新', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
            IconButton(
              tooltip: '关闭回复',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      const Divider(),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: items.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: CommentCard(comment: widget.comment, label: '原段评'),
              );
            }
            if (index == items.length + 1) {
              return _LoadStatus(
                loading: loading,
                error: error,
                empty: items.isEmpty,
                more: false,
                load: load,
                emptyText: '暂无回复',
              );
            }
            return Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 14),
              child: CommentCard(comment: items[index - 1], label: '回复 $index'),
            );
          },
        ),
      ),
    ],
  );
}

class _LoadStatus extends StatelessWidget {
  const _LoadStatus({
    required this.loading,
    required this.error,
    required this.empty,
    required this.more,
    required this.load,
    required this.emptyText,
  });
  final bool loading, empty, more;
  final String? error;
  final String emptyText;
  final VoidCallback load;
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (error != null) {
      return Column(
        children: [
          Text(error!, textAlign: TextAlign.center),
          TextButton(onPressed: load, child: const Text('重试')),
        ],
      );
    }
    if (empty) return Center(child: Text(emptyText));
    if (more) return OutlinedButton(onPressed: load, child: const Text('加载更多'));
    return const SizedBox.shrink();
  }
}
