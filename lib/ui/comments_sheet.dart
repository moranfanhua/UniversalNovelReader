import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../sources/sfacg_source.dart';

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
        items.addAll(result);
        page++;
        more = result.length == 20;
      });
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
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('菠萝包 · 段评', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(
              widget.paragraph.text.isEmpty ? '本段插图' : widget.paragraph.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
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
                  : (v) {
                      setState(() {
                        sort = v.single;
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
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const CircleAvatar(
                          radius: 16,
                          child: Icon(Icons.person_outline, size: 18),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            item.author,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text('♡ ${item.likes}'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SelectableText(item.text),
                    const SizedBox(height: 8),
                    Text(
                      item.date.replaceAll('T', ' '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (item.replies.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final r in item.replies)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text('${r.author}：${r.text}'),
                              ),
                          ],
                        ),
                      ),
                    if (item.replyCount > 0)
                      TextButton(
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          showDragHandle: true,
                          builder: (_) => FractionallySizedBox(
                            heightFactor: .7,
                            child: RepliesSheet(
                              source: widget.source,
                              comment: item,
                            ),
                          ),
                        ),
                        child: Text('查看 ${item.replyCount} 条回复'),
                      ),
                  ],
                ),
              ),
            if (error != null)
              Column(
                children: [
                  Text(error!, textAlign: TextAlign.center),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            if (loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              ),
            if (!loading && error == null && items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('这一段还没有吐槽')),
              ),
            if (!loading && error == null && more && items.isNotEmpty)
              OutlinedButton(onPressed: _load, child: const Text('加载更多')),
          ],
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
  final items = <ParagraphComment>[];
  int page = 0;
  bool loading = false, more = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final list = await widget.source.replies(widget.comment.id, page: page);
      if (mounted) {
        setState(() {
          items.addAll(list);
          page++;
          more = list.length == 20;
        });
      }
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
            Text('回复', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('${widget.comment.author}：${widget.comment.text}'),
            const Divider(),
            for (final r in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r.author),
                subtitle: Text(r.text),
                isThreeLine: true,
              ),
            if (error != null) Text(error!),
            if (loading) const Center(child: CircularProgressIndicator()),
            if (!loading && (more || error != null))
              TextButton(
                onPressed: load,
                child: Text(error != null ? '重试' : '加载更多'),
              ),
            if (!loading && error == null && items.isEmpty) const Text('暂无回复'),
          ],
        ),
      ),
    ],
  );
}
