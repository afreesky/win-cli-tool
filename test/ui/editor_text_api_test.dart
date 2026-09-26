import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_edapi_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<EditorPanelState> pumpEditor(WidgetTester tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [fakeProfile(id: 'd1', name: 'A')],
      child: const SizedBox(height: 400, child: EditorPanel(deviceId: 'd1')),
    );
    // 编辑区在 `initState` 里读草稿是**真盘 I/O**，`pumpAndSettle` 走不完。
    await settleDisk(tester);
    return tester.state<EditorPanelState>(find.byType(EditorPanel));
  }

  /// 编辑区里那个 `TextEditingController`。
  TextEditingController controllerOf(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!;

  /// 把文本换成 [text] 并把光标停在 [offset]。
  ///
  /// **不能只靠 `tester.enterText`**：它会把整段文本选中（`baseOffset: 0,
  /// extentOffset: length`），于是 `insertAtCursor` 走的是"替换整个编辑区"
  /// 而不是"插入"。光标必须显式摆一次。
  void setTextAndCaret(WidgetTester tester, String text, int offset) {
    controllerOf(tester).value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  testWidgets('光标所在行非空：先换行再插入（FR-S-03）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a\nb', 3);

    state.insertAtCursor('save');

    expect(controllerOf(tester).text, 'a\nb\nsave');
  });

  testWidgets('光标所在行是空行：不添换行（FR-S-03）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a\n', 2);

    state.insertAtCursor('save');

    expect(controllerOf(tester).text, 'a\nsave');
  });

  testWidgets('只有空白字符的行不算非空行（FR-E-08 的"一个空格是空行"）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a\n   ', 5);

    state.insertAtCursor('save');

    expect(controllerOf(tester).text, 'a\n   save');
  });

  testWidgets('从未获得过焦点（selection 无效）时插到末尾', (tester) async {
    final state = await pumpEditor(tester);
    controllerOf(tester).value = const TextEditingValue(
      text: 'a',
      selection: TextSelection.collapsed(offset: -1),
    );

    state.insertAtCursor('save');

    expect(controllerOf(tester).text, 'a\nsave');
  });

  testWidgets('插入之后光标在插入内容的末尾（连着双击两条不会倒着拼）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a', 1);

    state.insertAtCursor('save');

    expect(controllerOf(tester).selection.baseOffset, 6);
    expect(controllerOf(tester).selection.isCollapsed, isTrue);
  });

  testWidgets('replaceAllText 整份替换并把光标放到末尾', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'old', 3);

    state.replaceAllText('x\ny');

    expect(controllerOf(tester).text, 'x\ny');
    expect(controllerOf(tester).selection.baseOffset, 3);
  });

  testWidgets('appendText：原文本不以换行结尾时补一个（FR-E-15 的"追加到末尾"）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a', 1);

    state.appendText('save');

    expect(controllerOf(tester).text, 'a\nsave');
  });

  testWidgets('appendText：原文本以换行结尾时不补', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a\n', 2);

    state.appendText('save');

    expect(controllerOf(tester).text, 'a\nsave');
  });

  testWidgets('appendText：编辑区是空的时候不产生开头的空行', (tester) async {
    final state = await pumpEditor(tester);

    state.appendText('save');

    expect(controllerOf(tester).text, 'save');
  });

  testWidgets('改文本会触发草稿落盘（接上 FR-E-03）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a\nb', 3);

    state.insertAtCursor('save');
    // 防抖窗口是 500ms（`DraftAutosave` 的默认值），推过去再等盘。
    await tester.pump(const Duration(milliseconds: 600));
    await settleDisk(tester);

    expect(File('${root.path}/drafts/d1.txt').readAsStringSync(), 'a\nb\nsave');
  });
}
