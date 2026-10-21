import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/ui/comment_content.dart';
import 'package:unr/ui/comment_image.dart';
import 'helpers/viewport.dart';

class _Comments extends CommentSource {
  @override
  String get id => 'test';
  @override
  String get name => '测试';
  @override
  bool get hasSession => false;
  @override
  CommentCapabilities get commentCapabilities => const CommentCapabilities();
  @override
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  }) async => const CommentPage([]);
  @override
  List<CommentPart> commentContent(String text) => const [
    CommentPart.text('前文'),
    CommentPart.image('https://example.test/emoji.png', inline: true),
    CommentPart.text('后文'),
    CommentPart.image('https://example.test/photo.png'),
    CommentPart.text('图片之后'),
    CommentPart.image('https://example.test/second.png'),
    CommentPart.image('file:///private', text: '[无效图片]'),
  ];
}

class _Client implements HttpClient {
  _Client(this.bytes);
  final Uint8List bytes;
  bool fail = false;
  Completer<void>? gate;
  final requests = <Uri>[];
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    await gate?.future;
    return _Request(bytes, fail);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.bytes, this.fail);
  final Uint8List bytes;
  final bool fail;
  @override
  Future<HttpClientResponse> close() async => _Response(bytes, fail);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.bytes, this.fail);
  final Uint8List bytes;
  final bool fail;
  @override
  int get statusCode => fail ? 503 : 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List bytes;
  late _Client client;
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 600, 300),
      Paint()..color = Colors.green,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(600, 300);
    bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
  });
  setUp(() {
    client = _Client(bytes);
    debugNetworkImageHttpClientProvider = () => client;
  });
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<void> finishImages(WidgetTester tester) async {
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    await tester.runAsync(() async {
      for (final image in images) {
        await precacheImage(
          image.image,
          tester.element(find.byType(CommentImage).first),
          onError: (_, _) {},
        );
      }
    });
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 1400.0]) {
    testWidgets('配图独立显示、表情保持行内，宽度 $width 大字体无溢出', (tester) async {
      setTestViewport(tester, Size(width, 900));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: CommentCard(
                  source: _Comments(),
                  comment: const ParagraphComment(
                    id: '1',
                    author: '长名字读者',
                    text: '图评',
                    isReply: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await finishImages(tester);
      final images = tester
          .widgetList<CommentImage>(find.byType(CommentImage))
          .toList();
      expect(images.map((i) => i.url), [
        'https://example.test/emoji.png',
        'https://example.test/photo.png',
        'https://example.test/second.png',
      ]);
      expect(
        tester.getSize(find.byType(CommentImage).first),
        const Size(32, 32),
      );
      final photo = tester.getSize(find.byType(CommentImage).at(1));
      expect(photo.width, greaterThan(32));
      expect(photo.width, lessThanOrEqualTo(360));
      expect(photo.width, lessThan(width));
      expect(find.text('图片之后'), findsOneWidget);
      expect(find.text('[无效图片]'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugNetworkImageHttpClientProvider = null;
    });
  }

  testWidgets('点击配图打开可缩放大图，关闭后保留评论', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CommentImage(url: 'https://example.test/photo.png'),
        ),
      ),
    );
    await finishImages(tester);
    await tester.tap(find.byType(CommentImage));
    await tester.pumpAndSettle();
    expect(find.text('评论图片'), findsOneWidget);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.maxScale, greaterThan(1));
    final center = tester.getCenter(find.byType(InteractiveViewer));
    final first = await tester.startGesture(
      center - const Offset(50, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(50, 0),
      pointer: 2,
    );
    await first.moveBy(const Offset(-50, 0));
    await second.moveBy(const Offset(50, 0));
    await tester.pump();
    final transform = tester
        .widgetList<Transform>(
          find.descendant(
            of: find.byType(InteractiveViewer),
            matching: find.byType(Transform),
          ),
        )
        .first;
    expect(transform.transform.storage[0], greaterThan(1));
    await first.up();
    await second.up();
    await tester.tap(find.byTooltip('关闭图片'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byType(CommentImage), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugNetworkImageHttpClientProvider = null;
  });

  testWidgets('图片等待时显示加载，失败可手动重试且不会自动重发', (tester) async {
    client.fail = true;
    client.gate = Completer<void>();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CommentImage(url: 'https://example.test/failure.png'),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    client.gate!.complete();
    await finishImages(tester);
    expect(find.text('图片加载失败'), findsOneWidget);
    final before = client.requests.length;
    await tester.pump(const Duration(seconds: 2));
    expect(client.requests.length, before);
    client.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await finishImages(tester);
    expect(client.requests.length, before + 1);
    expect(find.text('图片加载失败'), findsNothing);
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(tester.takeException(), isNull);
    debugNetworkImageHttpClientProvider = null;
  });
}
