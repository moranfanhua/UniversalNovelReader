import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('安全存储恢复设备标识、nonce 和两个 App Cookie', () async {
    final api = await SfacgSession.open();
    api.setCookie(
      '.SFCommunity=synthetic-community; session_APP=synthetic-session',
    );
    final nonce = api.nonce, device = api.device;
    await api.onSessionChanged!();
    final saved = jsonDecode(
      (await const FlutterSecureStorage().read(key: 'unr.sfacg.session.v1'))!,
    );
    expect(saved['nonce'], nonce);
    final restored = await SfacgSession.open();
    expect(restored.nonce, nonce);
    expect(restored.device, device);
    expect(restored.cookies, api.cookies);
    await SfacgSession.logout(restored);
    expect((await SfacgSession.open()).hasSession, isFalse);
    api.close();
    restored.close();
  });
}
