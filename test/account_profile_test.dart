import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/account_source.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_source.dart';
import 'package:unr/sources/session_validation.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/account_platform_card.dart';

http.Response json(Object data) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), 200);

void main() {
  test('起点卡片读取 App 账户页的头像、ID、起点币、月票和等级，不写入会话', () async {
    var expired = false;
    final api =
        QidianApi(
            client: MockClient((request) async {
              expect(request.url.host, 'druidv6.if.qidian.com');
              expect(request.url.path, '/argus/api/v3/user/getaccountpage');
              expect(request.headers['QDSign'], isNotEmpty);
              return json({
                'Result': expired ? -2 : 0,
                'Data': {
                  'UserBasicInfo': {
                    'UserId': 42,
                    'NickName': '合成起点读者',
                    'Head': '//example.test/qidian.png',
                    'LevelNumber': 5,
                  },
                  'AccountBalance': {'QdBalance': 1234, 'MonthTicket': 0},
                },
              });
            }),
          )
          ..credentials = QidianCredentials(
            userId: '42',
            ywGuid: '42',
            ywKey: 'synthetic-key',
            token: 'synthetic-token',
          );
    addTearDown(api.close);
    var saves = 0;
    api.onSessionChanged = () async => saves++;
    final source = QidianSource(api);
    final session = source.accountSession;
    final account = await source.getAccount();
    expect(account.id, '42');
    expect(account.name, '合成起点读者');
    expect(account.avatar, 'https://example.test/qidian.png');
    expect(account.metrics.map((m) => m.value), ['1234', '0', '5']);
    expired = true;
    await expectLater(
      source.getAccount(),
      throwsA(isA<SessionExpiredException>()),
    );
    expect(source.accountSession, same(session));
    expect(saves, 0);
  });

  test('菠萝包按 App 余额接口读取火券和代券，不混用福利币且不覆盖登录', () async {
    final paths = <String>[];
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.url.host, 'api.sfacg.com');
        paths.add(request.url.path);
        expect(request.headers['sfsecurity'], isNotEmpty);
        if (request.url.path == '/user/money') {
          expect(request.headers['Cookie'], contains('session_APP=rotated'));
          return json({
            'status': {'httpCode': 200},
            'data': {'fireMoneyRemain': 800, 'couponsRemain': 20},
          });
        }
        expect(request.url.path, '/user');
        expect(request.url.queryParameters['expand'], 'growup');
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'status': {'httpCode': 200},
              'data': {
                'accountId': 42,
                'nickName': '合成菠萝包读者',
                'fireCoin': 9999,
                'avatar': 'http://example.test/sfacg.png',
                'expand': {
                  'welfareCoin': 8888,
                  'growup': {'lv': 9},
                },
              },
            }),
          ),
          200,
          headers: {'set-cookie': 'session_APP=rotated; Path=/'},
        );
      }),
    )..setCookie('.SFCommunity=synthetic; session_APP=synthetic-app');
    addTearDown(api.close);
    final source = SfacgSource(api);
    final session = source.accountSession;
    final account = await source.getAccount();
    expect(account.id, '42');
    expect(account.avatar, 'https://example.test/sfacg.png');
    expect(account.metrics.map((m) => m.label), ['火券', '代券', '成长等级']);
    expect(account.metrics.map((m) => m.value), ['800', '20', '9']);
    expect(account.notice, isNull);
    expect(paths, ['/user', '/user/money']);
    expect(source.accountSession, session);
  });

  test('菠萝包余额缺失或断网显示未知并可重试，不用福利币或零值填充', () async {
    var offline = true;
    final api = SfacgApi(
      client: MockClient((request) async {
        if (request.url.path == '/user') {
          return json({
            'status': {'httpCode': 200},
            'data': {
              'accountId': 42,
              'fireCoin': 9999,
              'expand': {
                'welfareCoin': 8888,
                'growup': {'lv': 9},
              },
            },
          });
        }
        expect(request.url.path, '/user/money');
        if (offline) throw http.ClientException('synthetic offline');
        return json({
          'status': {'httpCode': 200},
          'data': {'fireMoneyRemain': 0},
        });
      }),
    )..setCookie('.SFCommunity=synthetic; session_APP=synthetic-app');
    addTearDown(api.close);
    final source = SfacgSource(api);
    final offlineAccount = await source.getAccount();
    expect(offlineAccount.id, '42');
    expect(offlineAccount.metrics.map((m) => m.value), ['—', '—', '9']);
    expect(offlineAccount.notice, isNotNull);
    offline = false;
    final partial = await source.getAccount();
    expect(partial.metrics.map((m) => m.value), ['0', '—', '9']);
    expect(partial.notice, isNotNull);
    expect(api.hasSession, isTrue);
  });

  test('刺猬猫沿用 App 加签加密接口读取欢乐币、月票及等级', () async {
    final api =
        CiweimaoApi(
          client: MockClient((request) async {
            expect(request.url.path, '/reader/get_my_info');
            final form = Uri.splitQueryString(request.body);
            expect(form['p'], isNotEmpty);
            return http.Response(
              CiweimaoCrypto.encrypt(
                jsonEncode({
                  'code': 100000,
                  'data': {
                    'reader_info': {
                      'reader_id': '42',
                      'account': 'synthetic-account',
                      'reader_name': '合成刺猬猫读者',
                      'exp_lv': '6',
                      'avatar_thumb_url': '',
                      'avatar_url': 'https://example.test/cat.png',
                    },
                    'prop_info': {'rest_hlb': '2300', 'rest_yp': '3'},
                  },
                }),
              ),
              200,
            );
          }),
        )..restoreSession(
          CiweimaoCredentials(
            account: 'synthetic-account',
            token: 'synthetic-token-1234',
            readerId: '42',
          ),
        );
    addTearDown(api.close);
    final account = await CiweimaoSource(api).getAccount();
    expect(account.id, '42');
    expect(account.avatar, 'https://example.test/cat.png');
    expect(account.metrics.map((m) => m.value), ['2300', '3', '6']);
  });

  test('番茄仅请求 App 身份和资料，展示活跃天数且不请求钱包', () async {
    var failInfo = false;
    final paths = <String>[];
    final api = FanqieApi(
      client: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/passport/account/info/v2/') {
          return json({
            'message': 'success',
            'data': {
              'user_id': '42',
              'screen_name': '合成番茄读者',
              'avatar_url': 'https://example.test/fanqie.png',
            },
          });
        }
        expect(request.url.path, '/reading/user/info/v/');
        if (failInfo) throw http.ClientException('synthetic failure');
        return json({
          'code': 0,
          'data': {'user_id': '42', 'user_name': '番茄平台昵称', 'active_day': 123},
        });
      }),
    )..setCookie('sessionid=synthetic');
    api.app.restore({'deviceId': '1234567890', 'installId': '2345678901'});
    addTearDown(api.close);
    final source = FanqieSource(api);
    final account = await source.getAccount();
    expect(account.name, '番茄平台昵称');
    expect(account.metrics.single.value, '123');
    expect(account.metrics.single.label, '活跃天数');
    failInfo = true;
    final partial = await source.getAccount();
    expect(partial.id, '42');
    expect(partial.name, '合成番茄读者');
    expect(partial.metrics.single.value, '—');
    expect(partial.notice, isNotNull);
    expect(paths.any((path) => path.contains('wallet')), isFalse);
    expect(api.hasSession, isTrue);
  });

  test('缺失或无效数值显示未知，真实零值保留；头像地址拒绝凭据和非网络协议', () {
    for (final raw in [null, '', true, -1, 'invalid', 1.5]) {
      expect(AccountMetric.count('余额', raw).value, '—');
    }
    expect(AccountMetric.count('余额', '0').value, '0');
    expect(accountAvatar('https://user:password@example.test/a'), isNull);
    expect(accountAvatar('file:///private/avatar.png'), isNull);
  });

  testWidgets('未登录仅显示顶栏图标和未登录，并保留点击入口', (tester) async {
    final source = FakeAccountSource()..session = null;
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPlatformCard(
            source: source,
            onOpen: () async => opens++,
          ),
        ),
      ),
    );
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('合成读者'), findsNothing);
    expect(find.text('等级'), findsNothing);
    expect(find.byType(Image), findsNothing); // 起点使用现有矢量图标。
    expect(source.calls, 0);
    await tester.tap(find.text('未登录'));
    await tester.pump();
    expect(opens, 1);
  });

  testWidgets('从账号管理返回后刷新登录和退出状态', (tester) async {
    final source = FakeAccountSource()..session = null;
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPlatformCard(
            source: source,
            onOpen: () async {
              source.session = ++opens == 1 ? 1 : null;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('未登录'));
    await tester.pumpAndSettle();
    expect(find.text('合成读者'), findsOneWidget);
    expect(find.text('ID 42'), findsOneWidget);
    await tester.tap(find.text('合成读者'));
    await tester.pumpAndSettle();
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('ID 42'), findsNothing);
    expect(source.calls, 1);
  });

  testWidgets('旧账号的慢请求不覆盖新账号，退出后不再显示资料', (tester) async {
    final source = FakeAccountSource();
    final old = Completer<SourceAccount>();
    source.load = () => old.future;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: AccountPlatformCard(source: source, onOpen: () async {}),
            );
          },
        ),
      ),
    );
    source.session = 2;
    source.load = () async => const SourceAccount(id: 'new', name: '新账号');
    rebuild(() {});
    await tester.pumpAndSettle();
    expect(find.text('新账号'), findsOneWidget);
    old.complete(const SourceAccount(id: 'old', name: '旧账号'));
    await tester.pumpAndSettle();
    expect(find.text('旧账号'), findsNothing);
    source.session = null;
    rebuild(() {});
    await tester.pumpAndSettle();
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('新账号'), findsNothing);
  });

  testWidgets('资料失败可重试，离开后完成请求不更新已销毁页面', (tester) async {
    final source = FakeAccountSource()
      ..load = () async => throw Exception('offline');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPlatformCard(source: source, onOpen: () async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法读取账号信息'), findsOneWidget);
    source.load = () async => const SourceAccount(id: '42', name: '重试成功');
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试成功'), findsOneWidget);
    final pending = Completer<SourceAccount>();
    source.session = 3;
    source.load = () => pending.future;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPlatformCard(source: source, onOpen: () async {}),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(const SourceAccount(id: '42', name: '已离开'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 600.0, 1100.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('账号卡片宽度 $width、$scale 倍字体下长昵称 ID 不溢出且登录状态等高', (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = FakeAccountSource()
          ..load = () async => const SourceAccount(
            id: '12345678901234567890',
            name: '这是一个非常长的中文平台昵称用于检查手机和宽屏的文字布局',
            metrics: [
              AccountMetric('书币余额', '1234567890'),
              AccountMetric('月票', '0'),
              AccountMetric('成长等级', '12'),
            ],
          );
        Widget app() => MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              children: [
                AccountPlatformCard(source: source, onOpen: () async {}),
              ],
            ),
          ),
        );
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        expect(find.text('ID 12345678901234567890'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final loggedInHeight = tester
            .getSize(find.byType(AccountPlatformCard))
            .height;
        source.session = null;
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        expect(find.text('未登录'), findsOneWidget);
        expect(find.text('成长等级'), findsNothing);
        expect(
          tester.getSize(find.byType(AccountPlatformCard)).height,
          loggedInHeight,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}

class FakeAccountSource implements AccountSource {
  Object? session = 1;
  int calls = 0;
  Future<SourceAccount> Function() load = () async =>
      const SourceAccount(id: '42', name: '合成读者');
  @override
  String get id => 'qidian';
  @override
  String get name => '起点读书';
  @override
  Object? get accountSession => session;
  @override
  Future<SourceAccount> getAccount() {
    calls++;
    return load();
  }

  @override
  Future<Book> getBook(String input) => throw UnimplementedError();
  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) =>
      throw UnimplementedError();
}
