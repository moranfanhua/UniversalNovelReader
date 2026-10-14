import 'package:flutter/material.dart';
import '../domain/models.dart';

/// A sliver directory that keeps chapter rows lazy even for very large volumes.
class ChapterDirectory extends StatefulWidget {
  const ChapterDirectory({
    super.key,
    required this.chapters,
    required this.onChapterSelected,
    this.selectedChapter,
    this.cachedChapterIds = const {},
    this.enabled = true,
  });
  final List<Chapter> chapters;
  final ValueChanged<int> onChapterSelected;
  final int? selectedChapter;
  final Set<String> cachedChapterIds;
  final bool enabled;

  @override
  State<ChapterDirectory> createState() => _ChapterDirectoryState();
}

class _ChapterDirectoryState extends State<ChapterDirectory> {
  final expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final volumes = <({String name, int start, int end})>[];
    for (var i = 0; i < widget.chapters.length; i++) {
      final name = widget.chapters[i].volume.trim();
      // Keep consecutive ranges so repeated volume names cannot reorder a book.
      if (volumes.isEmpty || volumes.last.name != name) {
        volumes.add((name: name, start: i, end: i + 1));
      } else {
        final previous = volumes.removeLast();
        volumes.add((name: name, start: previous.start, end: i + 1));
      }
    }
    final rows = <({int volume, int? chapter})>[];
    for (var i = 0; i < volumes.length; i++) {
      rows.add((volume: i, chapter: null));
      final volume = volumes[i];
      if (expanded.contains(widget.chapters[volume.start].id)) {
        for (var chapter = volume.start; chapter < volume.end; chapter++) {
          rows.add((volume: i, chapter: chapter));
        }
      }
    }
    return SliverList.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final volume = volumes[row.volume];
        final chapterIndex = row.chapter;
        if (chapterIndex == null) {
          final id = widget.chapters[volume.start].id;
          final isExpanded = expanded.contains(id);
          final current = widget.selectedChapter;
          final selected =
              current != null &&
              current >= volume.start &&
              current < volume.end;
          return ListTile(
            key: ValueKey('directory-volume-$id'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: Icon(isExpanded ? Icons.expand_more : Icons.chevron_right),
            title: Text(volume.name.isEmpty ? '正文' : volume.name),
            subtitle: Text(
              '${volume.end - volume.start} 章${selected ? ' · 当前阅读' : ''}',
            ),
            selected: selected,
            onTap: () => setState(() {
              if (isExpanded) {
                expanded.remove(id);
              } else {
                expanded.add(id);
              }
            }),
          );
        }
        final chapter = widget.chapters[chapterIndex];
        return ListTile(
          key: ValueKey('directory-chapter-${chapter.id}'),
          contentPadding: const EdgeInsets.only(left: 40, right: 24),
          leading: Text('${chapterIndex + 1}'),
          title: Text(chapter.title),
          selected: widget.selectedChapter == chapterIndex,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.cachedChapterIds.contains(chapter.id))
                const Tooltip(
                  message: '已缓存',
                  child: Icon(Icons.download_done, size: 18),
                ),
              if (chapter.vip)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.lock_outline, size: 18),
                ),
            ],
          ),
          onTap: widget.enabled
              ? () => widget.onChapterSelected(chapterIndex)
              : null,
        );
      },
    );
  }
}
