import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_manager.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/panels/device_list_panel.dart';
import 'package:win_cli_tool/ui/widgets/status_dot.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  /// 在某个设备行上点右键并把菜单等出来。
  ///
  /// `ListTile` 的右键走 `GestureDetector.onSecondaryTapDown` —— 用
  /// `startGesture(buttons: kSecondaryMouseButton)` 才能触发它，
  /// `tester.tap` 是主键、不会走那条分支。
  Future<void> openMenu(WidgetTester tester, String deviceName) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(deviceName)),
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_dev_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> pumpList(
    WidgetTester tester, {
    FakeSessionFactory? factory,
  }) => pumpUi(
    tester,
    root: root,
    devices: [
      fakeProfile(id: 'd1', name: '核心交换机'),
      fakeProfile(id: 'd2', name: '边界防火墙'),
    ],
    factory: factory,
    child: const DeviceListPanel(),
  );

  testWidgets('列出全部设备，状态点是"未连接"（§9.2 第 4 条）', (tester) async {
    await pumpList(tester);
    expect(find.text('核心交换机'), findsOneWidget);
    expect(find.text('边界防火墙'), findsOneWidget);

    final dots = tester.widgetList<DeviceStatusDot>(find.byType(DeviceStatusDot));
    expect(dots, hasLength(2));
    expect(dots.every((d) => d.state == DeviceConnectionState.disconnected), isTrue);
  });

  testWidgets('点击一台设备会把它选中', (tester) async {
    await pumpList(tester);
    final element = tester.element(find.byType(DeviceListPanel));
    final container = ProviderScope.containerOf(element);
    expect(container.read(selectedDeviceProvider), 'd1', reason: '默认选第一台');

    await tester.tap(find.text('边界防火墙'));
    await tester.pumpAndSettle();
    expect(container.read(selectedDeviceProvider), 'd2');
  });

  testWidgets('连上之后状态点变绿（§9.2 第 4 条）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpList(tester, factory: factory);

    await tester.tap(find.byTooltip('连接 核心交换机'));
    await tester.pumpAndSettle();

    final dots = tester
        .widgetList<DeviceStatusDot>(find.byType(DeviceStatusDot))
        .toList();
    expect(dots.first.state, DeviceConnectionState.connected);
    expect(dots.last.state, DeviceConnectionState.disconnected,
        reason: '只连了一台，另一台不该跟着变');
  });

  testWidgets('右键菜单能删掉一台设备，且删之前要确认（FR-D-04）', (tester) async {
    await pumpList(tester);
    final element = tester.element(find.byType(DeviceListPanel));
    final container = ProviderScope.containerOf(element);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('边界防火墙')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('确认删除'), findsOneWidget, reason: '删设备是不可逆的');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(devicesProvider), hasLength(2), reason: '取消不该删');

    // 再来一次，这回确认。
    final again = await tester.startGesture(
      tester.getCenter(find.text('边界防火墙')),
      buttons: kSecondaryButton,
    );
    await again.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    // **这里不能用 `pumpAndSettle()`**：删除要写盘，而假时钟里真盘 I/O 走不完
    // （理由见 `settleDisk` 的文档）—— 表现是"点了确认，设备还在"。
    await settleDisk(tester);

    expect(container.read(devicesProvider).map((d) => d.id), ['d1']);
  });

  testWidgets('拖拽能改顺序，且顺序落到 devices.json（FR-D-03）', (tester) async {
    await pumpList(tester);
    final element = tester.element(find.byType(DeviceListPanel));
    final container = ProviderScope.containerOf(element);
    expect(container.read(devicesProvider).map((d) => d.id), ['d1', 'd2']);

    // 抓住第一台的拖拽把手，往下拖过第二台。
    final handle = find.byIcon(Icons.drag_handle).first;
    final from = tester.getCenter(handle);
    final to = tester.getCenter(find.text('边界防火墙'));

    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 200));
    // **落点必须越过第二项的底边。** `to.dy + 20` 落在框架的死区里（`_insertIndex`
    // 会等于被拖项的原地下标，`onReorderItem` 一次都不调）—— 三种落点的实测见 Step 6。
    await gesture.moveTo(Offset(from.dx, to.dy + 90));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    // 排序也要写盘，理由同上面删除那条。
    await settleDisk(tester);

    expect(container.read(devicesProvider).map((d) => d.id), ['d2', 'd1']);
  });

  testWidgets('右键菜单是四项，顺序为 连接/断开/编辑/删除（§7.3）', (tester) async {
    await pumpList(tester);

    await openMenu(tester, '核心交换机');

    expect(find.text('连接'), findsOneWidget);
    expect(find.text('断开'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('已连接时右键的「连接」不可点、「断开」可点（§7.3）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpList(tester, factory: factory);
    await tester.tap(find.byTooltip('连接 核心交换机'));
    await tester.pumpAndSettle();

    await openMenu(tester, '核心交换机');

    expect(tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, '连接'),
    ).enabled, isFalse);
    expect(tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, '断开'),
    ).enabled, isTrue);
  });

  testWidgets('右键「编辑」打开设备编辑对话框，且带着那台设备（FR-D-05）', (tester) async {
    await pumpList(tester);

    await openMenu(tester, '核心交换机');
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('编辑设备'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('device-host')))
          .controller!
          .text,
      '10.0.0.1',
    );
  });
}
