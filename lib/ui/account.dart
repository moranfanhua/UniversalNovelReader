import 'package:flutter/material.dart';
import '../data/library.dart';
import '../sources/sfacg/sfacg_session.dart';
import '../sources/fanqie/fanqie_source.dart';
import '../sources/session_helper.dart';
import 'fanqie_account.dart';
import 'session_helper_page.dart';
import 'account_login_method.dart';

class AccountSettingsPage extends StatelessWidget {
  const AccountSettingsPage({super.key, required this.library});
  final Library library;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('账号设置')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/sfacg_icon.jpg',
                    width: 44,
                    height: 44,
                    excludeFromSemantics: true,
                  ),
                ),
                title: Text(library.source.name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(library.source.name)),
                      body: AccountPage(library: library),
                    ),
                  ),
                ),
              ),
            ),
            for (final source
                in library.searchSources.whereType<FanqieSource>())
              Card(
                margin: const EdgeInsets.only(top: 16),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/fanqie_icon.webp',
                      width: 44,
                      height: 44,
                      excludeFromSemantics: true,
                    ),
                  ),
                  title: Text(source.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FanqieAccountPage(api: source.api),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.library, this.method});
  final Library library;
  final AccountLoginMethod? method;
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final account = TextEditingController(),
      password = TextEditingController(),
      cookie = TextEditingController();
  bool busy = false;
  String? message;

  Future<void> _openMethod(AccountLoginMethod method) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('菠萝包 · ${method.label}')),
          body: AccountPage(library: widget.library, method: method),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    account.dispose();
    password.dispose();
    cookie.dispose();
    super.dispose();
  }

  Future<void> authenticate({
    bool useCookie = false,
    bool website = false,
  }) async {
    final api = widget.library.source.api;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (useCookie) {
        await api.importCookie(cookie.text, website: website);
      } else {
        await api.login(account.text.trim(), password.text);
      }
      password.clear();
      cookie.clear();
      if (mounted) {
        setState(
          () => message =
              api.sessionNotice ??
              (api.websiteSession
                  ? '菠萝包官网登录成功，会话已保存在本机安全存储中'
                  : '菠萝包登录成功，会话已保存在本机安全存储中'),
        );
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
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
                    const SessionHelperPage(source: 'sfacg', name: '菠萝包'),
              ),
            )
          : await SessionHelper.openLogin('sfacg');
      if (mounted && value != null) {
        cookie.text = value;
        await authenticate(useCookie: true, website: true);
      }
    } catch (_) {
      if (mounted) setState(() => message = '无法打开网页登录，请重试或使用账号密码登录');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 660),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('菠萝包账号', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
            widget.library.source.api.hasSession
                ? '已保存登录会话'
                : '未登录 · 可阅读免费正文及公开段评',
          ),
          if (widget.library.source.api.websiteSession)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('官网会话使用官网已有章节阅读权限；发送段评、回复和点赞需要账号密码登录或导入 App 会话。'),
            ),
          const SizedBox(height: 12),
          if (widget.method == null)
            AccountLoginMethodList(
              onPassword: busy
                  ? null
                  : () => _openMethod(AccountLoginMethod.password),
              onWeb: !SessionHelper.supported || busy
                  ? null
                  : () => _openMethod(AccountLoginMethod.web),
              onVpn: !SessionHelper.supported || busy
                  ? null
                  : () => _webLogin(vpn: true),
            ),
          if (widget.method == AccountLoginMethod.web) ...[
            OutlinedButton.icon(
              onPressed: busy ? null : () => _webLogin(),
              icon: const Icon(Icons.public),
              label: const Text('打开官网登录'),
            ),
            const SizedBox(height: 12),
          ],
          if (widget.method == AccountLoginMethod.password) ...[
            TextField(
              controller: account,
              decoration: const InputDecoration(
                labelText: '账号',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '密码',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : () => authenticate(),
              child: const Text('登录菠萝包'),
            ),
            const SizedBox(height: 8),
            Text(
              SessionHelper.supported
                  ? '如需验证码或安全验证，请返回选择网页登录。'
                  : '如需验证码或安全验证，请在官方 App 完成后导入会话。',
            ),
          ],
          if (widget.method != null)
            ExpansionTile(
              title: const Text('导入 App 会话'),
              children: [
                TextField(
                  controller: cookie,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '.SFCommunity=…; session_APP=…',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: busy ? null : () => authenticate(useCookie: true),
                  child: const Text('验证并保存会话'),
                ),
              ],
            ),
          if (busy) const LinearProgressIndicator(),
          if (message != null ||
              widget.library.source.api.sessionNotice != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(message ?? widget.library.source.api.sessionNotice!),
            ),
          if (widget.method == null && widget.library.source.api.hasSession)
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      await SfacgSession.logout(widget.library.source.api);
                      if (mounted) setState(() => message = '已清除本机菠萝包会话');
                    },
              child: const Text('退出登录'),
            ),
        ],
      ),
    ),
  );
}
