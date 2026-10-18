import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sources/qidian/qidian_api.dart';
import '../sources/qidian/qidian_auth.dart';
import '../sources/qidian/qidian_captcha.dart';
import '../sources/qidian/qidian_session.dart';
import 'qidian_captcha.dart';
import 'account_login_method.dart';
import 'account_session_check.dart';

class QidianAccountPage extends StatefulWidget {
  const QidianAccountPage({
    super.key,
    required this.api,
    this.captchaSolver,
    this.method,
  });
  final QidianApi api;
  final QidianCaptchaSolver? captchaSolver;
  final AccountLoginMethod? method;
  @override
  State<QidianAccountPage> createState() => _QidianAccountPageState();
}

class _QidianAccountPageState extends State<QidianAccountPage> {
  final phone = TextEditingController(), code = TextEditingController();
  final account = TextEditingController(),
      password = TextEditingController(),
      session = TextEditingController();
  late final auth = QidianAuth(
    widget.api,
    solveCaptcha: (challenge) async {
      if (!mounted) return null;
      return widget.captchaSolver != null
          ? widget.captchaSolver!(challenge)
          : QidianCaptchaPage.solve(context, challenge);
    },
  );
  Timer? timer;
  bool busy = false;
  int remaining = 0;
  String? message;

  Future<void> _openMethod(AccountLoginMethod method) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => QidianAccountPage(
          api: widget.api,
          captchaSolver: widget.captchaSolver,
          method: method,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _cooldown() {
    timer?.cancel();
    remaining = auth.resendSeconds;
    if (remaining == 0) return;
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => remaining = auth.resendSeconds);
      if (remaining == 0) t.cancel();
    });
  }

  Future<void> _sendCode() async {
    if (busy || remaining > 0) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await auth.sendCode(phone.text);
      if (mounted) {
        code.clear();
        setState(() => message = '验证码已发送，请查看短信');
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) {
        _cooldown();
        setState(() => busy = false);
      }
    }
  }

  Future<void> _login() async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final credentials = switch (widget.method) {
        AccountLoginMethod.password => await auth.loginPassword(
          account.text,
          password.text,
        ),
        AccountLoginMethod.manual => await auth.importSession(session.text),
        _ => await auth.verifyCode(phone.text, code.text),
      };
      if (!mounted) return;
      await widget.api.saveSession(credentials);
      if (mounted) {
        auth.clear();
        code.clear();
        password.clear();
        session.clear();
        setState(
          () => message = widget.api.sessionNotice ?? '起点登录成功，会话已保存在本机安全存储中',
        );
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _logout() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await QidianSession.logout(widget.api);
      if (mounted) {
        auth.clear();
        code.clear();
        setState(() => message = '已清除本机起点会话');
      }
    } catch (_) {
      if (mounted) setState(() => message = '无法清除本机起点会话，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    auth.clear();
    phone.dispose();
    code.dispose();
    account.dispose();
    password.dispose();
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.method == null ? '起点读书账号' : '起点读书 · ${widget.method!.label}',
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(widget.api.hasSession ? '已保存起点登录会话' : '未登录 · 可阅读免费章节'),
            const SizedBox(height: 12),
            if (widget.method == null)
              AccountSessionCheck(
                session: widget.api.credentials,
                currentSession: () => widget.api.credentials,
                validate: widget.api.checkSession,
                enabled: !busy,
              ),
            if (widget.method == null)
              AccountLoginMethodList(
                onPassword: busy
                    ? null
                    : () => _openMethod(AccountLoginMethod.password),
                onSms: busy ? null : () => _openMethod(AccountLoginMethod.sms),
                onImport: busy
                    ? null
                    : () => _openMethod(AccountLoginMethod.manual),
              ),
            if (widget.method == AccountLoginMethod.password) ...[
              TextField(
                controller: account,
                enabled: !busy,
                autofillHints: const [AutofillHints.username],
                autocorrect: false,
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
                child: const Text('登录起点读书'),
              ),
            ],
            if (widget.method == AccountLoginMethod.sms) ...[
              TextField(
                controller: phone,
                enabled: !busy,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumberNational],
                autocorrect: false,
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
                child: const Text('登录起点读书'),
              ),
            ],
            if (widget.method == AccountLoginMethod.manual) ...[
              const Text(
                '导入官方 App 会话 JSON，需要包含 ywGuid 和 ywKey，验证成功后保存在本机安全存储中。',
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
            const Text('仅访问账号已有阅读权限的章节，不自动订阅或购买。'),
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
