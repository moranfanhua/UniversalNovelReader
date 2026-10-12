import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../sources/sfacg_markup.dart';

class CommentText extends StatelessWidget {
  const CommentText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var start = 0;
    for (final tag in SfacgMarkup.tags.allMatches(text)) {
      spans.add(TextSpan(text: text.substring(start, tag.start)));
      final url = SfacgMarkup.imageUrl(tag);
      spans.add(
        url == null
            ? TextSpan(text: tag[0])
            : WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Image.network(
                    url,
                    width: 32,
                    height: 32,
                    fit: BoxFit.contain,
                    semanticLabel: '表情 ${tag[2]} ${tag[3]}',
                    errorBuilder: (_, error, stack) => Tooltip(
                      message: tag[0]!,
                      child: const Icon(Icons.broken_image_outlined, size: 24),
                    ),
                  ),
                ),
              ),
      );
      start = tag.end;
    }
    spans.add(TextSpan(text: text.substring(start)));
    return SelectionArea(
      child: Text.rich(
        TextSpan(children: spans),
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.6),
      ),
    );
  }
}

class CommentCard extends StatelessWidget {
  const CommentCard({super.key, required this.comment, this.label});
  final ParagraphComment comment;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final avatar = SfacgMarkup.imageAddress(comment.avatar);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) ...[
            Text(label!, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              ClipOval(
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: avatar == null
                      ? const Icon(Icons.person_outline)
                      : Image.network(
                          avatar,
                          fit: BoxFit.cover,
                          semanticLabel: '${comment.author}的头像',
                          errorBuilder: (_, error, stack) =>
                              const Icon(Icons.person_outline),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      comment.author,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (comment.date.isNotEmpty)
                      Text(
                        comment.date.replaceAll('T', ' '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              if (comment.likes > 0) Text('♡ ${comment.likes}'),
            ],
          ),
          const SizedBox(height: 12),
          CommentText(comment.text),
        ],
      ),
    );
  }
}
