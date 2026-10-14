import 'package:flutter/material.dart';
import '../sources/fanqie/fanqie_api.dart';
import '../sources/fanqie/fanqie_session.dart';
import '../sources/session_helper.dart';
import 'session_helper_page.dart';
import 'account_login_method.dart';

class FanqieAccountPage extends StatefulWidget {
  const FanqieAccountPage({super.key, required this.api, this.method});
  final FanqieApi api;
  final AccountLoginMethod? method;
  @override
  State<FanqieAccountPage> createState() => _FanqieAccountPageState();
}

class _FanqieAccountPageState extends State<FanqieAccountPage> {
  final cookie = TextEditingController();
  bool busy = false;
  String? message;

  Future<void> _openMethod(AccountLoginMethod method) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => FanqieAccountPage(api: widget.api, method: method),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    cookie.dispose();
    super.dispose();
  }

  Future<void> _import({bool appSession = false}) async {
    setState(() {
      busy = true;
      message = null;
    });
    final candidate = FanqieApi(client: widget.api.client);
    try {
      candidate.setCookie(cookie.text);
      if (appSession && widget.api.app.deviceId.isNotEmpty)
        candidate.app.restore(widget.api.app.toJson());
      await candidate.validateSession(appSession: appSession);
      widget.api.setCookie(candidate.cookie);
      if (appSession) widget.api.app.restore(candidate.app.toJson());
      await widget.api.onSessionChanged?.call();
      cookie.clear();
      if (mounted) {
        setState(
          () => message = widget.api.sessionNotice ?? '番茄会话已验证并保存在本机安全存储中',
        );
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _logout() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await FanqieSession.logout(widget.api);
      if (mounted) setState(() => message = '已清除本机番茄会话');
    } catch (_) {
      if (mounted) setState(() => message = '无法清除本机安全存储，请稍后重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _webLogin({bool vpn = false}) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final value = vpn
          ? await Navigator.push<String>(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    const SessionHelperPage(source: 'fanqie', name: '番茄小说'),
              ),
            )
          : await SessionHelper.openLogin('fanqie');
      if (mounted && value != null) {
        cookie.text = value;
        await _import(appSession: vpn);
      }
    } catch (_) {
      if (mounted)
        setState(
          () => message = vpn
              ? '无法打开 App 会话辅助，请重试或手动导入会话'
              : '无法打开网页登录，请重试或手动导入会话',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.method == null ? '番茄小说账号' : '番茄小说 · ${widget.method!.label}',
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(widget.api.hasSession ? '已保存番茄登录会话' : '未登录 · 可阅读免费正文及公开段评'),
            const SizedBox(height: 12),
            if (widget.method == null)
              AccountLoginMethodList(
                onWeb: !SessionHelper.supported || busy
                    ? null
                    : () => _openMethod(AccountLoginMethod.web),
                onVpn: !SessionHelper.supported || busy
                    ? null
                    : () => _webLogin(vpn: true),
                onImport: SessionHelper.supported || busy
                    ? null
                    : () => _openMethod(AccountLoginMethod.manual),
              ),
            if (widget.method == AccountLoginMethod.web) ...[
              FilledButton.icon(
                onPressed: busy ? null : () => _webLogin(),
                icon: const Icon(Icons.public),
                label: const Text('打开官网登录'),
              ),
              const SizedBox(height: 12),
            ],
            if (widget.method != null) ...[
              const Text('会话验证成功后保存在本机安全存储中。'),
              const SizedBox(height: 20),
              ExpansionTile(
                title: const Text('手动导入会话'),
                initiallyExpanded: widget.method == AccountLoginMethod.manual,
                children: [
                  TextField(
                    controller: cookie,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '番茄 Cookie（包含 sessionid）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: busy ? null : _import,
                    child: const Text('验证并保存会话'),
                  ),
                ],
              ),
            ],
            if (busy) const LinearProgressIndicator(),
            if (message != null || widget.api.sessionNotice != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(message ?? widget.api.sessionNotice!),
              ),
            if (widget.method == null && widget.api.hasSession)
              TextButton(
                onPressed: busy ? null : _logout,
                child: const Text('退出登录'),
              ),
          ],
        ),
      ),
    ),
  );
}
