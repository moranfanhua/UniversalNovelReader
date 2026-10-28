import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../data/library.dart';
import '../domain/models.dart';
import 'quote_card.dart';

Future<void> showQuoteShareSheet(
  BuildContext context, {
  required Library library,
  required Book book,
  required String quote,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  constraints: const BoxConstraints(maxWidth: 720),
  builder: (_) => FractionallySizedBox(
    heightFactor: .92,
    child: QuoteShareSheet(library: library, book: book, quote: quote),
  ),
);

class QuoteShareSheet extends StatefulWidget {
  const QuoteShareSheet({
    super.key,
    required this.library,
    required this.book,
    required this.quote,
  });
  final Library library;
  final Book book;
  final String quote;

  @override
  State<QuoteShareSheet> createState() => _QuoteShareSheetState();
}

class _QuoteShareSheetState extends State<QuoteShareSheet> {
  QuoteCardTheme theme = QuoteCardTheme.paper;
  ui.Image? cover;
  Uint8List? png;
  bool loading = false, busy = false, coverFailed = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    cover?.dispose();
    super.dispose();
  }

  Future<void> _prepare({bool placeholder = false}) async {
    if (loading || busy) return;
    setState(() {
      loading = true;
      error = null;
      coverFailed = false;
      png = null;
    });
    if (cover == null && widget.book.cover.isNotEmpty && !placeholder) {
      try {
        final bytes = await widget.library.loadImage(
          widget.book,
          widget.book.cover,
        );
        if (!mounted) return;
        final decoded = await decodeQuoteCover(bytes);
        if (!mounted) {
          decoded.dispose();
          return;
        }
        cover = decoded;
      } catch (_) {
        if (mounted) {
          setState(() {
            loading = false;
            coverFailed = true;
            error = '封面加载失败，请重试，或选择使用默认封面。';
          });
        }
        return;
      }
    }
    if (!mounted) return;
    try {
      final result = await renderQuoteCard(
        book: widget.book,
        quote: widget.quote,
        theme: theme,
        cover: cover,
        fontFamily: widget.library.readingFontFamily,
      );
      if (mounted) setState(() => png = result);
    } catch (e) {
      if (mounted) {
        setState(() => error = e is SourceException ? e.message : '图片生成失败，请重试');
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _export({required bool share, Rect? origin}) async {
    final bytes = png;
    if (bytes == null || busy || loading) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (share) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile.fromData(bytes, mimeType: 'image/png')],
            fileNameOverrides: [quoteCardFileName(widget.book)],
            title: '选句分享',
            sharePositionOrigin: origin,
          ),
        );
      } else {
        final path = await FilePicker.saveFile(
          fileName: quoteCardFileName(widget.book),
          bytes: bytes,
          mimeType: 'image/png',
          dialogTitle: '保存选句图片',
        );
        if (path != null && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('选句图片已保存')));
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = share ? '分享未完成，可重试或先保存图片。' : '图片保存失败，请重试。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '选句分享',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '关闭选句分享',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              for (final value in QuoteCardTheme.values)
                ChoiceChip(
                  label: Text(value.label),
                  avatar: CircleAvatar(
                    backgroundColor: value.background,
                    radius: 8,
                  ),
                  selected: theme == value,
                  onSelected: loading || busy
                      ? null
                      : (_) {
                          if (loading || busy) return;
                          setState(() => theme = value);
                          _prepare(placeholder: cover == null && png != null);
                        },
                ),
            ],
          ),
        ),
        Expanded(
          child: loading
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('正在生成分享图…'),
                    ],
                  ),
                )
              : png == null
              ? const Center(
                  child: Icon(Icons.image_not_supported_outlined, size: 48),
                )
              : SingleChildScrollView(
                  key: const ValueKey('quote-card-preview'),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Semantics(
                    image: true,
                    label:
                        '${widget.quote}\n《${widget.book.title}》\n${widget.book.author.trim().isEmpty ? '佚名' : widget.book.author} 著',
                    child: Image.memory(
                      png!,
                      fit: BoxFit.fitWidth,
                      width: 480,
                      excludeFromSemantics: true,
                    ),
                  ),
                ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (!loading && png == null)
          Wrap(
            spacing: 12,
            children: [
              TextButton(onPressed: () => _prepare(), child: const Text('重试')),
              if (coverFailed)
                TextButton(
                  onPressed: () => _prepare(placeholder: true),
                  child: const Text('使用默认封面'),
                ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: png == null || loading || busy
                    ? null
                    : () => _export(share: false),
                icon: const Icon(Icons.save_alt),
                label: const Text('保存图片'),
              ),
              Builder(
                builder: (context) => FilledButton.icon(
                  onPressed: png == null || loading || busy
                      ? null
                      : () {
                          final box = context.findRenderObject()! as RenderBox;
                          _export(
                            share: true,
                            origin: box.localToGlobal(Offset.zero) & box.size,
                          );
                        },
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share),
                  label: const Text('系统分享'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
