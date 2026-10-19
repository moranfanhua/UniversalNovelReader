import '../../domain/models.dart';
import '../account_source.dart';
import '../session_validation.dart';
import '../source_verification.dart';
import 'sfacg_api.dart';

mixin SfacgAccount {
  SfacgApi get api;

  Object? get accountSession => api.hasSession
      ? (api.cookies['.SFCommunity'], api.cookies['session_APP'])
      : null;

  Future<SourceAccount> getAccount() async {
    if (!api.hasSession) throw const SourceException('请先登录菠萝包');
    final session = accountSession;
    void checkSession() {
      if (accountSession != session) {
        throw const SourceException('菠萝包账号已切换，请重试');
      }
    }

    // Keep response Cookies isolated from the saved session, as in checkSession.
    final probe =
        SfacgApi(
            client: api.client,
            device: api.device,
            appUserAgent: api.appUserAgent,
          )
          ..clockOffset = api.clockOffset
          ..cookies.addAll(api.cookies);
    Future<dynamic> read(String path, {Map<String, String>? query}) async {
      try {
        return await probe.get(path, query: query);
      } on SourceException catch (error) {
        if (error is! SourceVerificationRequiredException &&
            error.code == 401 &&
            error.errorCode != 507) {
          throw const SessionExpiredException('菠萝包会话已失效，请重新登录');
        }
        rethrow;
      }
    }

    // APK AccountApi.getUser(expand) provides identity and growth level.
    final user = await read('user', query: {'expand': 'growup'});
    checkSession();
    final id = user is Map ? int.tryParse('${user['accountId']}') : null;
    if (id == 0 || !probe.hasSession) {
      throw const SessionExpiredException('菠萝包会话已失效，请重新登录');
    }
    if (id == null || id < 0) {
      throw const SourceException('菠萝包账号信息格式已变化，请重试');
    }
    final expand = user['expand'];
    final growup = expand is Map ? expand['growup'] : null;
    Map? money;
    String? notice;
    try {
      // APK AccountApi.getUserMoney -> AccountMoney. Both the mine page and
      // ConsCouponMainActivity use these balances, not Account.welfareCoin.
      final data = await read('user/money');
      if (data is! Map) throw const SourceException('菠萝包余额格式已变化');
      money = data;
    } on SessionExpiredException {
      rethrow;
    } on SourceVerificationRequiredException {
      rethrow;
    } catch (_) {
      notice = '平台余额暂未获取，可稍后重试';
    }
    checkSession();
    final fireMoney = AccountMetric.count('火券', money?['fireMoneyRemain']);
    final coupons = AccountMetric.count('代券', money?['couponsRemain']);
    if (notice == null && (fireMoney.value == '—' || coupons.value == '—')) {
      notice = '平台余额暂未完整获取，可稍后重试';
    }
    return SourceAccount(
      id: '$id',
      name: '${user['nickName'] ?? user['userName'] ?? ''}',
      avatar: accountAvatar(user['avatar']),
      metrics: [
        fireMoney,
        coupons,
        AccountMetric.count('成长等级', growup is Map ? growup['lv'] : null),
      ],
      notice: notice,
    );
  }
}
