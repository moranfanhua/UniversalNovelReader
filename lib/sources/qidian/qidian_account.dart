import '../../domain/models.dart';
import '../account_source.dart';
import 'qidian_api.dart';

mixin QidianAccount {
  QidianApi get api;

  Object? get accountSession => api.credentials;

  Future<SourceAccount> getAccount() async {
    final session = api.credentials;
    if (session == null) throw const SourceException('请先登录起点读书');
    // APK UserAccountItemBean: UserBasicInfo and AccountBalance.
    final data = await api.accountPage();
    if (api.credentials != session) {
      throw const SourceException('起点账号信息与当前账号不匹配，请重试');
    }
    final user = data['UserBasicInfo'] as Map;
    final balance = data['AccountBalance'];
    return SourceAccount(
      id: session.userId,
      name: '${user['NickName'] ?? ''}',
      avatar: accountAvatar(user['Head']),
      metrics: [
        AccountMetric.count(
          '起点币',
          balance is Map ? balance['QdBalance'] : null,
        ),
        AccountMetric.count(
          '月票',
          balance is Map ? balance['MonthTicket'] : null,
        ),
        AccountMetric.count('等级', user['LevelNumber']),
      ],
    );
  }
}
