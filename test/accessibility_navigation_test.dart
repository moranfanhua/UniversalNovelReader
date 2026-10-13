import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/sfacg_api.dart';
import 'package:unr/sources/sfacg_source.dart';

class TreeRecorder {
  final nodes = <int, List<int>>{};
  final failures = <String>[];
  final labels = <int, String>{};
  final pending = <int>{};
  final sliderActions = <int, int>{};
  void update(Map<Symbol, dynamic> args) {
    final id = args[#id] as int;
    nodes[id] = List<int>.from(args[#childrenInTraversalOrder]);
    labels[id] = args[#label] as String;
    pending.add(id);
    if ((args[#flags] as ui.SemanticsFlags).isSlider) {
      sliderActions[id] = args[#actions] as int;
    } else {
      sliderActions.remove(id);
    }
  }

  void commit() {
    if (pending.isEmpty) return;
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in nodes[id] ?? <int>[]) {
        visit(child);
      }
    }

    visit(0);
    for (final id in pending.difference(reachable)) {
      failures.add('Orphan semantics node $id: ${labels[id]}');
    }
    nodes.removeWhere((id, _) => !reachable.contains(id));
    labels.removeWhere((id, _) => !reachable.contains(id));
    sliderActions.removeWhere((id, _) => !reachable.contains(id));
    pending.clear();
  }
}

class RecordingBuilder implements ui.SemanticsUpdateBuilder {
  RecordingBuilder(this.delegate, this.recorder);
  final ui.SemanticsUpdateBuilder delegate;
  final TreeRecorder recorder;
  @override
  ui.SemanticsUpdate build() {
    recorder.commit();
    return delegate.build();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      recorder.update(invocation.namedArguments);
      return Function.apply(delegate.updateNode, [], invocation.namedArguments);
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(
        delegate.updateCustomAction,
        [],
        invocation.namedArguments,
      );
    }
    return super.noSuchMethod(invocation);
  }
}

class RecordingBinding extends AutomatedTestWidgetsFlutterBinding {
  final recorder = TreeRecorder();
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      RecordingBuilder(super.createSemanticsUpdateBuilder(), recorder);
}

class NavigationLibrary extends Library {
  NavigationLibrary() : super(Directory.systemTemp, SfacgSource(SfacgApi()));
  @override
  Future<void> save() async => notifyListeners();
  @override
  Future<Map<String, ChapterContent>> cachedContents(Book book) async => {};
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      const ChapterContent([Paragraph('用于导航测试的正文')]);
}

void main() {
  final binding = RecordingBinding();
  testWidgets(
    'Windows 开启语义树后反复打开书籍及阅读设置不发送悬空节点',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final library = NavigationLibrary();
      library.books.add(
        const Book(
          id: 'one',
          source: 'local',
          title: '测试书',
          author: '测试作者',
          chapters: [Chapter(id: '1', title: '第一章')],
        ),
      );
      await tester.pumpWidget(UnrApp(library: library));
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      for (var cycle = 0; cycle < 4; cycle++) {
        await mouse.moveTo(tester.getCenter(find.byTooltip('导入 EPUB / TXT')));
        await tester.pump(const Duration(milliseconds: 600));
        await mouse.moveTo(tester.getCenter(find.text('测试书').last));
        await tester.tap(find.text('测试书').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('继续阅读'));
        await tester.pumpAndSettle();
        await mouse.moveTo(tester.getCenter(find.byTooltip('阅读设置')));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.tap(find.byTooltip('阅读设置'));
        await tester.pumpAndSettle();
        final slider = find
            .byKey(const ValueKey('reading-font-size'))
            .hitTestable();
        expect(binding.recorder.sliderActions, isNotEmpty);
        for (final actions in binding.recorder.sliderActions.values) {
          expect(actions & ui.SemanticsAction.increase.index, isNonZero);
          expect(actions & ui.SemanticsAction.decrease.index, isNonZero);
        }
        await tester.drag(slider, const Offset(20, 0));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('关闭阅读设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton).hitTestable());
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton).hitTestable());
        await tester.pumpAndSettle();
      }
      expect(binding.recorder.failures, isEmpty);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      library.source.api.close();
      library.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
