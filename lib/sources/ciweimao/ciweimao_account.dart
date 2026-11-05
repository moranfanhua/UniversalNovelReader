import '../../domain/models.dart';
import '../account_source.dart';
import '../session_validation.dart';
import 'ciweimao_api.dart';

mixin CiweimaoAccount {
  CiweimaoApi get api;

  Object? get accountSession => api.hasSession ? api.sessionGeneration : null;

  Future<SourceAccount> getAccount() async {
    final session = api.credentials;
    if (session == null || session.guest) {
      throw const SourceException('请先登录刺猬猫');
    }
    final generation = api.sessionGeneration;
    final Map<String, dynamic> data;
    try {
      data = await api.request('reader/get_my_info', {
        'reader_id': session.readerId,
      }, session: session);
    } on SourceException catch (error) {
      if (error.code == 200100 || error.code == 200001) {
        throw const SessionExpiredException('刺猬猫会话已失效，请重新登录');
      }
      rethrow;
    }
    api.checkSession(generation);
    final reader = data['reader_info'];
    if (reader is! Map ||
        '${reader['reader_id']}' != session.readerId ||
        '${reader['account']}' != session.account) {
      throw const SourceException('刺猬猫账号信息与当前账号不匹配，请重试');
    }
    // APK ReaderInfo and PropInfo, returned together by get_my_info.
    final props = data['prop_info'];
    return SourceAccount(
      id: session.readerId,
      name: '${reader['reader_name'] ?? session.name}',
      avatar:
          accountAvatar(reader['avatar_thumb_url']) ??
          accountAvatar(reader['avatar_url']),
      metrics: [
        AccountMetric.count('欢乐币', props is Map ? props['rest_hlb'] : null),
        AccountMetric.count('月票', props is Map ? props['rest_yp'] : null),
        AccountMetric.count('等级', reader['exp_lv']),
      ],
    );
  }
}
