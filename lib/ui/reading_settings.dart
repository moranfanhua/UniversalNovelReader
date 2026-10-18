import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../data/library.dart';
import '../data/reader_fonts.dart';
import '../domain/reading_preferences.dart';
import 'theme_settings.dart';

Future<void> showReadingSettings(BuildContext context, Library library) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text('阅读设置', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭阅读设置',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: [ReadingSettings(library: library)],
              ),
            ),
          ],
        ),
      ),
    );

class ReadingSettings extends StatefulWidget {
  const ReadingSettings({super.key, required this.library});
  final Library library;
  @override
  State<ReadingSettings> createState() => _ReadingSettingsState();
}

class _ReadingSettingsState extends State<ReadingSettings> {
  Library get library => widget.library;
  String? pendingFont, error;
  bool fontBusy = false, downloading = false;
  int received = 0;
  int? total;
  @override
  void dispose() {
    if (downloading) library.fonts.cancel();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await library.save();
    } catch (e) {
      if (mounted) setState(() => error = '阅读偏好保存失败：$e');
    }
  }

  Future<void> _font(String id, {bool download = false}) async {
    setState(() {
      fontBusy = true;
      downloading = download;
      error = null;
      received = 0;
      total = null;
    });
    try {
      if (download) {
        await library.downloadFont(
          id,
          onProgress: (bytes, size) {
            if (mounted) {
              setState(() {
                received = bytes;
                total = size;
              });
            }
          },
        );
      } else {
        await library.selectFont(id);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          fontBusy = false;
          downloading = false;
        });
      }
    }
  }

  Widget _slider(
    String label,
    String key,
    double value,
    double min,
    double max,
    int divisions,
    ValueChanged<double> update,
    String display,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [Text(label), const Spacer(), Text(display)]),
      // Keep the value indicator's portal inside this semantics subtree.
      // Flutter #190357: route/scroll updates can otherwise serialize orphans.
      Overlay.wrap(
        alwaysSizeToContent: true,
        clipBehavior: Clip.none,
        child: Slider(
          key: ValueKey(key),
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: display,
          onChanged: (value) => setState(() => update(value)),
          onChangeEnd: (_) => _save(),
        ),
      ),
    ],
  );
  Future<void> _license(String id) async {
    try {
      final text = await library.fonts.licenseText(id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${ReaderFonts.font(id).name} · 字体许可'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(child: SelectableText(text)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) {
      var selected = pendingFont ?? library.readingFontId;
      if (selected.isNotEmpty &&
          !ReaderFonts.catalog.any((font) => font.id == selected)) {
        selected = '';
      }
      final cached = library.downloadedFonts.contains(selected);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('阅读方式'),
          const SizedBox(height: 10),
          SegmentedButton<ReadingMode>(
            segments: const [
              ButtonSegment(
                value: ReadingMode.scroll,
                icon: Icon(Icons.swap_vert),
                label: Text('滚动阅读'),
              ),
              ButtonSegment(
                value: ReadingMode.paged,
                icon: Icon(Icons.swap_horiz),
                label: Text('翻页阅读'),
              ),
            ],
            selected: {library.readingMode},
            onSelectionChanged: (value) {
              setState(() => library.readingMode = value.single);
              _save();
            },
          ),
          const SizedBox(height: 16),
          if (library.readingMode == ReadingMode.paged) ...[
            const Text('翻页动画'),
            const SizedBox(height: 8),
            SegmentedButton<PageTurnAnimation>(
              key: const ValueKey('reading-page-turn-animation'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: PageTurnAnimation.none,
                  label: Text('无动画'),
                ),
                ButtonSegment(
                  value: PageTurnAnimation.simulation,
                  label: Text('仿真'),
                ),
                ButtonSegment(
                  value: PageTurnAnimation.slide,
                  label: Text('滑动'),
                ),
              ],
              selected: {library.pageTurnAnimation},
              onSelectionChanged: (value) {
                setState(() => library.pageTurnAnimation = value.single);
                _save();
              },
            ),
            const SizedBox(height: 16),
          ],
          SwitchListTile(
            key: const ValueKey('reading-paragraph-comments'),
            contentPadding: EdgeInsets.zero,
            title: const Text('显示段评'),
            value: library.showParagraphComments,
            onChanged: (value) {
              setState(() => library.showParagraphComments = value);
              _save();
            },
          ),
          if (library.showParagraphComments) ...[
            const Text('段评位置'),
            const SizedBox(height: 8),
            SegmentedButton<ParagraphCommentPlacement>(
              key: const ValueKey('reading-comment-placement'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: ParagraphCommentPlacement.right,
                  label: Text('固定右侧'),
                ),
                ButtonSegment(
                  value: ParagraphCommentPlacement.paragraphEnd,
                  label: Text('跟随段尾'),
                ),
              ],
              selected: {library.paragraphCommentPlacement},
              onSelectionChanged: (value) {
                setState(
                  () => library.paragraphCommentPlacement = value.single,
                );
                _save();
              },
            ),
            const SizedBox(height: 16),
          ],
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            SwitchListTile(
              key: const ValueKey('reading-volume-keys'),
              contentPadding: EdgeInsets.zero,
              title: const Text('音量键翻页'),
              subtitle: const Text('音量减翻下一页，音量加翻上一页'),
              value: library.volumeKeyPaging,
              onChanged: (value) {
                setState(() => library.volumeKeyPaging = value);
                _save();
              },
            ),
          const Text('阅读字体'),
          DropdownButton<String>(
            key: const ValueKey('reading-font'),
            value: selected,
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: '', child: Text('系统字体')),
              for (final font in ReaderFonts.catalog)
                DropdownMenuItem(
                  value: font.id,
                  child: Text(
                    '${font.name}${library.downloadedFonts.contains(font.id) ? ' · 已下载' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: fontBusy
                ? null
                : (id) {
                    if (id == null) return;
                    setState(() => pendingFont = id);
                    if (id.isEmpty || library.downloadedFonts.contains(id)) {
                      _font(id);
                    }
                  },
          ),
          if (selected.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: fontBusy
                        ? null
                        : () => _font(selected, download: !cached),
                    icon: Icon(
                      cached ? Icons.check : Icons.cloud_download_outlined,
                    ),
                    label: Text(cached ? '使用已下载字体' : '下载并使用字体'),
                  ),
                ),
                if (cached)
                  TextButton(
                    onPressed: () => _license(selected),
                    child: const Text('字体许可'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '来源：${ReaderFonts.font(selected).source} · SIL OFL 1.1\n下载后保存在本机，可离线使用。',
            ),
            if (ReaderFonts.font(selected).notice case final notice?) ...[
              const SizedBox(height: 8),
              Text(notice),
            ],
          ],
          if (fontBusy) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: downloading && total != null && total! > 0
                  ? (received / total!).clamp(0, 1)
                  : null,
            ),
            if (downloading)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '已下载 ${(received / 1024 / 1024).toStringAsFixed(1)} MB${total == null ? '' : ' / ${(total! / 1024 / 1024).toStringAsFixed(1)} MB'}',
                    ),
                  ),
                  TextButton(
                    onPressed: library.fonts.cancel,
                    child: const Text('取消下载'),
                  ),
                ],
              ),
          ],
          if (library.fontNotice != null) Text(library.fontNotice!),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          _slider(
            '字号',
            'reading-font-size',
            library.fontSize,
            14,
            32,
            18,
            (v) => library.fontSize = v,
            '${library.fontSize.round()}',
          ),
          _slider(
            '左右页边距',
            'reading-horizontal-margin',
            library.horizontalMargin,
            8,
            64,
            28,
            (v) => library.horizontalMargin = v,
            '${library.horizontalMargin.round()}',
          ),
          _slider(
            '上下页边距',
            'reading-vertical-margin',
            library.verticalMargin,
            8,
            48,
            20,
            (v) => library.verticalMargin = v,
            '${library.verticalMargin.round()}',
          ),
          _slider(
            '行间距',
            'reading-line-height',
            library.lineHeight,
            1.2,
            2.6,
            14,
            (v) => library.lineHeight = v,
            '${library.lineHeight.toStringAsFixed(1)} 倍',
          ),
          ThemeSettings(library: library),
          const SizedBox(height: 8),
          const Text('当前阅读效果'),
          const SizedBox(height: 8),
          Container(
            key: const ValueKey('reading-preview'),
            padding: EdgeInsets.symmetric(
              horizontal: library.horizontalMargin,
              vertical: library.verticalMargin,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Text(
              '天地玄黄，宇宙洪荒。\n愿你在故事中找到片刻宁静。',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: library.readingFontFamily,
                fontSize: library.fontSize,
                height: library.lineHeight,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: fontBusy
                ? null
                : () async {
                    setState(() {
                      pendingFont = '';
                      error = null;
                    });
                    try {
                      await library.resetReadingPreferences();
                    } catch (e) {
                      if (mounted) setState(() => error = '$e');
                    }
                  },
            child: const Text('恢复默认阅读设置'),
          ),
        ],
      );
    },
  );
}
