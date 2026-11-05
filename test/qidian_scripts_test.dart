import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/novel_source.dart';
import 'package:unr/sources/qidian/qidian_scripts.dart';

const uid = '00000000-0000-4000-8000-000000000001';
final now = DateTime.utc(2026, 10, 23);
Map<String, dynamic> file(int id) => {
  'id': id,
  'st': 1,
  'd': base64Encode(utf8.encode('synthetic-script-$id')),
};
String saved({List<Map<String, dynamic>> files = const [], int attempt = 0}) =>
    jsonEncode({
      'version': 1,
      'uid': uid,
      'attemptedAtMs': attempt,
      'files': files,
    });

void main() {
  test('脚本下载保留安装标识，只发送 FockRT 鉴权，先加载真实编号再保存', () async {
    String? stored;
    final operations = <Map<String, dynamic>>[];
    final provider = QidianSigningScripts(
      dispatch: (input) async {
        operations.add(input);
        if (input['op'] == 'script_auth') {
          expect(input['timestamp'], '${now.millisecondsSinceEpoch ~/ 1000}');
          expect(input['uid'], (jsonDecode(stored!) as Map)['uid']);
          return {
            'ok': true,
            'headers': {'Sign': 'synthetic-sign'},
          };
        }
        expect(input['id'], 2);
        expect((jsonDecode(stored!) as Map)['files'], isEmpty);
        return {'ok': true};
      },
      read: () async => stored,
      write: (value) async => stored = value,
      clock: () => now,
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://fockrt.yuewen.com/files?t=1');
        expect(request.followRedirects, isFalse);
        expect(request.headers.keys, isNot(contains('Cookie')));
        expect(request.headers['Sign'], 'synthetic-sign');
        expect(
          (jsonDecode(stored!) as Map)['attemptedAtMs'],
          now.millisecondsSinceEpoch,
        );
        return http.Response(
          jsonEncode({
            'status': 0,
            'data': [file(2)],
          }),
          200,
        );
      }),
    );
    addTearDown(provider.close);
    await provider.prepare('handle');
    expect(operations.map((op) => op['op']), ['script_auth', 'script_install']);
    expect((jsonDecode(stored!) as Map)['files'], [file(2)]);
  });

  test('启动更新上报缓存编号，网络失败继续使用原脚本', () async {
    var stored = saved(files: [file(2)]);
    final provider = QidianSigningScripts(
      dispatch: (input) async => input['op'] == 'script_auth'
          ? {'ok': true, 'headers': <String, String>{}}
          : {'ok': input['id'] == 2},
      read: () async => stored,
      write: (value) async => stored = value,
      clock: () => now,
      client: MockClient((request) async {
        expect(request.url.queryParametersAll['cs[]'], ['2']);
        throw http.ClientException('synthetic transport error');
      }),
    );
    addTearDown(provider.close);
    await provider.prepare('handle');
    expect((jsonDecode(stored) as Map)['files'], [file(2)]);
  });

  test('成功返回空配置时清除旧脚本，回到官方内置编号零', () async {
    var stored = saved(files: [file(2)]);
    final provider = QidianSigningScripts(
      dispatch: (input) async => input['op'] == 'script_auth'
          ? {'ok': true, 'headers': <String, String>{}}
          : {'ok': input['id'] == 0 && input['data'] == ''},
      read: () async => stored,
      write: (value) async => stored = value,
      clock: () => now,
      client: MockClient(
        (_) async => http.Response('{"status":0,"data":null}', 200),
      ),
    );
    addTearDown(provider.close);
    await provider.prepare('handle');
    expect((jsonDecode(stored) as Map)['files'], isEmpty);
  });

  test('新脚本无法执行时阻止请求，保留旧缓存并且不伪装编号零', () async {
    var stored = saved(files: [file(2)]);
    final ids = <int>[];
    final provider = QidianSigningScripts(
      dispatch: (input) async {
        if (input['op'] == 'script_auth') {
          return {'ok': true, 'headers': <String, String>{}};
        }
        ids.add(input['id'] as int);
        return {'ok': false};
      },
      read: () async => stored,
      write: (value) async => stored = value,
      clock: () => now,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': 0,
            'data': [file(3)],
          }),
          200,
        ),
      ),
    );
    addTearDown(provider.close);
    await expectLater(
      provider.prepare('handle'),
      throwsA(isA<SourceException>()),
    );
    expect(ids, [3]);
    expect((jsonDecode(stored) as Map)['files'], [file(2)]);
  });

  test('网络暂停期不发送脚本下载，也不覆盖缓存', () async {
    final initial = saved(files: [file(2)]);
    var writes = 0;
    final provider = QidianSigningScripts(
      dispatch: (_) async => {'ok': false, 'serviceCode': -4403},
      read: () async => initial,
      write: (_) async => writes++,
      clock: () => now,
      client: MockClient((_) async => fail('暂停期不应访问服务端')),
    );
    addTearDown(provider.close);
    await expectLater(
      provider.prepare('handle'),
      throwsA(isA<SourceAccessRestrictedException>()),
    );
    expect(writes, 0);
  });

  test('重启保留三分钟退避，离线模式只加载缓存', () async {
    for (final online in [false, true]) {
      var installs = 0;
      final provider = QidianSigningScripts(
        allowNetwork: online,
        dispatch: (input) async {
          expect(input['op'], 'script_install');
          expect(input['id'], 2);
          installs++;
          return {'ok': true};
        },
        read: () async =>
            saved(files: [file(2)], attempt: now.millisecondsSinceEpoch),
        write: (_) async => fail('退避期间不应覆盖缓存'),
        clock: () => now,
        client: MockClient((_) async => fail('退避期间不应访问服务端')),
      );
      await provider.prepare('handle');
      expect(installs, 1);
      provider.close();
    }
  });

  test('待处理的新脚本跨重启保留，退避期间仍拒绝回退旧编号', () async {
    final state =
        jsonDecode(saved(files: [file(2)], attempt: now.millisecondsSinceEpoch))
            as Map<String, dynamic>;
    state['pendingFiles'] = [file(3)];
    final ids = <int>[];
    final provider = QidianSigningScripts(
      dispatch: (input) async {
        expect(input['op'], 'script_install');
        ids.add(input['id'] as int);
        return {'ok': false};
      },
      read: () async => jsonEncode(state),
      write: (_) async => fail('退避期间不应覆盖待处理脚本'),
      clock: () => now,
      client: MockClient((_) async => fail('退避期间不应联网')),
    );
    addTearDown(provider.close);
    await expectLater(
      provider.prepare('handle'),
      throwsA(isA<SourceException>()),
    );
    expect(ids, [3]);
  });

  test('关闭后忽略迟到的更新，不加载也不写入新脚本', () async {
    final response = Completer<http.Response>();
    var stored = saved();
    final provider = QidianSigningScripts(
      dispatch: (_) async => {'ok': true, 'headers': <String, String>{}},
      read: () async => stored,
      write: (value) async => stored = value,
      clock: () => now,
      client: MockClient((_) => response.future),
    );
    final pending = provider.prepare('handle');
    await Future<void>.delayed(Duration.zero);
    provider.close();
    response.complete(
      http.Response(
        jsonEncode({
          'status': 0,
          'data': [file(2)],
        }),
        200,
      ),
    );
    await expectLater(pending, throwsA(isA<SourceException>()));
    expect((jsonDecode(stored) as Map)['files'], isEmpty);
  });

  test('非签名脚本、重复编号及损坏缓存均拒绝且不重新生成安装标识', () async {
    for (final invalid in [
      saved(
        files: [
          {'id': 2, 'st': 3, 'd': 'YQ=='},
        ],
      ),
      saved(files: [file(2), file(2)]),
      'broken-json',
    ]) {
      final provider = QidianSigningScripts(
        dispatch: (_) async => fail('损坏状态不应进入原生层'),
        read: () async => invalid,
        write: (_) async => fail('损坏状态不应被覆盖'),
        client: MockClient((_) async => fail('损坏状态不应访问服务端')),
      );
      await expectLater(
        provider.prepare('handle'),
        throwsA(isA<SourceException>()),
      );
      provider.close();
    }
  });
}
