import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/sources/sfacg/sfacg_verification.dart';
import 'package:unr/sources/source_verification.dart';
import 'package:unr/ui/reader.dart';

class _Source extends SfacgSource {
  _Source() : super(SfacgApi());
  @override
  String get id => 'future-source';
  @override
  bool get canVerifyAccess => true;
  bool blocked = true;
  String blockedChapter = '1';
  Object failure = const SourceVerificationRequiredException('平台要求安全验证');
  final reads = <String>[];
  int verifications = 0;

  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async {
    reads.add(chapter.id);
    if (blocked && chapter.id == blockedChapter) throw failure;
    return ChapterContent([
      for (var i = 0; i < 30; i++) Paragraph('章节${chapter.id}正文$i'),
    ]);
  }

  @override
  Future<SourceVerificationOutcome> verifyAccess(
    SourceVerificationSolver solve,
  ) async {
    verifications++;
    final result = await solve(
      SfacgVerificationChallenge(
        aid: 'aid',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ),
    );
    if (result == null) return SourceVerificationOutcome.cancelled;
    blocked = false;
    return SourceVerificationOutcome.verified;
  }
}

class _Library extends Library {
  _Library(_Source other, {SfacgSource? primary})
    : super(
        Directory.systemTemp,
        primary ?? SfacgSource(SfacgApi()),
        novelSources: [other],
      ) {
    showParagraphComments = false;
  }
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) =>
      sourceFor(book)!.readChapter(book, chapter);
  @override
  Future<void> save() async {}
  @override
  Future<void> recordReading(Book book) async {}
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

Book book({bool twoChapters = false, String source = 'future-source'}) => Book(
  id: 'verification',
  source: source,
  title: '风控验证与阅读进度恢复的长书名测试',
  author: '',
  chapters: [
    const Chapter(id: '1', title: '第一章'),
    if (twoChapters) const Chapter(id: '2', title: '第二章'),
  ],
);

Future<T?> solved<T>(SourceVerificationChallenge<T> challenge) async =>
    challenge.parseResult({'ret': 0, 'ticket': 'ticket', 'randstr': 'random'});

void main() {
  Future<void> open(
    WidgetTester tester,
    _Library library,
    Book target, {
    SourceVerificationSolver? solver = solved,
    double width = 360,
  }) async {
    tester.view.physicalSize = Size(width, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ReaderPage(
          library: library,
          book: target,
          verificationSolver: solver,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final mode in ReadingMode.values) {
    for (final width in [320.0, 1280.0]) {
      testWidgets('阅读加载风控可直接验证，${mode.name} / $width，保留位置并手动重试', (
        tester,
      ) async {
        final source = _Source();
        addTearDown(source.api.close);
        final library = _Library(source)..readingMode = mode;
        final target = book();
        library.progress[target.key] = [0, 5];
        await open(tester, library, target, width: width);
        expect(find.text('处理安全验证'), findsOneWidget);
        await tester.ensureVisible(find.text('处理安全验证'));
        await tester.tap(find.text('处理安全验证'));
        await tester.pumpAndSettle();
        expect(source.verifications, 1);
        expect(source.reads, ['1']);
        expect(library.progress[target.key], [0, 5]);
        expect(find.text('安全验证已通过，请点击“重试”加载本章。'), findsOneWidget);
        await tester.ensureVisible(find.text('重试'));
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(source.reads, ['1', '1']);
        expect(find.text('处理安全验证'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('滚动续章风控保留已读正文，验证后重试下一章', (tester) async {
    final source = _Source()..blockedChapter = '2';
    addTearDown(source.api.close);
    final library = _Library(source);
    final target = book(twoChapters: true);
    await open(tester, library, target);
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scroll-next-error')), findsOneWidget);
    await tester.ensureVisible(find.text('处理安全验证'));
    await tester.tap(find.text('处理安全验证'));
    await tester.pumpAndSettle();
    expect(find.text('安全验证已通过，请点击“重试下一章”继续阅读。'), findsOneWidget);
    expect(source.reads, ['1', '2']);
    expect(find.text('　　章节1正文29'), findsOneWidget);
    final offset = scroll.offset;
    await tester.ensureVisible(find.text('重试下一章'));
    await tester.tap(find.text('重试下一章'));
    await tester.pumpAndSettle();
    expect(source.reads, ['1', '2', '2']);
    expect(find.text('　　章节2正文0'), findsOneWidget);
    expect(scroll.offset, greaterThanOrEqualTo(offset));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('普通章节错误不显示安全验证入口', (tester) async {
    final source = _Source()..failure = const SourceException('网络不可用');
    addTearDown(source.api.close);
    final library = _Library(source);
    await open(tester, library, book());
    expect(find.text('网络不可用'), findsOneWidget);
    expect(find.text('处理安全验证'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('未登录的 App 风控从阅读页引导至账号设置', (tester) async {
    final other = _Source();
    addTearDown(other.api.close);
    final primary = SfacgSource(
      SfacgApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': {'httpCode': 403, 'msg': '请完成安全验证'},
            }),
            403,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      ),
    );
    final library = _Library(other, primary: primary);
    await open(tester, library, book(source: 'sfacg'));
    expect(find.text('前往账号设置处理验证'), findsOneWidget);
    await tester.tap(find.text('前往账号设置处理验证'));
    await tester.pumpAndSettle();
    expect(find.text('账号设置'), findsOneWidget);
    expect(find.text('菠萝包轻小说'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('阅读页按钮实际打开验证页，返回取消后保留错误且不重试章节', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final source = _Source();
    addTearDown(source.api.close);
    final library = _Library(source);
    await open(tester, library, book(), solver: null);
    await tester.tap(find.text('处理安全验证'));
    await tester.pumpAndSettle();
    expect(find.text('菠萝包安全验证'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('已取消安全验证。'), findsOneWidget);
    expect(source.reads, ['1']);
    expect(source.blocked, isTrue);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
