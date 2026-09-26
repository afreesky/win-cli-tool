import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/main_window.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';
import 'package:win_cli_tool/ui/panels/output_panel.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_win_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> pumpWindow(
    WidgetTester tester, {
    FakeSessionFactory? factory,
    AppSettings settings = const AppSettings(),
  }) async {
    await pumpUi(
      tester,
      root: root,
      devices: [
        fakeProfile(id: 'd1', name: '核心交换机', autoConnect: true),
        fakeProfile(id: 'd2', name: '边界防火墙'),
      ],
      settings: settings,
      factory: factory,
      child: const MainWindow(),
    );
    // 编辑区要在 `initState` 里把草稿读出来才算就绪，而那次读是**真盘 I/O**
    // （`pumpAndSettle` 里走不完，见 `settleDisk` 的文档）。
    await settleDisk(tester);
  }

  testWidgets('三个区都在，且默认选中第一台（§7.1 的布局）', (tester) async {
    await pumpWindow(tester);
    expect(find.byType(EditorPanel), findsOneWidget);
    expect(find.byType(OutputPanel), findsOneWidget);
    expect(find.text('核心交换机'), findsWidgets);
  });

  testWidgets('切换设备会把编辑区与输出区都换过去（§9.2 第 2 条）', (tester) async {
    await pumpWindow(tester);

    var editor = tester.widget<EditorPanel>(find.byType(EditorPanel));
    expect(editor.deviceId, 'd1');

    await tester.tap(find.text('边界防火墙'));
    await tester.pumpAndSettle();

    editor = tester.widget<EditorPanel>(find.byType(EditorPanel));
    final output = tester.widget<OutputPanel>(find.byType(OutputPanel));
    expect(editor.deviceId, 'd2', reason: '编辑区要跟着换');
    expect(output.deviceId, 'd2', reason: '输出区也要跟着换，否则会看到上一台的输出');
  });

  testWidgets('切换设备时草稿跟着换（FR-E-03）', (tester) async {
    await pumpWindow(tester);

    await tester.enterText(find.byType(TextField), 'sys');
    await tester.pump(const Duration(milliseconds: 600));
    await settleDisk(tester);
    await tester.tap(find.text('边界防火墙'));
    await tester.pumpAndSettle();
    expect(find.text('sys'), findsNothing, reason: 'B 设备不该看到 A 的草稿');

    await tester.tap(find.text('核心交换机').first);
    await settleDisk(tester);

    expect(find.text('sys'), findsOneWidget, reason: '切回来草稿还在');
  });

  testWidgets('切设备时草稿落在原设备上，不串到新设备（FR-E-03）', (tester) async {
    await pumpWindow(tester);

    // **防抖还没到就切走** —— 这一刻压在节流里的那段文本属于 d1。
    await tester.enterText(find.byType(TextField), 'AAA');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('边界防火墙'));
    await settleDisk(tester);

    expect(File('${root.path}/drafts/d1.txt').readAsStringSync(), 'AAA',
        reason: '切走那一刻的文本要落到原设备');
    final d2 = File('${root.path}/drafts/d2.txt');
    expect(d2.existsSync() ? d2.readAsStringSync() : '', isNot(contains('AAA')),
        reason: '不能写进新设备的草稿文件');
  });

  testWidgets('切过一次设备之后草稿仍然会落盘（FR-E-03）', (tester) async {
    await pumpWindow(tester);
    await tester.tap(find.text('边界防火墙'));
    await settleDisk(tester);

    await tester.enterText(find.byType(TextField), 'BBB');
    await tester.pump(const Duration(milliseconds: 600));
    await settleDisk(tester);

    expect(File('${root.path}/drafts/d2.txt').readAsStringSync(), 'BBB');
  });

  testWidgets('带着未落盘的编辑被卸载：不抛，且草稿要写下去（FR-E-04）', (tester) async {
    await pumpWindow(tester);
    await tester.enterText(find.byType(TextField), 'last');
    await tester.pump(const Duration(milliseconds: 100));

    // 把编辑区从树上摘掉。真机上对应两种情形：把设备删光（窗口切到空状态）、
    // 以及退出时整棵树被拆。
    await pumpUi(tester, root: root, child: const SizedBox());
    expect(tester.takeException(), isNull);
    await settleDisk(tester);

    expect(File('${root.path}/drafts/d1.txt').readAsStringSync(), 'last');
  });

  testWidgets('Ctrl+L 清屏（§4.8）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpWindow(tester, factory: factory);
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(MainWindow));
    final container = ProviderScope.containerOf(element);
    container.read(outputBufferProvider('d1')).add('一些输出\n');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    expect(find.textContaining('一些输出'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.textContaining('一些输出'), findsNothing);
  });

  testWidgets('Esc 中止命令队列（§4.8）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpWindow(tester, factory: factory);
    await tester.tap(find.byTooltip('连接 核心交换机'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a\nb\nc\nd');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final session = factory.sessions.single;
    // **队列是一条一条发的**：第一条出去之后要等提示符才轮到第二条。这里一直
    // 没吐提示符，所以此刻出去的只有头一条（或还没有 —— 见下面的写法）。
    final before = session.written.length;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 中止之后把提示符补上：队列若还活着，下一条会跟着出去。
    session.emit('<Huawei>');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    // **断言写成"没有再增加"而不是"等于某一条"**：前者不依赖"第一条是同步写出
    // 去的"这个实现细节，而后者会。判别力不受影响 —— 没有 abort 的话，这个
    // 提示符会让队列前进，`written` 必然变长。
    expect(session.written.length, before,
        reason: 'Esc 之后剩余命令不该再发出去（FR-E-13）');
  });

  testWidgets('分隔条拖动会写回 editorSplitRatio（§7.3）', (tester) async {
    await pumpWindow(tester);
    final element = tester.element(find.byType(MainWindow));
    final container = ProviderScope.containerOf(element);
    final before = container.read(settingsProvider).editorSplitRatio;

    final splitter = find.byKey(const ValueKey('splitter-h'));
    await tester.drag(splitter, const Offset(0, 60));
    await settleDisk(tester);

    final after = container.read(settingsProvider).editorSplitRatio;
    expect(after, greaterThan(before), reason: '往下拖应当让编辑区变高');
  });

  testWidgets('AppBar 的「添加设备」打开设备编辑对话框（FR-D-01）', (tester) async {
    await pumpWindow(tester);

    await tester.tap(find.byTooltip('添加设备'));
    await tester.pumpAndSettle();

    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('Ctrl+N 走同一条路（§4.8）', (tester) async {
    await pumpWindow(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('AppBar 的「设置」打开设置对话框（FR-G-01）', (tester) async {
    await pumpWindow(tester);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();

    // **只可能是对话框标题那一个。** AppBar 上那个 `IconButton` 的
    // `tooltip: '设置'` 不算 —— `Tooltip` 没展开时**不渲染它的文字**
    // （这正是 Task 6 里删掉一条同类断言的原因：当时写的理由是"标题与 tooltip
    // 都会命中"，而那个机制根本不存在）。所以这里用 `findsOneWidget`；若真
    // 数出两个，那是树上多了别的东西，要查，不是放宽断言。
    expect(find.text('设置'), findsOneWidget, reason: '对话框标题');
    expect(
      find.byKey(const ValueKey('settings-command-timeout')),
      findsOneWidget,
    );
  });
}
