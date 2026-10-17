import 'package:flutter/material.dart';

/// A comment attachment, or a small inline emoticon. Both can be enlarged.
class CommentImage extends StatelessWidget {
  const CommentImage({
    super.key,
    required this.url,
    this.label = '',
    this.inline = false,
    this.asset = false,
  });
  final String url, label;
  final bool inline, asset;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label.isEmpty ? '查看评论图片' : '查看表情 $label',
    child: InkWell(
      onTap: () => showDialog<void>(
        context: context,
        useSafeArea: false,
        builder: (context) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                tooltip: '关闭图片',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
              title: const Text('评论图片'),
            ),
            body: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: SizedBox.expand(
                child: _CommentImageBody(url: url, label: label, asset: asset),
              ),
            ),
          ),
        ),
      ),
      child: inline
          ? SizedBox.square(
              dimension: 32,
              child: _CommentImageBody(
                url: url,
                label: label,
                inline: true,
                asset: asset,
              ),
            )
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: SizedBox(
                width: double.infinity,
                height: 220,
                child: _CommentImageBody(url: url, label: label),
              ),
            ),
    ),
  );
}

class _CommentImageBody extends StatefulWidget {
  const _CommentImageBody({
    required this.url,
    required this.label,
    this.inline = false,
    this.asset = false,
  });
  final String url, label;
  final bool inline, asset;

  @override
  State<_CommentImageBody> createState() => _CommentImageBodyState();
}

class _CommentImageBodyState extends State<_CommentImageBody> {
  int attempt = 0;
  bool retrying = false;

  Future<void> retry() async {
    if (retrying) return;
    retrying = true;
    final url = widget.url;
    await _provider.evict();
    if (!mounted) return;
    setState(() {
      retrying = false;
      if (url == widget.url) attempt++;
    });
  }

  ImageProvider get _provider =>
      widget.asset ? AssetImage(widget.url) : NetworkImage(widget.url);

  @override
  Widget build(BuildContext context) => Image(
    image: _provider,
    key: ValueKey((widget.url, widget.asset, attempt)),
    fit: BoxFit.contain,
    semanticLabel: widget.label.isEmpty ? '评论图片' : widget.label,
    frameBuilder: (context, child, frame, synchronous) =>
        synchronous || frame != null
        ? child
        : Center(
            child: SizedBox.square(
              dimension: widget.inline ? 16 : 28,
              child: const CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: '图片加载中',
              ),
            ),
          ),
    loadingBuilder: (context, child, progress) => progress == null
        ? child
        : Center(
            child: SizedBox.square(
              dimension: widget.inline ? 16 : 28,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: progress.expectedTotalBytes == null
                    ? null
                    : progress.cumulativeBytesLoaded /
                          progress.expectedTotalBytes!,
                semanticsLabel: '图片加载中',
              ),
            ),
          ),
    errorBuilder: (context, error, stack) => widget.inline
        ? Tooltip(
            message: '${widget.label} 加载失败，点击重试',
            child: IconButton(
              padding: EdgeInsets.zero,
              onPressed: retry,
              icon: const Icon(Icons.broken_image_outlined, size: 24),
            ),
          )
        : Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image_outlined),
                const Text('图片加载失败'),
                TextButton(onPressed: retry, child: const Text('重试')),
              ],
            ),
          ),
  );
}
