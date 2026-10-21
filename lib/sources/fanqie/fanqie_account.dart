import '../../domain/models.dart';
import '../account_source.dart';
import 'fanqie_api.dart';

mixin FanqieAccount {
  FanqieApi get api;

  Object? get accountSession => api.hasSession ? api.cookie : null;

  Future<SourceAccount> getAccount() async {
    if (!api.hasSession) throw const SourceException('请先登录番茄小说');
    final session = api.cookie;
    final probe = FanqieApi(client: api.client)..setCookie(session);
    if (api.app.deviceId.isNotEmpty) probe.app.restore(api.app.toJson());
    final user = await probe.app.accountInfo();
    final id = '${user['user_id']}';
    if (api.cookie != session) throw const SourceException('番茄账号已切换，请重试');
    Map<String, dynamic>? info;
    try {
      // APK UserApiService.infoRxJava -> InfoData.active_day.
      final data = await probe.app.request('/reading/user/info/v/');
      if ('${data['user_id']}' != id) {
        throw const SourceException('番茄资料与当前账号不匹配');
      }
      info = data;
    } catch (_) {
      // Passport identity remains useful when optional platform data is down.
    }
    return SourceAccount(
      id: id,
      name: '${info?['user_name'] ?? user['screen_name'] ?? ''}',
      avatar:
          accountAvatar(info?['avatar_url']) ??
          accountAvatar(user['avatar_url']),
      metrics: [AccountMetric.count('活跃天数', info?['active_day'])],
      notice: info == null ? '平台资料暂未获取，可稍后重试' : null,
    );
  }
}
