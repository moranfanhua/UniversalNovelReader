import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';
import 'package:unr/sources/novel_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_source.dart';
import 'package:unr/sources/saved_session_check.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/account.dart';
import 'package:unr/ui/home.dart';
import 'package:unr/ui/reader.dart';
import 'helpers/memory_library.dart';

class SessionFixture {
  final calls = <String, int>{};
  final expired = <String>{};
  final offline = <String>{};
  final gates = <String, Completer<void>>{};
  var saves = 0;
  late final client = MockClient((request) async {
    final id = switch (request.url.path) {
      '/user' => 'sfacg',
      '/passport/account/info/v2/' => 'fanqie',
      '/argus/api/v3/user/getaccountpage' => 'qidian',
      '/reader/get_my_info' => 'ciweimao',
      _ => throw StateError('不应请求其他接口'),
    };
    calls.update(id, (value) => value + 1, ifAbsent: () => 1);
    if (gates[id] case final gate?) await gate.future;
    if (offline.contains(id)) throw http.ClientException('synthetic offline');
    final invalid = expired.contains(id);
    final document = switch (id) {
      'sfacg' => {
        'status': {'httpCode': 200},
        'data': {'accountId': invalid ? 0 : 42},
      },
      'fanqie' =>
        invalid
            ? {
                'message': 'error',
                'data': {'name': 'session_expired'},
              }
            : {
                'message': 'success',
                'data': {'user_id': '42'},
              },
      'qidian' => {
        'Result': invalid ? -2 : 0,
        'Data': {
          'UserBasicInfo': {'UserId': 42},
        },
      },
      _ => {
        'code': invalid ? 200100 : 100000,
        'data': {
          'reader_info': {'account': 'synthetic-account', 'reader_id': '42'},
        },
      },
    };
    final body = jsonEncode(document);
    return http.Response(
      id == 'ciweimao' ? CiweimaoCrypto.encrypt(body) : body,
      200,
    );
  });
  late final sf = SfacgApi(client: client);
  late final fq = FanqieApi(client: client);
  late final qd = QidianApi(client: client);
  late final cat = CiweimaoApi(client: client);
  late final sources = <NovelSource>[
    SfacgSource(sf),
    FanqieSource(fq),
    QidianSource(qd),
    CiweimaoSource(cat),
  ];

  SessionFixture({bool loggedIn = true}) {
    fq.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});
    if (loggedIn) {
      sf.setCookie('.SFCommunity=synthetic; session_APP=synthetic');
      fq.setCookie('sessionid=synthetic');
      qd.credentials = QidianCredentials(
        userId: '42',
        ywGuid: '43',
        ywKey: 'synthetic-key',
        token: 'synthetic-token',
      );
      cat.restoreSession(
        CiweimaoCredentials(
          account: 'synthetic-account',
          token: 'synthetic-token-1234',
          readerId: '42',
        ),
      );
    }
    sf.onSessionChanged = fq.onSessionChanged = qd.onSessionChanged =
        cat.onSessionChanged = () async => saves++;
  }
  void close() => client.close();
}

class CachedLibrary extends TestLibrary with MemoryPersistence {
  CachedLibrary(SessionFixture fixture)
    : super(
        source: fixture.sources.first as SfacgSource,
        novelSources: fixture.sources.skip(1),
      );

  int reads = 0;
  @override
  Future<ShelfUpdateResult> refreshShelfBooks({
    String? shelfId,
    required bool Function() isCancelled,
  }) async => const ShelfUpdateResult();
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async {
    reads++;
    return const ChapterContent([Paragraph('已有本地缓存，检测期间仍可阅读')]);
  }
}

void main() {
  SessionFixture fixture({bool loggedIn = true}) {
    final value = SessionFixture(loggedIn: loggedIn);
    addTearDown(value.close);
    return value;
  }

  test('只检查已保存的账号，跳过未登录、旧网页会话和刺猬猫游客', () async {
    final value = fixture(loggedIn: false);
    value.sf.setCookie('.SFCommunity=synthetic-web', website: true);
    value.cat.restoreSession(
      CiweimaoCredentials(
        account: 'synthetic-guest',
        token: 'synthetic-token-1234',
        readerId: '42',
        guest: true,
      ),
    );
    expect(await checkSavedSessions(value.sources), isEmpty);
    expect(value.calls, isEmpty);
    expect(value.saves, 0);
  });

  test('四个平台并行检测，只报告确实失效的账号，不将断网判失效或写回存储', () async {
    final value = fixture();
    value.expired.addAll(['sfacg', 'ciweimao']);
    value.offline.add('fanqie');
    final gate = Completer<void>();
    for (final source in value.sources) {
      value.gates[source.id] = gate;
    }
    final checking = checkSavedSessions(value.sources);
    await Future<void>.delayed(Duration.zero);
    expect(value.calls, {'sfacg': 1, 'fanqie': 1, 'qidian': 1, 'ciweimao': 1});
    gate.complete();
    final results = await checking;
    expect(results.map((r) => r.sourceName), ['菠萝包轻小说', '刺猬猫阅读']);
    expect(results.every((r) => r.isCurrent), isTrue);
    value.sf.setCookie('.SFCommunity=new; session_APP=new');
    value.cat.restoreSession(null);
    expect(results.every((r) => !r.isCurrent), isTrue);
    expect(value.saves, 0);
    expect(value.qd.hasSession && value.fq.hasSession, isTrue);
  });

  for (final size in [const Size(320, 800), const Size(1400, 900)]) {
    testWidgets('启动汇总失效提示，可进入账号设置，$size 双倍文字不溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final value = fixture()
        ..expired.addAll(['sfacg', 'fanqie', 'qidian', 'ciweimao']);
      final library = CachedLibrary(value);
      addTearDown(library.dispose);
      await tester.pumpWidget(UnrApp(library: library));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(SnackBar)),
        ).scale(10),
        20,
      );
      expect(find.textContaining('登录会话已失效'), findsOneWidget);
      for (final source in value.sources) {
        expect(find.textContaining(source.name), findsOneWidget);
      }
      expect(value.calls.values, everyElement(1));
      await tester.tap(find.widgetWithText(TextButton, '账号设置'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountSettingsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(value.saves, 0);
    });
  }

  testWidgets('启动检测不阻塞缓存阅读，主题重建和回到前台不重复请求', (tester) async {
    final value = fixture();
    final gate = Completer<void>();
    for (final source in value.sources) {
      value.gates[source.id] = gate;
    }
    final library = CachedLibrary(value);
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await tester.pump();
    expect(find.byType(HomePage), findsOneWidget);
    expect(value.calls.length, 4);
    final context = tester.element(find.byType(HomePage));
    const book = Book(
      id: 'cached',
      title: '缓存作品',
      author: '作者',
      source: 'local',
      chapters: [Chapter(id: '1', title: '第一章')],
    );
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              ReaderPage(library: library, book: book, initialChapter: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(library.reads, 1);
    expect(find.textContaining('已有本地缓存'), findsOneWidget);
    await library.setThemeMode(AppThemeMode.dark);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();
    expect(value.calls.values, everyElement(1));
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('检测期间退出或更换账号不显示旧会话失效提示', (tester) async {
    final value = fixture()
      ..expired.addAll(['sfacg', 'fanqie', 'qidian', 'ciweimao']);
    final gate = Completer<void>();
    for (final source in value.sources) {
      value.gates[source.id] = gate;
    }
    final library = CachedLibrary(value);
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await tester.pump();
    value.sf.setCookie('.SFCommunity=new; session_APP=new');
    value.fq.setCookie('sessionid=new');
    value.qd.credentials = null;
    value.cat.restoreSession(null);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(value.saves, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出应用组件后检测返回不再通知', (tester) async {
    final value = fixture()..expired.add('qidian');
    final gate = Completer<void>();
    value.gates['qidian'] = gate;
    final library = CachedLibrary(value);
    addTearDown(library.dispose);
    await tester.pumpWidget(UnrApp(library: library));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
