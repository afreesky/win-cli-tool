import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/main_window.dart';
// 「抽屉真的关了吗」这条断言要靠 `find.byType(SnippetDrawer)` 来问 ——
// 见下面那条用例里的注释。
import 'package:win_cli_tool/ui/panels/snippet_drawer.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_snip_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// d1 有两条片段，d2 一条都没有 —— FR-S-01 要的"各自独立"就靠这个对比。
  DeviceProfile withSnippets(String id, String name, List<Snippet> snippets) =>
      fakeProfile(id: id, name: name).copyWith(snippets: snippets);

  Future<void> pumpWindow(WidgetTester tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [
        withSnippets('d1', '核心交换机', const [
          Snippet(id: 's1', name: '保存配置', content: 'save\nY'),
          Snippet(id: 's2', name: '看版本', content: 'display version'),
        ]),
        withSnippets('d2', '边界防火墙', const []),
      ],
      child: const MainWindow(),
    );
    await settleDisk(tester);
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MainWindow)));

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byTooltip('命令库'));
    await tester.pumpAndSettle();
  }

  /// 双击。**`tester` 没有 doubleTap**，两次 `tap` 之间的间隔必须落在
  /// `kDoubleTapTimeout`（300ms）内，识别器才认。
  Future<void> doubleTap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('抽屉列出当前设备的片段（FR-S-01/02）', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);

    expect(find.text('保存配置'), findsOneWidget);
    expect(find.text('看版本'), findsOneWidget);
    expect(find.textContaining('命令库 · 核心交换机'), findsOneWidget);
  });

  testWidgets('换设备之后抽屉列的是新设备的（FR-S-01：各自独立）', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);
    expect(find.text('保存配置'), findsOneWidget);

    // 关掉抽屉再切设备：抽屉开着的时候点不到列表。
    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('边界防火墙'));
    await tester.pumpAndSettle();
    await openDrawer(tester);

    expect(find.text('保存配置'), findsNothing, reason: 'A 的片段不该出现在 B 的命令库里');
    expect(find.text('还没有命令片段'), findsOneWidget);
  });

  testWidgets('双击片段插入光标处，且抽屉关掉、主窗口还在（FR-S-03）', (tester) async {
    await pumpWindow(tester);

    final editor = tester.widget<TextField>(find.byType(TextField)).controller!;
    editor.value = const TextEditingValue(
      text: 'sys',
      selection: TextSelection.collapsed(offset: 3),
    );
    await tester.pump();

    await openDrawer(tester);
    await doubleTap(tester, find.text('看版本'));

    expect(
      editor.text,
      'sys\ndisplay version',
      reason: '光标在非空行上，插入前要先换行',
    );
    // 这两条合起来才证明"抽屉关了、而页面还在"。
    //
    // **别把它写成 `find.text('还没有命令片段')`。** d1 是有片段的，那句话在
    // d1 的抽屉里根本不会渲染 —— 写成它，这条断言就恒真了：抽屉关没关都绿。
    // （和 Task 1 里 const 规范化让相等用例恒真是同一类错误：断言在测空气。）
    // 要问的是抽屉这个**组件**还在不在，不是它里面某句文案。
    expect(find.byType(SnippetDrawer), findsNothing, reason: '抽屉要关上');
    expect(find.byType(MainWindow), findsOneWidget, reason: '关抽屉不能把页面一起弹掉');
  });

  testWidgets('添加片段：进了抽屉，也进了 devices.json（FR-S-04）', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);

    await tester.tap(find.byTooltip('添加命令片段'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('snippet-name')), '看接口');
    await tester.enterText(
      find.byKey(const ValueKey('snippet-content')),
      'display interface',
    );
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(find.text('看接口'), findsOneWidget);

    final stored = containerOf(tester)
        .read(devicesProvider)
        .firstWhere((d) => d.id == 'd1')
        .snippets;
    expect(stored.map((s) => s.name), contains('看接口'));
    expect(stored.first.id, 's1', reason: '加在末尾，前两条不动');
    expect(stored.last.content, 'display interface');
  });

  testWidgets('编辑片段：改名但 id 不变（FR-S-04）', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);

    await tester.tap(find.byTooltip('编辑 保存配置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('snippet-name')), '保存并退出');
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(find.text('保存并退出'), findsOneWidget);
    final stored = containerOf(tester)
        .read(devicesProvider)
        .firstWhere((d) => d.id == 'd1')
        .snippets;
    expect(stored, hasLength(2), reason: '编辑不能变成新增');
    expect(stored.first.id, 's1');
    expect(stored.first.content, 'save\nY', reason: '没动的字段要原样保留');
  });

  testWidgets('删除片段要二次确认；取消则还在（FR-S-04）', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);

    await tester.tap(find.byTooltip('删除 看版本'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除「看版本」'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('看版本'), findsOneWidget, reason: '取消了就不该删');

    await tester.tap(find.byTooltip('删除 看版本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await settleDisk(tester);

    expect(find.text('看版本'), findsNothing);
    final stored = containerOf(tester)
        .read(devicesProvider)
        .firstWhere((d) => d.id == 'd1')
        .snippets;
    expect(stored.map((s) => s.id), ['s1']);
  });

  testWidgets('片段名或内容为空时挡下来', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);

    await tester.tap(find.byTooltip('添加命令片段'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('snippet-content')), 'x');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('名称不能为空'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget, reason: '没保存成功，对话框不该关');
  });
}
