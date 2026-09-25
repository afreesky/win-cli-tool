import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/main_window.dart';
import 'package:win_cli_tool/ui/panels/device_list_panel.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';
import 'package:win_cli_tool/ui/panels/output_panel.dart';

import '../fixtures/fake_session.dart';
import 'golden_harness.dart';
import 'ui_harness.dart';

/// golden 的开关：**默认跳过**。
///
/// 跑它们：
/// ```
/// WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart
/// ```
/// 界面改样子之后重新生成：
/// ```
/// WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart --update-goldens
/// ```
///
/// **为什么不默认跑**：golden 的比对结果取决于字体文件与渲染后端。换机器、
/// 换字体版本、换 Flutter 版本都会变 —— 而那不是回归。默认跑的下场是
/// `flutter test` 在别人机器上变红，然后所有人学会忽略红。
void main() {
  // **跳过而不是失败** —— 理由见上面那段说明。两个条件都写在这里：
  // 没设 `WCT_GOLDEN=1`，或者本机没有 golden 需要的中文字体。
  final skip = !goldensEnabled || !fontsAvailable;

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_golden_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  // **只改夹具，不改产品代码。**
  final devices = [
    fakeProfile(id: 'd1', name: '核心交换机-01', host: '10.0.0.1'),
    fakeProfile(id: 'd2', name: '边界防火墙', host: '10.0.0.254'),
    fakeProfile(id: 'd3', name: '接入交换机-3F', host: '10.0.1.7'),
  ];

  /// 往缓冲里灌一段**带颜色**的、像真设备回显的输出。
  void seedOutput(WidgetTester tester, Finder host, String deviceId) {
    final container = ProviderScope.containerOf(tester.element(host));
    final buffer = container.read(outputBufferProvider(deviceId));
    buffer.add('\x1b[1m<Huawei>display version\x1b[0m\n');
    buffer.add('Huawei Versatile Routing Platform Software\n');
    buffer.add('VRP (R) software, Version 8.180 (CE6865 V200R019C10SPC800)\n');
    buffer.add('\x1b[32mInfo:\x1b[0m 系统运行正常，已运行 \x1b[33m42\x1b[0m 天\n');
    buffer.add('\x1b[31mError:\x1b[0m 接口 GE0/0/3 光模块 \x1b[7m不在位\x1b[0m\n');
    buffer.add('<Huawei>');
  }

  testWidgets('主窗口 —— 浅色', (tester) async {
    await loadTestFonts();
    useGoldenSurface(tester);
    await pumpForGolden(
      tester,
      root: root,
      brightness: Brightness.light,
      devices: devices,
      child: const MainWindow(),
    );
    seedOutput(tester, find.byType(MainWindow), 'd1');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();

    await expectLater(
      find.byType(MainWindow),
      matchesGoldenFile('golden/main_window_light.png'),
    );
  }, skip: skip);

  testWidgets('主窗口 —— 深色', (tester) async {
    await loadTestFonts();
    useGoldenSurface(tester);
    await pumpForGolden(
      tester,
      root: root,
      brightness: Brightness.dark,
      settings: const AppSettings(theme: AppTheme.dark),
      devices: devices,
      child: const MainWindow(),
    );
    seedOutput(tester, find.byType(MainWindow), 'd1');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();

    await expectLater(
      find.byType(MainWindow),
      matchesGoldenFile('golden/main_window_dark.png'),
    );
  }, skip: skip);

  testWidgets('面板 —— 设备列表 / 编辑区 / 输出区', (tester) async {
    await loadTestFonts();
    useGoldenSurface(tester, size: const Size(360, 520));

    await pumpForGolden(
      tester,
      root: root,
      brightness: Brightness.light,
      devices: devices,
      child: const Scaffold(body: DeviceListPanel()),
    );
    await expectLater(
      find.byType(DeviceListPanel),
      matchesGoldenFile('golden/device_list_panel.png'),
    );

    await pumpForGolden(
      tester,
      root: root,
      brightness: Brightness.light,
      devices: devices,
      child: const Scaffold(body: EditorPanel(deviceId: 'd1')),
    );
    // **先让草稿读出来（`settleDisk`），再打字。** 那次读是**真盘 I/O**，
    // 假时钟里走不完 —— 读不完 `_seeded` 就是 false，而 `_onTextChanged` 在
    // `_seeded` 为 false 时直接返回、**不 `setState`**。后果是行号栏停在
    // "1"：编辑区里五行字，行号却只有一个（实测）。真机上草稿读得完，不会有
    // 这个现象，所以这里要把它等出来，否则 golden 拍的是一个假状态。
    await settleDisk(tester);
    await tester.enterText(
      find.byType(TextField),
      'sys\ninterface GE0/0/1\n description 上行链路\ndisplay version\nquit',
    );
    await tester.pump();
    await expectLater(
      find.byType(EditorPanel),
      matchesGoldenFile('golden/editor_panel.png'),
    );

    await pumpForGolden(
      tester,
      root: root,
      brightness: Brightness.light,
      devices: devices,
      child: const Scaffold(body: OutputPanel(deviceId: 'd1')),
    );
    seedOutput(tester, find.byType(OutputPanel), 'd1');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    await expectLater(
      find.byType(OutputPanel),
      matchesGoldenFile('golden/output_panel.png'),
    );
  }, skip: skip);
}
