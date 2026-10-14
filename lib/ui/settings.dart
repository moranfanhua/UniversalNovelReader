import 'package:flutter/material.dart';
import '../data/library.dart';
import 'reading_settings.dart';

class SoftwareSettingsPage extends StatefulWidget {
  const SoftwareSettingsPage({
    super.key,
    required this.library,
    required this.gbk,
    required this.onEncodingChanged,
  });
  final Library library;
  final bool gbk;
  final ValueChanged<bool> onEncodingChanged;

  @override
  State<SoftwareSettingsPage> createState() => _SoftwareSettingsPageState();
}

class _SoftwareSettingsPageState extends State<SoftwareSettingsPage> {
  late bool gbk = widget.gbk;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('软件设置')),
    body: SettingsPage(
      library: widget.library,
      gbk: gbk,
      onEncodingChanged: (value) {
        setState(() => gbk = value);
        widget.onEncodingChanged(value);
      },
    ),
  );
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.library,
    required this.gbk,
    required this.onEncodingChanged,
  });
  final Library library;
  final bool gbk;
  final ValueChanged<bool> onEncodingChanged;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('书架排序', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            DropdownButton<ShelfSort>(
              key: const ValueKey('shelf-sort'),
              value: library.shelfSort,
              isExpanded: true,
              items: [
                for (final sort in ShelfSort.values)
                  DropdownMenuItem(value: sort, child: Text(sort.label)),
              ],
              onChanged: (sort) async {
                if (sort == null) return;
                try {
                  await library.setShelfSort(sort);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('书架排序保存失败：$e')));
                  }
                }
              },
            ),
            Text(switch (library.shelfSort) {
              ShelfSort.updated => '按已获取的作品更新时间排序，本地小说按导入时间排序。',
              ShelfSort.name => '中文书名按无声调拼音的字典序升序排列，忽略英文大小写。',
              ShelfSort.lastActive => '最近打开或阅读的作品优先。',
            }),
            const Divider(height: 40),
            Text('阅读偏好', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ReadingSettings(library: library),
            const Divider(height: 40),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('按 GBK 编码导入 TXT'),
              subtitle: const Text('默认识别 UTF-8 / UTF-16 文本'),
              value: gbk,
              onChanged: onEncodingChanged,
            ),
          ],
        ),
      ),
    ),
  );
}
