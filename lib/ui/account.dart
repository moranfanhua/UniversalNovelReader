import 'package:flutter/material.dart';
import '../data/library.dart';
import '../data/session.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.library,
    required this.gbk,
    required this.onEncodingChanged,
  });
  final Library library;
  final bool gbk;
  final ValueChanged<bool> onEncodingChanged;
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final account = TextEditingController(),
      password = TextEditingController(),
      cookie = TextEditingController();
  bool busy = false;
  String? message;
  @override
  void dispose() {
    account.dispose();
    password.dispose();
    cookie.dispose();
    super.dispose();
  }

  Future<void> authenticate({bool useCookie = false}) async {
    final api = widget.library.source.api;
    final old = Map<String, String>.from(api.cookies);
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (useCookie) {
        api.setCookie(cookie.text);
        await api.get('user');
        await api.onSessionChanged?.call();
      } else {
        await api.login(account.text.trim(), password.text);
      }
      password.clear();
      cookie.clear();
      if (mounted) {
        setState(() => message = api.sessionNotice ?? '菠萝包登录成功，会话已保存在本机安全存储中');
      }
    } catch (e) {
      api.cookies
        ..clear()
        ..addAll(old);
      await api.onSessionChanged?.call();
      if (mounted) setState(() => message = '$e');
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
          Text('阅读偏好', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
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
            selected: {widget.library.readingMode},
            onSelectionChanged: (value) async {
              setState(() => widget.library.readingMode = value.single);
              try {
                await widget.library.save();
              } catch (e) {
                if (mounted) setState(() => message = '阅读方式保存失败：$e');
              }
            },
          ),
          const SizedBox(height: 8),
          const Text('翻页模式支持左右滑动，也可使用上一页、下一页按钮。'),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('夜间模式'),
            value: widget.library.night,
            onChanged: (v) async {
              widget.library.night = v;
              await widget.library.save();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('按 GBK 编码导入 TXT'),
            subtitle: const Text('默认识别 UTF-8 / UTF-16 文本'),
            value: widget.gbk,
            onChanged: widget.onEncodingChanged,
          ),
          const Divider(height: 40),
          Text('菠萝包账号', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
            widget.library.source.api.hasSession
                ? '已保存登录会话'
                : '未登录 · 可阅读免费正文及公开段评',
          ),
          const SizedBox(height: 12),
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
          const Text('付费章节使用账号已有阅读权限。登录验证或验证码请在官方 App 完成。'),
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
          if (message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(message!),
            ),
          if (widget.library.source.api.hasSession)
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
