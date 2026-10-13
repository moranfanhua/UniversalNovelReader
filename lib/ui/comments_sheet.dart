import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../sources/comment_source.dart';
import 'comment_content.dart';

Future<void> showComments(
  BuildContext context,
  CommentSource source,
  Chapter chapter,
  Paragraph paragraph, {
  Book? book,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: FractionallySizedBox(
      heightFactor: .85,
      child: CommentsSheet(
        source: source,
        chapter: chapter,
        paragraph: paragraph,
        book: book,
      ),
    ),
  ),
);

class CommentsSheet extends StatefulWidget {
  const CommentsSheet({
    super.key,
    required this.source,
    required this.chapter,
    required this.paragraph,
    this.book,
  });
  final CommentSource source;
  final Chapter chapter;
  final Paragraph paragraph;
  final Book? book;
  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  CommentLocation get location => CommentLocation(
    book: widget.book,
    chapter: widget.chapter,
    paragraph: widget.paragraph,
  );
  final items = <ParagraphComment>[];
  CommentSort sort = CommentSort.hot;
  String? cursor;
  bool loading = false, more = true;
  String? error;
  final draft = TextEditingController();
  bool sending = false;
  String? sendMessage;
  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final supportedSorts = widget.source.commentCapabilities.sorts;
    sort = supportedSorts.isEmpty ? CommentSort.latest : supportedSorts.first;
    _load();
  }

  Future<void> _load() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.source.commentPage(
        location,
        cursor: cursor,
        sort: sort,
      );
      if (!mounted) return;
      setState(() {
        final known = items.map((item) => item.id).toSet();
        items.addAll(result.items.where((item) => known.add(item.id)));
        cursor = result.nextCursor;
        more = cursor != null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _refresh({bool latest = false}) async {
    if (loading) return;
    setState(() {
      if (latest &&
          widget.source.commentCapabilities.sorts.contains(
            CommentSort.latest,
          )) {
        sort = CommentSort.latest;
      }
      items.clear();
      cursor = null;
      more = true;
    });
    await _load();
  }

  Future<void> _send() async {
    if (sending || loading) return;
    if (draft.text.trim().isEmpty) {
      setState(() => sendMessage = '请输入评论内容');
      return;
    }
    setState(() {
      sending = true;
      sendMessage = null;
    });
    try {
      await widget.source.publishComment(location, draft.text);
      if (!mounted) return;
      draft.clear();
      setState(() => sendMessage = '段评已发送');
      // Refresh failure must not turn an acknowledged send into a failed send.
      await _refresh(latest: true);
    } catch (e) {
      if (mounted) setState(() => sendMessage = '$e');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _replies(
    ParagraphComment comment, {
    bool compose = false,
    ParagraphComment? target,
  }) async {
    var changed = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: FractionallySizedBox(
          heightFactor: .85,
          child: RepliesSheet(
            source: widget.source,
            comment: comment,
            compose: compose,
            target: target,
            location: location,
            onSent: () => changed = true,
          ),
        ),
      ),
    );
    if (changed && mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !sending,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.source.name} · 段评',
                      style: Theme.of(context).textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新段评',
                    onPressed: loading || sending ? null : () => _refresh(),
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: '关闭段评',
                    onPressed: sending ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(
                widget.paragraph.text.isEmpty ? '本段插图' : widget.paragraph.text,
                maxLines: MediaQuery.viewInsetsOf(context).bottom > 0 ? 1 : 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 14),
              if (widget.source.commentCapabilities.sorts.length > 1)
                SegmentedButton<CommentSort>(
                  segments: [
                    for (final option
                        in widget.source.commentCapabilities.sorts)
                      ButtonSegment(
                        value: option,
                        label: Text(option == CommentSort.hot ? '最热' : '最新'),
                      ),
                  ],
                  selected: {sort},
                  onSelectionChanged: loading || sending
                      ? null
                      : (value) {
                          setState(() {
                            sort = value.single;
                            items.clear();
                            cursor = null;
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
                    CommentCard(
                      comment: item,
                      source: widget.source,
                      location: location,
                      root: item,
                      onReply:
                          sending ||
                              !widget.source.commentCapabilities.canReply(item)
                          ? null
                          : () => _replies(item, compose: true),
                    ),
                    if (widget.source.commentCapabilities.replies &&
                        item.replies.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(left: 20, top: 10),
                        padding: const EdgeInsets.only(left: 12),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              width: 2,
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text('回复预览'),
                            const SizedBox(height: 8),
                            for (final reply
                                in widget.source
                                    .orderedReplies(item.replies)
                                    .take(3))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: CommentCard(
                                  comment: reply,
                                  source: widget.source,
                                  location: location,
                                  root: item,
                                  onReply:
                                      sending ||
                                          !widget.source.commentCapabilities
                                              .canReply(reply)
                                      ? null
                                      : () => _replies(
                                          item,
                                          compose: true,
                                          target: reply,
                                        ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (widget.source.commentCapabilities.replies &&
                        (item.replyCount > 0 || item.replies.isNotEmpty))
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
        if (widget.source.commentCapabilities.post) const Divider(height: 1),
        if (widget.source.commentCapabilities.post)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.source.hasSession)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('paragraph-comment-draft'),
                            controller: draft,
                            enabled: !sending,
                            minLines: 1,
                            maxLines: 3,
                            textInputAction: TextInputAction.newline,
                            decoration: const InputDecoration(
                              hintText: '写下对这一段的评论…',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: sending || loading ? null : _send,
                          child: Text(sending ? '发送中…' : '发送'),
                        ),
                      ],
                    )
                  else
                    Text('请先在“我的 → 账号设置”中登录${widget.source.name}后发表评论'),
                  if (sendMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(sendMessage!),
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class RepliesSheet extends StatefulWidget {
  const RepliesSheet({
    super.key,
    required this.source,
    required this.comment,
    this.compose = false,
    this.target,
    this.onSent,
    required this.location,
  });
  final CommentSource source;
  final ParagraphComment comment;
  final bool compose;
  final ParagraphComment? target;
  final VoidCallback? onSent;
  final CommentLocation location;
  @override
  State<RepliesSheet> createState() => _RepliesSheetState();
}

class _RepliesSheetState extends State<RepliesSheet> {
  CommentLocation get location => widget.location;
  List<ParagraphComment> items = [];
  bool loading = false;
  String? error;
  final draft = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  bool sending = false;
  String? sendMessage;
  late ParagraphComment target;

  @override
  void dispose() {
    draft.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    target = widget.target ?? widget.comment;
    load();
  }

  void _replyTo(ParagraphComment comment) {
    if (sending) return;
    setState(() => target = comment);
    focus.requestFocus();
  }

  Future<void> _send() async {
    if (sending || loading) return;
    final content = draft.text.trim();
    if (content.isEmpty) {
      setState(() => sendMessage = '请输入回复内容');
      return;
    }
    setState(() {
      sending = true;
      sendMessage = null;
    });
    try {
      await widget.source.postReply(
        widget.comment,
        content,
        target: target,
        location: location,
      );
      widget.onSent?.call();
      if (!mounted) return;
      draft.clear();
      setState(() => sendMessage = '回复已发送');
      await load();
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        }
      });
    } catch (e) {
      if (mounted) setState(() => sendMessage = '$e');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> load() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.source.repliesFor(
        location,
        widget.comment,
        cancelled: () => !mounted,
      );
      if (mounted) setState(() => items = widget.source.orderedReplies(result));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !sending,
    child: Column(
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
                tooltip: '刷新回复',
                onPressed: loading || sending ? null : load,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '关闭回复',
                onPressed: sending ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            padding: const EdgeInsets.all(20),
            itemCount: items.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: CommentCard(
                    comment: widget.comment,
                    label: '原段评',
                    source: widget.source,
                    location: location,
                    root: widget.comment,
                    onReply:
                        sending ||
                            !widget.source.commentCapabilities.canReply(
                              widget.comment,
                            )
                        ? null
                        : () => _replyTo(widget.comment),
                  ),
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
                child: CommentCard(
                  comment: items[index - 1],
                  label: '回复 $index',
                  source: widget.source,
                  location: location,
                  root: widget.comment,
                  onReply:
                      sending ||
                          !widget.source.commentCapabilities.canReply(
                            items[index - 1],
                          )
                      ? null
                      : () => _replyTo(items[index - 1]),
                ),
              );
            },
          ),
        ),
        if (widget.source.commentCapabilities.reply) const Divider(height: 1),
        if (widget.source.commentCapabilities.reply)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.source.hasSession) ...[
                    Text(
                      '回复 @${target.author}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('comment-reply-draft'),
                            controller: draft,
                            focusNode: focus,
                            autofocus: widget.compose,
                            enabled: !sending,
                            minLines: 1,
                            maxLines: 3,
                            textInputAction: TextInputAction.newline,
                            decoration: const InputDecoration(
                              hintText: '写下回复…',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: sending || loading ? null : _send,
                          child: Text(sending ? '发送中…' : '发送回复'),
                        ),
                      ],
                    ),
                  ] else
                    Text('请先在“我的 → 账号设置”中登录${widget.source.name}后回复评论'),
                  if (sendMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(sendMessage!),
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
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
