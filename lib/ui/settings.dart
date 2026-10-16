import 'package:flutter/material.dart';
import '../data/library.dart';
import 'reading_settings.dart';
import 'platform_order.dart';
import 'logs.dart';
import 'theme_settings.dart';

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
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 660),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _entry(
            context,
            'appearance',
            '外观',
            Icons.palette_outlined,
            (_) => _SettingsSection(
              title: '外观设置',
              children: [ThemeSettings(library: library)],
            ),
          ),
          const SizedBox(height: 16),
          _entry(
            context,
            'shelf',
            '书架',
            Icons.library_books_outlined,
            (_) => _ShelfSettingsPage(library: library),
          ),
          const SizedBox(height: 16),
          _entry(
            context,
            'reading',
            '阅读',
            Icons.menu_book_outlined,
            (_) => _SettingsSection(
              title: '阅读设置',
              children: [ReadingSettings(library: library)],
            ),
          ),
          const SizedBox(height: 16),
          _entry(
            context,
            'search',
            '搜索',
            Icons.search,
            (_) => _SearchSettingsPage(library: library),
          ),
          const SizedBox(height: 16),
          _entry(
            context,
            'import',
            '导入',
            Icons.file_open_outlined,
            (_) => _ImportSettingsPage(
              gbk: gbk,
              onEncodingChanged: onEncodingChanged,
            ),
          ),
          const SizedBox(height: 16),
          _entry(
            context,
            'logs',
            '日志',
            Icons.receipt_long_outlined,
            (_) => const LogsPage(),
          ),
        ],
      ),
    ),
  );

  Widget _entry(
    BuildContext context,
    String id,
    String title,
    IconData icon,
    WidgetBuilder builder,
  ) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      key: ValueKey('settings-$id-entry'),
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: () =>
          Navigator.push<void>(context, MaterialPageRoute(builder: builder)),
    ),
  );
}

class _ShelfSettingsPage extends StatelessWidget {
  const _ShelfSettingsPage({required this.library});
  final Library library;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) => _SettingsSection(
      title: '书架设置',
      children: [
        Text('显示方式', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        SegmentedButton<ShelfLayout>(
          key: const ValueKey('shelf-layout'),
          segments: const [
            ButtonSegment(
              value: ShelfLayout.grid,
              icon: Icon(Icons.grid_view),
              label: Text('宫格'),
            ),
            ButtonSegment(
              value: ShelfLayout.list,
              icon: Icon(Icons.view_list_outlined),
              label: Text('列表'),
            ),
          ],
          selected: {library.shelfLayout},
          onSelectionChanged: (selected) async {
            try {
              await library.setShelfLayout(selected.single);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('显示方式保存失败：$e')));
              }
            }
          },
        ),
        const SizedBox(height: 28),
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
      ],
    ),
  );
}

class _SearchSettingsPage extends StatefulWidget {
  const _SearchSettingsPage({required this.library});
  final Library library;

  @override
  State<_SearchSettingsPage> createState() => _SearchSettingsPageState();
}

class _SearchSettingsPageState extends State<_SearchSettingsPage> {
  bool saving = false;
  String? error;

  Future<void> _toggle(String id, bool enabled) async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.library.setSearchSourceEnabled(id, enabled);
    } catch (e) {
      if (mounted) setState(() => error = '搜索设置保存失败：$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.library,
    builder: (context, _) => _SettingsSection(
      title: '搜索设置',
      children: [
        const Text('选择搜索书名或作者时参与搜索的平台'),
        const SizedBox(height: 12),
        for (final source in platformDisplayOrder(widget.library.searchSources))
          SwitchListTile(
            key: ValueKey('search-source-${source.id}'),
            contentPadding: EdgeInsets.zero,
            title: Text(source.name),
            value: widget.library.isSearchSourceEnabled(source.id),
            onChanged: saving ? null : (value) => _toggle(source.id, value),
          ),
        if (widget.library.enabledSearchSources.isEmpty)
          const Text('未选择搜索平台，请至少开启一个平台后再搜索。'),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}

class _ImportSettingsPage extends StatefulWidget {
  const _ImportSettingsPage({
    required this.gbk,
    required this.onEncodingChanged,
  });
  final bool gbk;
  final ValueChanged<bool> onEncodingChanged;

  @override
  State<_ImportSettingsPage> createState() => _ImportSettingsPageState();
}

class _ImportSettingsPageState extends State<_ImportSettingsPage> {
  late bool gbk = widget.gbk;

  @override
  Widget build(BuildContext context) => _SettingsSection(
    title: '导入设置',
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('按 GBK 编码导入 TXT'),
        subtitle: const Text('默认识别 UTF-8 / UTF-16 文本'),
        value: gbk,
        onChanged: (value) {
          setState(() => gbk = value);
          widget.onEncodingChanged(value);
        },
      ),
    ],
  );
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: ListView(padding: const EdgeInsets.all(24), children: children),
      ),
    ),
  );
}
