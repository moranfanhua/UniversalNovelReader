import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../sources/chapter_subscription_source.dart';

class ChapterSubscriptionDialog extends StatefulWidget {
  const ChapterSubscriptionDialog({
    super.key,
    required this.source,
    required this.book,
    required this.first,
  });
  final ChapterSubscriptionSource source;
  final Book book;
  final Chapter first;
  @override
  State<ChapterSubscriptionDialog> createState() =>
      _ChapterSubscriptionDialogState();
}

class _ChapterSubscriptionDialogState extends State<ChapterSubscriptionDialog> {
  final custom = TextEditingController();
  String choice = '20';
  ChapterSubscriptionQuote? quote;
  Object? error;
  bool busy = false, submitting = false;

  @override
  void dispose() {
    custom.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    if (busy) return;
    final count = choice == 'all'
        ? null
        : int.tryParse(choice == 'custom' ? custom.text : choice);
    if (choice != 'all' && (count == null || count < 1)) {
      setState(() => error = '请输入大于 0 的章节数量');
      return;
    }
    setState(() {
      busy = true;
      quote = null;
      error = null;
    });
    try {
      final result = await widget.source.prepareSubscription(
        widget.book,
        widget.first,
        count: count,
      );
      if (mounted) setState(() => quote = result);
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _confirm() async {
    final current = quote;
    if (busy || current == null) return;
    setState(() {
      busy = true;
      submitting = true;
      error = null;
      quote = null;
    });
    try {
      await current.confirm();
      if (mounted) Navigator.of(context).pop(true);
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !submitting,
    child: AlertDialog(
      title: const Text('订阅后续章节'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${widget.source.name} · ${widget.book.title}'),
              const SizedBox(height: 8),
              Text('从“${widget.first.title}”起，按目录顺序订阅；跳过免费和已订阅章节。'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final option in [
                    ('20', '20章'),
                    ('100', '100章'),
                    ('all', '全部'),
                    ('custom', '自定义'),
                  ])
                    ChoiceChip(
                      label: Text(option.$2),
                      selected: choice == option.$1,
                      onSelected: busy
                          ? null
                          : (_) => setState(() {
                              choice = option.$1;
                              quote = null;
                              error = null;
                            }),
                    ),
                ],
              ),
              if (choice == 'custom')
                TextField(
                  controller: custom,
                  enabled: !busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '章节数量'),
                  onChanged: (_) => setState(() {
                    quote = null;
                    error = null;
                  }),
                ),
              const SizedBox(height: 12),
              const Text('“全部”仅包含当前目录中从本章起的未订阅章节，不开启自动订阅。'),
              if (quote case final current?) ...[
                const Divider(),
                Text('实际订阅 ${current.chapters.length} 章'),
                Text('从：${current.chapters.first.title}'),
                Text('至：${current.chapters.last.title}'),
                Text(
                  '合计：${current.totalCost}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Text('确认后将使用当前平台账号余额订阅。'),
              ],
              if (busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                Text(submitting ? '正在订阅，请稍候…' : '正在获取章节权限与费用…'),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  '$error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        if (quote == null)
          FilledButton(
            onPressed: busy ? null : _prepare,
            child: const Text('获取订阅费用'),
          )
        else
          FilledButton(
            onPressed: busy ? null : _confirm,
            child: const Text('确认订阅'),
          ),
      ],
    ),
  );
}
