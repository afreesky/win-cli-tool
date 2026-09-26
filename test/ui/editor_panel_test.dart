import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';
import 'package:win_cli_tool/ui/widgets/sent_line_controller.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_ed_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> pumpEditor(
    WidgetTester tester, {
    FakeSessionFactory? factory,
  }) => pumpUi(
    tester,
    root: root,
    devices: [fakeProfile(id: 'd1', name: 'A')],
    factory: factory,
    child: const SizedBox(height: 400, child: EditorPanel(deviceId: 'd1')),
  );

  /// 让命令队列往前走 [count] 步：每步吐一个提示符，再推过 `promptDebounce`
  /// （生产默认 120ms，见 `CommandDispatcher` 的构造默认值；这里给 300ms 留余量）。
  ///
  /// **`FakeSession` 不会自己回提示符** —— 它的 `output` 是空的广播流，只有
  /// `emit` 才吐数据。而队列是**一条一条发的**：第一条出去之后要等提示符才轮到
  /// 第二条。少了这一步，队列就停在第一条，那条 10 秒超时定时器会一直挂着，
  /// 用例在拆卸期红在 `A Timer is still pending even after the widget tree was
  /// disposed`，**而 `written` / `sentLines` 的断言其实已经过了** —— 别被那个
  /// 假象骗了，以为断言写错了。（Task 9 里推队列用的也是这个手法。）
  Future<void> drainQueue(
    WidgetTester tester,
    FakeSessionFactory factory,
    int count,
  ) async {
    for (var i = 0; i < count; i++) {
      factory.sessions.single.emit('Switch# ');
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('发送选中范围覆盖到的行（§9.2 第 1 条）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    // 先把会话连上，`enqueue` 才有 dispatcher 可进。
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'sys\ninterface GE0/0/1\nquit');
    await tester.pump();
    // 只选中第二行的中间几个字符 —— 期望整行发出，且只有那一行。
    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    controller.selection = const TextSelection(baseOffset: 6, extentOffset: 12);
    await tester.pump();

    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    // 队列里就这一条，吐一个提示符它就结束了。
    await drainQueue(tester, factory, 1);

    expect(
      factory.sessions.single.written.map((w) => w.trim()),
      ['interface GE0/0/1'],
      reason: '有选中就只发选中的行，且整行参与',
    );
  });

  testWidgets('没有可发送的命令时给轻提示，不静默（§5.1）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   \n\n');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    expect(find.text('没有可发送的命令'), findsOneWidget);
    expect(factory.sessions.single.written, isEmpty);
  });

  testWidgets('队列执行中显示进度，发送按钮转为停止（§9.2 第 3 条）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a\nb\nc');
    await tester.pump();
    // **`enterText` 会把光标收到文本末尾**（`TextSelection.collapsed(offset: 5)`），
    // 而"没有选中就只发光标那一行" —— 那样队列里只有 `c` 一条，"队列执行中"
    // 就名不副实了。全选，让三条都进队列。
    final editor = tester.widget<TextField>(find.byType(TextField)).controller!;
    editor.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    expect(find.text('执行中 1/3'), findsOneWidget,
        reason: 'FR-E-14：队列执行中要有 执行中 n/m，且 m 是队列长度');
    expect(find.byTooltip('中止'), findsOneWidget);

    // 三条命令，三个提示符，队列跑完。
    await drainQueue(tester, factory, 3);
    expect(find.byTooltip('发送'), findsOneWidget, reason: '队列空了应当能再发');
  });

  testWidgets('未连接时发送按钮不可用（§9.2 第 4 条的一半）', (tester) async {
    await pumpEditor(tester);
    // **不能用 `tester.widget<IconButton>(find.byTooltip('发送'))`。**
    // `find.byTooltip` 匹配的是 `Tooltip` / `RawTooltip` 组件本身（实测
    // SDK 源码），不是那个 `IconButton` —— 取 widget 会红在类型转换上。
    // 要按图标定位按钮：`IconButton` 是 `Icon` 的祖先。
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send),
    );
    expect(button.onPressed, isNull, reason: '没有会话时发出去的命令会掉进空处');
  });

  testWidgets('已发送的行被标出来（FR-E-10）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a\nb');
    await tester.pump();
    // 同上：不给选中就只发光标那一行，而本用例要的是两行都被标出来。
    final editor = tester.widget<TextField>(find.byType(TextField)).controller!;
    editor.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await drainQueue(tester, factory, 2);

    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!
            as SentLineController;
    expect(controller.sentLines, {0, 1});
  });

  testWidgets('断线后编辑区工具栏的进度文案不再是「未发送」', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'show version\nshow clock');
    await tester.pump();
    // **`enterText` 会把光标收到文本末尾**（`TextSelection.collapsed(offset: 23)`），
    // 而 §5.1 的规则是"没有选中就只发光标那一行" —— 那样队列里只有 `show clock`
    // **一条**，丢弃数是 1，下面那句 `断线，2 条命令未完成` 永远找不到。
    // 本文件三条兄弟用例都栽过这个坑（见它们各自的注释）。
    final editor = tester.widget<TextField>(find.byType(TextField)).controller!;
    editor.selection = TextSelection(
      baseOffset: 0,
      extentOffset: editor.text.length,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    // 第一条在途、第二条排队 —— 丢弃数因此是 2（在途那条也计入，见
    // `command_dispatcher.dart` 的 `onDisconnected`）。
    factory.sessions.first.drop();
    await tester.pump();

    expect(find.text('断线，2 条命令未完成'), findsOneWidget);

    // **把重连定时器走完，并顺带钉住"重连成功后这句文案要消失"。**
    //
    // 不走定时器的话用例会红在 `A Timer is still pending even after the widget
    // tree was disposed` —— 那是拆卸期的假象，断言其实已经过了（见 `drainQueue`
    // 的注释）。退避首档是 1s，所以推 1s 就够。
    //
    // **为什么这里还要再断一次**：`断线，N 条命令未完成` 说的是**现在**，不是
    // 过去。重连成功后按钮已经绿了，工具栏却还挂着"断线"就是一句假话 —— 那正是
    // 本任务要消灭的形状。所以 Step 3 在 `_onSessionReady` 里把
    // `lastDispatchEvent` 一并清掉（与旁边那句 `droppedCommands: 0` 同一个道理）。
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(factory.sessions, hasLength(2), reason: '前提：1s 后确实重连了');
    expect(
      find.text('断线，2 条命令未完成'),
      findsNothing,
      reason: '重连成功后不能再挂着上一段断线的进度文案',
    );
  });
}
