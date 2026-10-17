import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sources/ciweimao/ciweimao_api.dart';
import '../sources/ciweimao/ciweimao_auth.dart';
import '../sources/ciweimao/ciweimao_session.dart';
import 'account_login_method.dart';

class CiweimaoAccountPage extends StatefulWidget {
  const CiweimaoAccountPage({super.key, required this.api, this.method});
  final CiweimaoApi api;
  final AccountLoginMethod? method;
  @override
  State<CiweimaoAccountPage> createState() => _CiweimaoAccountPageState();
}

class _CiweimaoAccountPageState extends State<CiweimaoAccountPage> {
  final account = TextEditingController(),
      password = TextEditingController(),
      phone = TextEditingController(),
      code = TextEditingController(),
      session = TextEditingController();
  late final auth = CiweimaoAuth(widget.api);
  Timer? timer;
  bool busy = false;
  int remaining = 0;
  String? message;

  Future<void> _open(AccountLoginMethod method) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CiweimaoAccountPage(api: widget.api, method: method),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _sendCode() => _run(() async {
    try {
      await auth.sendCode(phone.text);
      if (mounted) {
        code.clear();
        setState(() => message = '验证码已发送，请查看短信');
      }
    } finally {
      if (mounted) {
        timer?.cancel();
        setState(() => remaining = auth.resendSeconds);
        if (remaining > 0) {
          timer = Timer.periodic(const Duration(seconds: 1), (t) {
            if (!mounted) {
              t.cancel();
              return;
            }
            setState(() => remaining = auth.resendSeconds);
            if (remaining == 0) t.cancel();
          });
        }
      }
    }
  });

  Future<void> _login() => _run(() async {
    final candidate = switch (widget.method) {
      AccountLoginMethod.password => await auth.passwordLogin(
        account.text,
        password.text,
      ),
      AccountLoginMethod.sms => await auth.verifyCode(phone.text, code.text),
      _ => await auth.importSession(session.text),
    };
    if (!mounted) return;
    await widget.api.saveSession(candidate);
    if (mounted) {
      auth.clear();
      password.clear();
      code.clear();
      session.clear();
      setState(
        () => message = widget.api.sessionNotice ?? '刺猬猫登录成功，会话已保存在本机安全存储中',
      );
    }
  });

  Future<void> _logout() => _run(() async {
    await CiweimaoSession.logout(widget.api);
    if (mounted) {
      auth.clear();
      setState(() => message = '已清除本机刺猬猫会话');
    }
  });

  @override
  void dispose() {
    timer?.cancel();
    auth.clear();
    for (final c in [account, password, phone, code, session]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.method == null ? '刺猬猫账号' : '刺猬猫 · ${widget.method!.label}',
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(widget.api.hasSession ? '已保存刺猬猫登录会话' : '未登录 · 可阅读免费正文及公开段评'),
            const SizedBox(height: 20),
            if (widget.method == null)
              AccountLoginMethodList(
                onPassword: busy
                    ? null
                    : () => _open(AccountLoginMethod.password),
                onSms: busy ? null : () => _open(AccountLoginMethod.sms),
                onImport: busy ? null : () => _open(AccountLoginMethod.manual),
              ),
            if (widget.method == AccountLoginMethod.password) ...[
              TextField(
                controller: account,
                enabled: !busy,
                autocorrect: false,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: '手机号、邮箱或账号',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                enabled: !busy,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(
                  labelText: '密码',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : _login,
                child: const Text('登录刺猬猫'),
              ),
            ],
            if (widget.method == AccountLoginMethod.sms) ...[
              TextField(
                controller: phone,
                enabled: !busy,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumberNational],
                decoration: const InputDecoration(
                  labelText: '手机号（中国大陆）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: busy || remaining > 0 ? null : _sendCode,
                child: Text(remaining > 0 ? '$remaining 秒后重新获取' : '获取验证码'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: code,
                enabled: !busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                autofillHints: const [AutofillHints.oneTimeCode],
                decoration: const InputDecoration(
                  labelText: '短信验证码',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : _login,
                child: const Text('登录刺猬猫'),
              ),
            ],
            if (widget.method == AccountLoginMethod.manual) ...[
              const Text(
                '导入官方 App 会话 JSON，支持登录响应或包含 account、login_token、reader_id 的对象。',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: session,
                enabled: !busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'App 会话 JSON',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : _login,
                child: const Text('验证并保存会话'),
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              '仅阅读账号已有权限的章节，不自动购买。若需要安全验证，请先在官方 App 完成，再登录或导入 App 会话。',
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
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
