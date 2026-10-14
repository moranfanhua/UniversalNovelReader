import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../sources/fanqie/fanqie_auth.dart';
import '../domain/models.dart';
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
  final phone = TextEditingController(), code = TextEditingController();
  late final auth = FanqieAuth(widget.api.client, widget.api.app);
  Timer? cooldown;
  int remaining = 0;
  String? sentPhone;
  bool pendingSmsSession = false;
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
    phone.dispose();
    code.dispose();
    cooldown?.cancel();
    auth.clear();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (busy || remaining > 0) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final normalized = FanqieAuth.mobile(phone.text);
      final seconds = await auth.sendCode(normalized);
      if (!mounted) return;
      setState(() {
        sentPhone = normalized;
        remaining = seconds;
        message = '验证码已发送，请查看短信';
      });
      cooldown?.cancel();
      cooldown = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || remaining <= 1) timer.cancel();
        if (mounted) setState(() => remaining--);
      });
    } catch (error) {
      if (mounted) setState(() => message = '$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _smsLogin() async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (FanqieAuth.mobile(phone.text) != sentPhone) {
        throw const SourceException('请先为当前手机号获取验证码');
      }
      final value = await auth.verifyCode(phone.text, code.text);
      if (mounted) {
        cookie.text = value;
        pendingSmsSession = true;
        await _import(appSession: true);
      }
    } catch (error) {
      if (mounted) setState(() => message = '$error');
    } finally {
      if (mounted) {
        code.clear();
        setState(() => busy = false);
      }
    }
  }

  Future<void> _import({bool appSession = false}) async {
    setState(() {
      busy = true;
      message = null;
    });
    final candidate = FanqieApi(client: widget.api.client);
    try {
      candidate.setCookie(cookie.text);
      if (appSession && widget.api.app.deviceId.isNotEmpty) {
        candidate.app.restore(widget.api.app.toJson());
      }
      await candidate.validateSession(appSession: appSession);
      widget.api.setCookie(candidate.cookie);
      if (appSession) widget.api.app.restore(candidate.app.toJson());
      await widget.api.onSessionChanged?.call();
      cookie.clear();
      pendingSmsSession = false;
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
      if (mounted) {
        setState(
          () => message = vpn
              ? '无法打开 App 会话辅助，请重试或手动导入会话'
              : '无法打开网页登录，请重试或手动导入会话',
        );
      }
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
                onSms: busy ? null : () => _openMethod(AccountLoginMethod.sms),
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
            if (widget.method == AccountLoginMethod.sms) ...[
              TextField(
                controller: phone,
                enabled: !busy,
                keyboardType: TextInputType.phone,
                autocorrect: false,
                autofillHints: const [AutofillHints.telephoneNumberNational],
                decoration: const InputDecoration(
                  labelText: '手机号',
                  prefixText: '+86 ',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) {
                  code.clear();
                  setState(() => message = null);
                },
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
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                autofillHints: const [AutofillHints.oneTimeCode],
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: '短信验证码',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : _smsLogin,
                child: const Text('登录并保存会话'),
              ),
              if (pendingSmsSession)
                OutlinedButton(
                  onPressed: busy ? null : () => _import(appSession: true),
                  child: const Text('重新验证登录会话'),
                ),
              TextButton(
                onPressed: busy || !SessionHelper.supported
                    ? null
                    : () => _webLogin(),
                child: const Text('改用网页登录'),
              ),
              const Text('如提示访问频繁或要求安全验证，请稍后重试或使用网页登录。'),
              const SizedBox(height: 12),
            ],
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
