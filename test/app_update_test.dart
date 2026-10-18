import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/app_update.dart';
import 'helpers/app_release.dart';

void main() {
  AppUpdates updatesFor(http.Response response) {
    final updates = AppUpdates(
      clientFactory: () => MockClient((request) async {
        expect(request.url, AppUpdates.latestRelease);
        expect(request.url.host, 'api.github.com');
        expect(request.headers['Accept'], 'application/vnd.github+json');
        return response;
      }),
    );
    addTearDown(updates.close);
    return updates;
  }

  AppUpdates withRelease(Map<String, dynamic> json) =>
      updatesFor(jsonResponse(json));

  test('直连 GitHub 检查正式版并解析两个平台的发布包', () async {
    final release = (await withRelease(releaseJson()).check('0.3.2'))!;
    expect(release.version.toString(), '0.4.0');
    expect(release.notes, '更新说明：修复阅读问题');
    expect(release.downloads.keys, containsAll(UpdatePlatform.values));
    expect(
      release.downloads[UpdatePlatform.android]!.path,
      endsWith('/unr-0.4.0-android-universal.apk'),
    );
    expect(
      release.downloads[UpdatePlatform.windows]!.path,
      endsWith('/unr-0.4.0-windows-x64.zip'),
    );
  });

  test('按数值比较版本，忽略本地构建号，避免重复更新及降级', () async {
    for (final current in ['0.4.0', '0.4.0+4', '0.5.0', '1.0.0-rc.1']) {
      expect(await withRelease(releaseJson()).check(current), isNull);
    }
    expect(
      await withRelease(releaseJson(version: '0.10.0')).check('0.9.0'),
      isNotNull,
    );
    expect(await withRelease(releaseJson()).check('0.4.0-rc.1'), isNotNull);
  });

  test('拒绝草稿、预发布、异常版本与损坏响应', () async {
    for (final json in [
      {...releaseJson(), 'draft': true},
      {...releaseJson(), 'prerelease': true},
      releaseJson(version: '0.5.0-rc.1'),
      {...releaseJson(), 'tag_name': 'latest'},
      {...releaseJson(), 'assets': null},
      {...releaseJson(), 'tag_name': null},
    ]) {
      await expectLater(
        withRelease(json).check('0.3.2'),
        throwsA(isA<AppUpdateException>()),
      );
    }
    for (final body in ['<html>错误</html>', '[]', 'null']) {
      await expectLater(
        updatesFor(http.Response.bytes(utf8.encode(body), 200)).check('0.3.2'),
        throwsA(isA<AppUpdateException>()),
      );
    }
    await expectLater(
      withRelease(releaseJson()).check('开发版'),
      throwsA(isA<AppUpdateException>()),
    );
  });

  test('缺失、空包、未上传、非本项目及异常地址不提供下载', () async {
    for (final change in [
      {'name': 'unr-0.3.0-windows-x64.zip'},
      {'size': 0},
      {'state': 'new'},
      {'browser_download_url': 'https://other.example/update.zip'},
      {
        'browser_download_url':
            'https://github.com/other/repo/releases/download/v0.4.0/unr-0.4.0-windows-x64.zip',
      },
      {
        'browser_download_url':
            'http://github.com/moranfanhua/UniversalNovelReader/releases/download/v0.4.0/unr-0.4.0-windows-x64.zip',
      },
      {'browser_download_url': null},
    ]) {
      final json = releaseJson();
      final asset = (json['assets'] as List).first as Map;
      json['assets'] = [
        null,
        {...asset, ...change},
      ];
      final release = (await withRelease(json).check('0.3.2'))!;
      expect(release.downloads, isEmpty, reason: '$change');
    }
    final release = (await withRelease({
      ...releaseJson(),
      'assets': [],
      'body': null,
    }).check('0.3.2'))!;
    expect(release.downloads, isEmpty);
    expect(release.notes, isEmpty);
  });

  test('未发布、限流与服务器错误均提示失败，可再次检查', () async {
    for (final status in [404, 403, 429, 500]) {
      final updates = updatesFor(http.Response('', status));
      await expectLater(
        updates.check('0.3.2'),
        throwsA(isA<AppUpdateException>()),
      );
      await expectLater(
        updates.check('0.3.2'),
        throwsA(isA<AppUpdateException>()),
      );
    }
  });

  test('网络超时与连接失败转换为可读错误，结束后可重试', () async {
    var calls = 0;
    final updates = AppUpdates(
      clientFactory: () => MockClient((_) async {
        if (calls++ == 0) throw TimeoutException('timeout');
        if (calls == 2) throw http.ClientException('offline');
        return jsonResponse(releaseJson());
      }),
    );
    addTearDown(updates.close);
    await expectLater(
      updates.check('0.3.2'),
      throwsA(
        isA<AppUpdateException>().having(
          (e) => e.message,
          'message',
          contains('超时'),
        ),
      ),
    );
    await expectLater(
      updates.check('0.3.2'),
      throwsA(
        isA<AppUpdateException>().having(
          (e) => e.message,
          'message',
          contains('网络'),
        ),
      ),
    );
    expect(await updates.check('0.3.2'), isNotNull);
  });

  test('检查过程中禁止重复请求', () async {
    final response = Completer<http.Response>();
    var calls = 0;
    final updates = AppUpdates(
      clientFactory: () => MockClient((_) {
        calls++;
        return response.future;
      }),
    );
    addTearDown(updates.close);
    final pending = updates.check('0.3.2');
    await expectLater(
      updates.check('0.3.2'),
      throwsA(isA<AppUpdateException>()),
    );
    response.complete(jsonResponse(releaseJson()));
    expect(await pending, isNotNull);
    expect(calls, 1);
  });
}
