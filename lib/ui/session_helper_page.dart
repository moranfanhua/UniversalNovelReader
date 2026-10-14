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
  bool _busy = false, _ready = false, _installed = false, _appInstalled = false;
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
      final state = await SessionHelper.prepare(widget.source);
      if (mounted) {
        setState(() {
          _state = state;
          _installed = state['certificateInstalled'] == true;
          _appInstalled = state['appInstalled'] == true;
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

  Future<void> _complete() => _run(() async {
    final cookie = await SessionHelper.captureResult(widget.source);
    if (mounted && cookie != null)
      Navigator.pop(context, cookie);
    else if (mounted)
      setState(() => _message = '尚未取得完整 App 会话，请在官方 App 登录或进入账号页后返回');
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
    final canOpen = phase == 'capturing';
    return Scaffold(
      appBar: AppBar(title: Text('${widget.name} · VPN 辅助登录')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('启动 VPN 后打开${widget.name}官方 App，登录或进入账号页，再返回 UNR 验证并保存会话。'),
              const SizedBox(height: 16),
              const Text(
                '只转发所选官方 App 的流量，仅收集其认证域名中的会话 Cookie，不读取密码或请求正文。取得完整会话或退出后自动停止 VPN。',
              ),
              const SizedBox(height: 16),
              const Text(
                '官方 App 必须信任本机 CA 才能读取 HTTPS 会话。普通手机上，安装用户 CA 不保证可用；若 App 拒绝证书，将停止抓取并提示原因。',
              ),
              const SizedBox(height: 20),
              if (!SessionHelper.supported)
                const Text('此辅助目前仅支持 Android。')
              else ...[
                if (_ready && !_appInstalled)
                  Text('未找到${widget.name}官方 App，请先安装后返回。'),
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
                      _busy ||
                          !_installed ||
                          !_appInstalled ||
                          running ||
                          phase == 'captured'
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
                  onPressed: _busy || !canOpen || !_appInstalled
                      ? null
                      : () => _run(() => SessionHelper.openApp(widget.source)),
                  child: Text('打开${widget.name}官方 App'),
                ),
                FilledButton(
                  onPressed: _busy || phase != 'captured' ? null : _complete,
                  child: const Text('验证并保存 App 会话'),
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
                    '正在等待官方 App 请求，已识别 ${_state['requests'] ?? 0} 个认证域名请求',
                  'captured' => '已取得完整 App 会话，请验证并保存',
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
