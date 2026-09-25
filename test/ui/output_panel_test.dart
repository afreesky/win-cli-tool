import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/state/output_buffer.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/panels/output_panel.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_out_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 直接拿到那台设备的缓冲（面板订阅的是同一个实例）。
  OutputBuffer bufferOf(WidgetTester tester) {
    final element = tester.element(find.byType(OutputPanel));
    return ProviderScope.containerOf(element).read(outputBufferProvider('d1'));
  }

  testWidgets('标题栏显示当前设备名（FR-O-08）', (tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [fakeProfile(id: 'd1', name: '核心交换机')],
      child: const SizedBox(height: 300, child: OutputPanel(deviceId: 'd1')),
    );

    expect(find.text('核心交换机'), findsOneWidget);
  });

  testWidgets('新到达的输出会渲染出来，并滚到最新一行（FR-O-04）', (tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [fakeProfile(id: 'd1', name: 'A')],
      child: const SizedBox(height: 200, child: OutputPanel(deviceId: 'd1')),
    );

    final buffer = bufferOf(tester);
    // 100 行 × 约 20 逻辑像素，远超 200 高的视口。
    for (var i = 0; i < 100; i++) {
      buffer.add('第 $i 行\n');
    }
    // 两条：一条给 RefreshThrottle 的定时器，一条给跟底那一跳。
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();

    final controller = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    expect(controller.offset, controller.position.maxScrollExtent,
        reason: '新输出到达时应当看到最新的一行');
  });

  testWidgets('清屏只清显示内容，日志那一路分毫不动（FR-O-05 / §9.2 第 6 条）',
      (tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [fakeProfile(id: 'd1', name: 'A')],
      child: const SizedBox(height: 300, child: OutputPanel(deviceId: 'd1')),
    );

    final buffer = bufferOf(tester);
    // 挂上日志出口，模拟一次真会话在写日志。
    final logged = <String>[];
    buffer.onText = logged.add;
    addTearDown(() => buffer.onText = null);

    buffer.add('清屏之前\n');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    expect(find.textContaining('清屏之前'), findsOneWidget);

    await tester.tap(find.byTooltip('清屏'));
    await tester.pumpAndSettle();
    expect(find.textContaining('清屏之前'), findsNothing, reason: '显示内容该被清掉');

    buffer.add('清屏之后\n');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    expect(find.textContaining('清屏之后'), findsOneWidget);

    expect(logged.join(), contains('清屏之前'),
        reason: 'FR-O-05 只清显示：清屏不该让已经写进日志的内容消失');
    expect(logged.join(), contains('清屏之后'),
        reason: '清屏之后流还在继续，后续输出照常进日志');
  });

  testWidgets('半条控制序列不会渲染成字面文本（承接 5a 的留存边界）', (tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [fakeProfile(id: 'd1', name: 'A')],
      child: const SizedBox(height: 300, child: OutputPanel(deviceId: 'd1')),
    );

    final buffer = bufferOf(tester);
    buffer.add('前\x1b[3');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    expect(find.textContaining('[3'), findsNothing, reason: '半条序列应当被留住');

    buffer.add('2m绿\x1b[0m\n');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    expect(find.textContaining('绿'), findsOneWidget);
    expect(find.textContaining('2m'), findsNothing);
  });
}
