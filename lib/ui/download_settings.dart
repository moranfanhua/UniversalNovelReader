import 'package:flutter/material.dart';
import '../data/download_mirror.dart';
import '../data/library.dart';

class DownloadSettings extends StatefulWidget {
  const DownloadSettings({super.key, required this.library});
  final Library library;

  @override
  State<DownloadSettings> createState() => _DownloadSettingsState();
}

class _DownloadSettingsState extends State<DownloadSettings> {
  late final address = TextEditingController(
    text: widget.library.downloadMirror.baseUrl,
  );
  bool saving = false;
  String? error, notice;

  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  Future<void> _save({bool? enabled, bool reset = false}) async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
      notice = null;
    });
    try {
      final mirror = reset
          ? DownloadMirror.defaults
          : DownloadMirror(
              enabled: enabled ?? widget.library.downloadMirror.enabled,
              // Toggling the switch preserves the saved address and any draft.
              baseUrl: enabled == null
                  ? address.text
                  : widget.library.downloadMirror.baseUrl,
            );
      await widget.library.setDownloadMirror(mirror);
      if (!mounted) return;
      if (enabled == null) address.text = mirror.baseUrl;
      setState(() => notice = '已保存，将用于下次下载。');
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) setState(() => error = '下载设置保存失败：$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.library,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('download-mirror-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('使用下载镜像'),
          subtitle: const Text('目前用于字体及其许可证下载，关闭后直接连接原始地址。'),
          value: widget.library.downloadMirror.enabled,
          onChanged: saving ? null : (value) => _save(enabled: value),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('download-mirror-address'),
          controller: address,
          enabled: !saving,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '镜像地址',
            hintText: DownloadMirror.defaultBaseUrl,
            helperText: '默认使用 GH-Proxy，可更换为兼容的 HTTPS 镜像地址。',
            helperMaxLines: 3,
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {
            error = null;
            notice = null;
          }),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton(
              key: const ValueKey('download-mirror-save'),
              onPressed: saving ? null : () => _save(),
              child: Text(saving ? '正在保存…' : '保存地址'),
            ),
            TextButton(
              onPressed: saving ? null : () => _save(reset: true),
              child: const Text('恢复默认下载设置'),
            ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (notice != null) ...[const SizedBox(height: 12), Text(notice!)],
      ],
    ),
  );
}
