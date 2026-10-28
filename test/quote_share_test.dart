import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/quote_card.dart';
import 'package:unr/ui/quote_share_sheet.dart';
import 'package:unr/ui/reader.dart';

const book = Book(
  id: 'quote',
  source: 'local',
  title: '山海之间',
  author: '测试作者',
  cover: 'local:cover',
  chapters: [
    Chapter(id: '1', title: '第一章'),
    Chapter(id: '2', title: '第二章'),
  ],
);

class QuoteLibrary extends Library {
  QuoteLibrary(this.coverBytes)
    : super(Directory.systemTemp, SfacgSource(SfacgApi()));
  final Future<Uint8List> Function() coverBytes;
  int coverReads = 0;
  @override
  Future<Uint8List> loadImage(Book book, String key) {
    coverReads++;
    return coverBytes();
  }

  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      ChapterContent([
        Paragraph(chapter.id == '1' ? '沿着山路前行，看见远处的海。' : '另一章里也有值得收藏的句子。'),
      ]);
  @override
  Future<void> save() async => notifyListeners();
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

class QuoteFilePicker extends FilePickerPlatform {
  Uint8List? saved;
  String? name, mime;
  int calls = 0;
  Future<Uri?> Function()? result;
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    saved = bytes;
    name = fileName;
    mime = mimeType;
    return result == null ? Uri.file('/quote.png') : result!();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List coverBytes;
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 40, 60),
      Paint()..color = Colors.green,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(40, 60);
    coverBytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
  });

  Future<ui.Image> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  QuoteLibrary library() {
    final value = QuoteLibrary(() async => coverBytes);
    addTearDown(value.source.api.close);
    addTearDown(value.dispose);
    return value;
  }

  Uint8List preview(WidgetTester tester) =>
      (tester
                  .widget<Image>(
                    find.descendant(
                      of: find.byKey(const ValueKey('quote-card-preview')),
                      matching: find.byType(Image),
                    ),
                  )
                  .image
              as MemoryImage)
          .bytes;

  Future<void> ready(WidgetTester tester) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find
          .byKey(const ValueKey('quote-card-preview'))
          .evaluate()
          .isNotEmpty) {
        final context = tester.element(
          find.byKey(const ValueKey('quote-card-preview')),
        );
        await tester.runAsync(
          () => precacheImage(MemoryImage(preview(tester)), context),
        );
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('分享图未生成');
  }

  Future<void> open(
    WidgetTester tester,
    QuoteLibrary library, {
    Book selectedBook = book,
    String quote = '沿着山路前行，看见远处的海。',
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showQuoteShareSheet(
                context,
                library: library,
                book: selectedBook,
                quote: quote,
              ),
              child: const Text('打开分享'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开分享'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  test('生成 1080px PNG，保留实际封面，长选句和长署名完整增加图片高度', () async {
    final cover = await decodeQuoteCover(coverBytes);
    addTearDown(cover.dispose);
    final short = await decode(
      await renderQuoteCard(
        book: book,
        quote: '选中的句子。',
        theme: QuoteCardTheme.paper,
        cover: cover,
      ),
    );
    final long = await decode(
      await renderQuoteCard(
        book: book,
        quote: '第一句。\n${'继续阅读，收藏故事。' * 120}\n最后一句。',
        theme: QuoteCardTheme.paper,
        cover: cover,
      ),
    );
    final metadata = await decode(
      await renderQuoteCard(
        book: Book(
          id: 'long',
          title: '很长的作品名称' * 10,
          author: '很长的作者名称' * 8,
          chapters: [],
        ),
        quote: '选中的句子。',
        theme: QuoteCardTheme.paper,
        cover: cover,
      ),
    );
    addTearDown(short.dispose);
    addTearDown(long.dispose);
    addTearDown(metadata.dispose);
    expect(short.width, 1080);
    expect(long.width, 1080);
    expect(long.height, greaterThan(short.height * 2));
    expect(metadata.height, greaterThan(short.height));
    final pixels = (await short.toByteData())!.buffer.asUint8List();
    var green = 0;
    for (var i = 0; i < pixels.length; i += 4) {
      if (pixels[i] == 76 && pixels[i + 1] == 175 && pixels[i + 2] == 80) {
        green++;
      }
    }
    expect(green, greaterThan(10000), reason: '真实封面必须出现在导出的图片中');
  });

  test('支持 SVG 封面，空选句和超长选句明确失败，文件名保留中文并去除非法字符', () async {
    final svg = await decodeQuoteCover(
      Uint8List.fromList(
        utf8.encode(
          '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="150"><rect width="100" height="150" fill="green"/></svg>',
        ),
      ),
    );
    addTearDown(svg.dispose);
    expect(svg.height, 600);
    expect(svg.width, 400);
    await expectLater(
      renderQuoteCard(book: book, quote: '　 ', theme: QuoteCardTheme.paper),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      renderQuoteCard(
        book: book,
        quote: '正文' * 10000,
        theme: QuoteCardTheme.paper,
      ),
      throwsA(isA<SourceException>()),
    );
    expect(
      quoteCardFileName(
        const Book(id: '1', title: '书名:/😀', author: '', chapters: []),
      ),
      '书名__😀_选句.png',
    );
  });

  testWidgets('手机大字模式预览包含选句和署名，切换主题复用封面且保存与分享使用同一 PNG', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final value = library();
    final picker = QuoteFilePicker();
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    final shared = <MethodCall>[];
    final temp = (await tester.runAsync(
      () => Directory(
        '${Directory.current.path}/.local/quote-share-test',
      ).create(recursive: true),
    ))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => temp.path);
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shared.add(call);
      return '';
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(shareChannel, null);
    });
    await open(tester, value, scale: 2);
    await ready(tester);
    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('沿着山路前行，看见远处的海。\n《山海之间》\n测试作者 著'),
      findsOneWidget,
    );
    semantics.dispose();
    final first = preview(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, '夜色'));
    await tester.pump();
    await ready(tester);
    final bytes = preview(tester);
    expect(bytes, isNot(orderedEquals(first)));
    expect(value.coverReads, 1);
    await tester.tap(find.text('保存图片'));
    await tester.pump();
    expect(picker.saved, orderedEquals(bytes));
    expect(picker.name, '山海之间_选句.png');
    expect(picker.mime, 'image/png');
    await tester.tap(find.text('系统分享'));
    for (var i = 0; i < 100 && shared.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(shared, hasLength(1));
    expect(shared.single.method, 'share');
    final args = shared.single.arguments as Map;
    expect(args['mimeTypes'], ['image/png']);
    final path = (args['paths'] as List).single as String;
    expect(
      await tester.runAsync(() => File(path).readAsBytes()),
      orderedEquals(bytes),
    );
    expect(find.textContaining('分享未完成'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭选句分享'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => temp.delete(recursive: true));
  });

  testWidgets('封面下载和解码失败可重试或明确使用默认封面，关闭后忽略旧加载结果', (tester) async {
    var bad = true;
    final value = QuoteLibrary(
      () async => bad ? Uint8List.fromList([1, 2, 3]) : coverBytes,
    );
    addTearDown(value.source.api.close);
    addTearDown(value.dispose);
    await open(tester, value);
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.text('使用默认封面').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('封面加载失败'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '系统分享'))
          .onPressed,
      isNull,
    );
    bad = false;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await ready(tester);
    expect(value.coverReads, 2);
    await tester.tap(find.byTooltip('关闭选句分享'));
    await tester.pumpAndSettle();
    final pending = Completer<Uint8List>();
    final lateLibrary = QuoteLibrary(() => pending.future);
    addTearDown(lateLibrary.source.api.close);
    addTearDown(lateLibrary.dispose);
    await open(tester, lateLibrary);
    await tester.tap(find.byTooltip('关闭选句分享'));
    await tester.pumpAndSettle();
    pending.complete(coverBytes);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('封面请求失败可主动使用默认封面，本地无封面和作者的作品也能生成', (tester) async {
    final value = QuoteLibrary(
      () async => throw const SourceException('网络不可用'),
    );
    addTearDown(value.source.api.close);
    addTearDown(value.dispose);
    await open(tester, value);
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用默认封面'));
    await ready(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, '青绿'));
    await tester.pump();
    await ready(tester);
    expect(value.coverReads, 1);
    await tester.tap(find.byTooltip('关闭选句分享'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(
      tester,
      value,
      selectedBook: Book(
        id: 'txt',
        source: 'local',
        title: '很长的本地书名' * 10,
        author: '',
        chapters: [],
      ),
      scale: 2,
    );
    await ready(tester);
    expect(value.coverReads, 1);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label?.contains('佚名 著') == true,
      ),
      findsOneWidget,
    );
    expect(find.text('系统分享').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存取消不报成功，失败可重试，保存期间拦截重复请求', (tester) async {
    final value = library();
    final picker = QuoteFilePicker()..result = () async => null;
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    await open(tester, value);
    await ready(tester);
    await tester.tap(find.text('保存图片'));
    await tester.pump();
    expect(find.text('选句图片已保存'), findsNothing);
    picker.result = () async => throw const FileSystemException('无法写入');
    await tester.tap(find.text('保存图片'));
    await tester.pump();
    expect(find.text('图片保存失败，请重试。'), findsOneWidget);
    final pending = Completer<Uri?>();
    picker.result = () => pending.future;
    final save = tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '保存图片'))
        .onPressed!;
    save();
    save();
    await tester.pump();
    expect(picker.calls, 3);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '保存图片'))
          .onPressed,
      isNull,
    );
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '保存图片'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏右页的下一章预览可分享选句，关闭后保持当前章节位置', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final value = library()..readingMode = ReadingMode.paged;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: value, book: book),
      ),
    );
    await tester.pumpAndSettle();
    final editable = tester.state<EditableTextState>(
      find.byType(EditableText).hitTestable().last,
    );
    final all = editable.textEditingValue.text;
    expect(all, contains('另一章'));
    final saved = value.progress[book.key]?.toList() ?? [0, 0];
    editable.userUpdateTextEditingValue(
      TextEditingValue(
        text: all,
        selection: TextSelection(
          baseOffset: all.indexOf('值得'),
          extentOffset: all.length,
        ),
      ),
      SelectionChangedCause.longPress,
    );
    editable.showToolbar();
    await tester.pumpAndSettle();
    await tester.tap(find.text('选句分享'));
    await tester.pump();
    expect(
      tester.widget<QuoteShareSheet>(find.byType(QuoteShareSheet)).quote,
      '值得收藏的句子。',
    );
    await ready(tester);
    await tester.tap(find.byTooltip('关闭选句分享'));
    await tester.pumpAndSettle();
    expect(value.progress[book.key], saved);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mode in ReadingMode.values) {
    for (final wide in [false, true]) {
      testWidgets('阅读器${mode.name}${wide ? '宽屏' : '手机'}选句入口只传递选中文字并保留复制菜单', (
        tester,
      ) async {
        tester.view.physicalSize = wide
            ? const Size(1920, 1080)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final value = library()..readingMode = mode;
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(library: value, book: book),
          ),
        );
        await tester.pumpAndSettle();
        final target = find.byType(EditableText).hitTestable().first;
        final editable = tester.state<EditableTextState>(target);
        final all = editable.textEditingValue.text;
        final start = all.indexOf('看见');
        editable.userUpdateTextEditingValue(
          TextEditingValue(
            text: all,
            selection: TextSelection(
              baseOffset: start,
              extentOffset: start + '看见远处的海。'.length,
            ),
          ),
          SelectionChangedCause.longPress,
        );
        editable.showToolbar();
        await tester.pumpAndSettle();
        expect(find.text('选句分享'), findsOneWidget);
        final toolbar = tester.widget<AdaptiveTextSelectionToolbar>(
          find.byType(AdaptiveTextSelectionToolbar),
        );
        expect(
          toolbar.buttonItems!.any((b) => b.type == ContextMenuButtonType.copy),
          isTrue,
        );
        await tester.tap(find.text('选句分享'));
        await tester.pump();
        expect(
          tester.widget<QuoteShareSheet>(find.byType(QuoteShareSheet)).quote,
          '看见远处的海。',
        );
        expect(
          tester.widget<QuoteShareSheet>(find.byType(QuoteShareSheet)).book.key,
          book.key,
        );
        await ready(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
