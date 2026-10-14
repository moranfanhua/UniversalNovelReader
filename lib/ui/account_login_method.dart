import 'package:flutter/material.dart';

enum AccountLoginMethod {
  password('账号密码登录'),
  web('网页登录'),
  manual('导入会话');

  const AccountLoginMethod(this.label);
  final String label;
}

class AccountLoginMethodList extends StatelessWidget {
  const AccountLoginMethodList({
    super.key,
    this.onPassword,
    this.onWeb,
    this.onVpn,
    this.onImport,
  });

  final VoidCallback? onPassword, onWeb, onVpn, onImport;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text('选择登录方式'),
        ),
      ),
      if (onPassword != null) _entry('账号密码登录', Icons.password, onPassword!),
      if (onWeb != null) _entry('网页登录', Icons.public, onWeb!),
      if (onVpn != null) _entry('VPN 辅助登录', Icons.vpn_lock, onVpn!),
      if (onImport != null) _entry('导入会话', Icons.key, onImport!),
    ],
  );

  Widget _entry(String title, IconData icon, VoidCallback onTap) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}
