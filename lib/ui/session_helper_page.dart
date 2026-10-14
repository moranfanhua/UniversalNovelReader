import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../sources/session_helper.dart';

class SessionHelperPage extends StatefulWidget {
  const SessionHelperPage({
    super.key,
    required this.source,
    required this.name,
  });
  final String source, name;
  @override
  State<SessionHelperPage> createState() => _SessionHelperPageState();
}

class _SessionHelperPageState extends State<SessionHelperPage>
    with WidgetsBindingObserver {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Map<String, dynamic> _state = {};
  bool _busy = false, _ready = false, _installed = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (SessionHelper.supported) {
      _subscription = SessionHelper.events.listen(
        (state) {
          if (mounted) setState(() => _state = state);
        },
        onError: (_) {
          if (mounted) setState(() => _message = '无法读取辅助状态，请重新进入');
        },
      );
      _prepare();
    }
  }

  Future<void> _prepare() async {
    try {
      final state = await SessionHelper.prepare();
      if (mounted) {
        setState(() {
          _state = state;
          _installed = state['certificateInstalled'] == true;
          _ready = true;
        });
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? '无法准备会话辅助');
    } on MissingPluginException {
      if (mounted) setState(() => _message = '当前安装包不支持会话辅助，请更新安装包');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !_busy &&
        SessionHelper.supported) {
      _prepare();
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? '会话辅助失败，请重试');
    } on MissingPluginException {
      if (mounted) setState(() => _message = '当前安装包不支持会话辅助，请更新安装包');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    String? filename;
    await _run(() async {
      filename = await SessionHelper.installCertificate();
    });
    if (!mounted || filename == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安装本机 CA 证书'),
        content: Text(
          '证书已导出至“下载/$filename”。\n\n在系统安全设置中选择“安装 CA 证书”，然后选择这个文件。安装后返回此页。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await _run(SessionHelper.certificateSettings);
            },
            child: const Text('打开系统设置'),
          ),
        ],
      ),
    );
  }

  Future<void> _openLogin() => _run(() async {
    final cookie = await SessionHelper.openLogin(widget.source, vpn: true);
    if (mounted && cookie != null) Navigator.pop(context, cookie);
  });

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    if (SessionHelper.supported) {
      unawaited(SessionHelper.stop().catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phase = _state['phase'];
    final running =
        phase == 'starting' || phase == 'capturing' || phase == 'stopping';
    final canOpen = phase == 'capturing' || phase == 'captured';
    return Scaffold(
      appBar: AppBar(title: Text('${widget.name}会话辅助')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('优先使用账号页的“网页登录”，无需安装证书。网页登录后无法自动取得会话时，可尝试此 VPN 辅助。'),
              const SizedBox(height: 16),
              const Text(
                '仅处理本阅读器中所选平台的网页登录请求，不抓取其他 App。会临时占用系统 VPN，取得会话或退出后自动停止。',
              ),
              const SizedBox(height: 20),
              if (!SessionHelper.supported)
                const Text('此辅助目前仅支持 Android。')
              else ...[
                Text(_installed ? '本机 CA 证书已安装' : '需要先安装本机 CA 证书'),
                if (_installed)
                  TextButton(
                    onPressed: _busy || running
                        ? null
                        : () => _run(SessionHelper.certificateSettings),
                    child: const Text('管理系统证书'),
                  ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy || !_ready || running ? null : _install,
                  child: const Text('安装本机抓包证书'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed:
                      _busy || !_installed || running || phase == 'captured'
                      ? null
                      : () => _run(() async {
                          final state = await SessionHelper.start(
                            widget.source,
                          );
                          if (mounted) setState(() => _state = state);
                        }),
                  child: const Text('启动 VPN 辅助'),
                ),
                OutlinedButton(
                  onPressed: _busy || !canOpen ? null : _openLogin,
                  child: const Text('打开官网登录'),
                ),
                if (running || phase == 'captured')
                  TextButton(
                    onPressed: _busy ? null : () => _run(SessionHelper.stop),
                    child: const Text('停止抓取'),
                  ),
                const SizedBox(height: 12),
                Text(switch (phase) {
                  'starting' => '正在启动 VPN…',
                  'stopping' => '正在停止 VPN…',
                  'capturing' =>
                    '正在等待网页登录，已识别 ${_state['requests'] ?? 0} 个平台请求',
                  'captured' => '已取得会话，请在网页登录页点击“完成并验证”',
                  'error' => '${_state['message'] ?? '辅助运行失败，请重试'}',
                  'stopped' => 'VPN 辅助已停止',
                  _ => _ready ? '准备就绪' : '正在准备本机证书…',
                }),
              ],
              if (_busy) const LinearProgressIndicator(),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_message!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
