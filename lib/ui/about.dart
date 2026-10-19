import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/app_update.dart';
import '../data/library.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({
    super.key,
    required this.library,
    this.updates,
    this.openUrl,
  });
  final Library library;
  final AppUpdates? updates;
  final Future<bool> Function(Uri)? openUrl;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final updates = widget.updates ?? AppUpdates();
  PackageInfo? info;
  String? versionError, updateMessage;
  bool loadingVersion = true, checking = false, prompting = false;

  String get versionLabel {
    final value = info;
    if (value == null) return versionError ?? '正在读取版本…';
    return value.buildNumber.isEmpty
        ? value.version
        : '${value.version}+${value.buildNumber}';
  }

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  @override
  void dispose() {
    updates.close();
    super.dispose();
  }

  Future<void> _loadVersion() async {
    setState(() {
      loadingVersion = true;
      versionError = null;
    });
    try {
      final value = await PackageInfo.fromPlatform();
      if (value.version.isEmpty) throw StateError('版本号为空');
      if (mounted) setState(() => info = value);
    } catch (_) {
      if (mounted) setState(() => versionError = '版本读取失败，点击重试');
    } finally {
      if (mounted) setState(() => loadingVersion = false);
    }
  }

  Future<void> _check() async {
    if (checking || prompting || info == null) return;
    setState(() {
      checking = true;
      updateMessage = null;
    });
    try {
      final release = await updates.check(info!.version);
      if (!mounted) return;
      if (release == null) {
        setState(() => updateMessage = '当前已是最新正式版本');
      } else {
        setState(() {
          checking = false;
          prompting = true;
          updateMessage = '发现新版本 ${release.version}';
        });
        await showDialog<void>(
          context: context,
          builder: (_) => _UpdateDialog(
            release: release,
            library: widget.library,
            openUrl: widget.openUrl ?? _openDownload,
          ),
        );
      }
    } on AppUpdateException catch (e) {
      if (mounted) setState(() => updateMessage = e.message);
    } catch (_) {
      if (mounted) setState(() => updateMessage = '检查更新失败，请稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          checking = false;
          prompting = false;
        });
      }
    }
  }

  static Future<bool> _openDownload(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('关于')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'UNR 阅读器',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.tag),
                    title: const Text('当前版本'),
                    subtitle: Text(versionLabel),
                    trailing: versionError == null
                        ? null
                        : const Icon(Icons.refresh),
                    onTap: versionError != null && !loadingVersion
                        ? _loadVersion
                        : null,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    key: const ValueKey('about-check-update'),
                    leading: const Icon(Icons.system_update_alt),
                    title: Text(checking ? '正在检查更新…' : '检查更新'),
                    subtitle: updateMessage == null
                        ? null
                        : Text(updateMessage!),
                    trailing: checking
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap:
                        loadingVersion || info == null || checking || prompting
                        ? null
                        : _check,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: const Text('开源许可'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: 'UNR 阅读器',
                      applicationVersion: info == null ? null : versionLabel,
                      applicationLegalese: 'AGPL-3.0\n非官方阅读器，作品与段评归相应权利人所有。',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({
    required this.release,
    required this.library,
    required this.openUrl,
  });
  final AppRelease release;
  final Library library;
  final Future<bool> Function(Uri) openUrl;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool opening = false;
  String? error;

  UpdatePlatform? get platform => switch (defaultTargetPlatform) {
    TargetPlatform.android => UpdatePlatform.android,
    TargetPlatform.windows => UpdatePlatform.windows,
    _ => null,
  };

  Future<void> _download(Uri original) async {
    if (opening) return;
    setState(() {
      opening = true;
      error = null;
    });
    try {
      final uri = widget.library.downloadMirror.resolve(original);
      final opened = await widget.openUrl(uri);
      if (!mounted) return;
      if (opened) {
        Navigator.pop(context);
      } else {
        setState(() => error = '无法打开下载链接，请重试');
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法打开下载链接，请重试');
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final download = widget.release.downloads[platform];
    return AlertDialog(
      title: Text('发现新版本 ${widget.release.version}'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.release.notes.isNotEmpty) ...[
            Text(widget.release.notes),
            const SizedBox(height: 16),
          ],
          Text(
            download == null
                ? platform == UpdatePlatform.android
                      ? '此版本暂未提供与当前应用架构匹配的 Android 安装包，请稍后重试。'
                      : '此版本暂未提供适用于当前平台的安装包，请稍后重试。'
                : platform == UpdatePlatform.windows
                ? '将在浏览器中下载 Windows 压缩包，解压后运行新版本。'
                : '将在浏览器中下载 Android 安装包，下载后打开以更新应用。',
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: opening ? null : () => Navigator.pop(context),
          child: const Text('稍后'),
        ),
        if (download != null)
          FilledButton(
            onPressed: opening ? null : () => _download(download),
            child: Text(opening ? '正在打开…' : '下载更新'),
          ),
      ],
    );
  }
}
