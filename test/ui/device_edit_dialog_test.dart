import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_manager.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/dialogs/device_edit_dialog.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_devdlg_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.text('打开')));

  DeviceProfile existing() => const DeviceProfile(
    id: 'd1',
    name: '核心交换机',
    protocol: DeviceProtocol.ssh,
    host: '10.0.0.1',
    port: 22,
    username: 'admin',
    password: 'secret',
  );

  Future<void> open(
    WidgetTester tester, {
    DeviceProfile? device,
    List<DeviceProfile> devices = const [],
    FakeSessionFactory? factory,
  }) async {
    await pumpDialogHost(
      tester,
      root: root,
      buttonLabel: '打开',
      devices: devices,
      factory: factory,
      open: (context) => DeviceEditDialog.show(context, existing: device),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  String fieldOf(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

  Future<void> fill(WidgetTester tester, String key, String text) =>
      tester.enterText(find.byKey(ValueKey(key)), text);

  Future<void> chooseProtocol(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const ValueKey('device-protocol')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  DeviceProfile stored(WidgetTester tester) =>
      containerOf(tester).read(devicesProvider).single;

  /// 把测试窗口调高到装得下整个对话框。
  ///
  /// **默认的 800×600 装不下**：对话框内容实测 798 逻辑像素高、视口只有 384，
  /// 折在窗口外的控件 `tap` 只会空点一下 —— 实测开关在 y=866、行尾符下拉在
  /// y=634，都在 600 之外（`ensureVisible` 也只把它滚到 516，仍在视口下沿
  /// 480 之外，因为内容末尾只有那个开关，滚到底也只够露出来一点点）。
  /// 需要**点到**窗口外那几个控件的用例先调这一下；断言一字未改。
  Future<void> useTallSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 等到 SnackBar 真的弹出来（最多 [rounds] 轮），动画走完再返回。
  ///
  /// **不能只靠 `settleDisk` / `pumpAndSettle`。** 「断开」走的是
  /// `_disconnect` → `await …disconnect()` → `_endLog()` → `_flush(force: true)`，
  /// 里面除了 `stat` / `create` / `writeAsString(flush: true)`，还有
  /// `restrictToOwner` 的 `Process.run('chmod', …)` —— **起一个真进程**。
  /// 假时钟推不动这些真 I/O，而 `settleDisk` 的轮数是写死的（12 × 5ms ≈ 60ms
  /// 真实时间），够不够全看机器当下忙不忙：实测同一份代码，多一句 `debugPrint`
  /// 就从红变绿。所以这里按条件等，出现即走。
  ///
  /// 注意状态断言**不能**代替它：`ConnectionManager` 的新状态是经 `onStatus`
  /// 回调推进 provider 的，不等 `_disconnect` 里那个 await —— 实测状态已经是
  /// `disconnected` 时 SnackBar 还一个都没有。
  Future<void> pumpUntilSnackBar(WidgetTester tester, {int rounds = 400}) async {
    for (var i = 0; i < rounds; i++) {
      if (find.byType(SnackBar).evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await tester.pumpAndSettle();
  }

  testWidgets('NFR-S-02：明文存储的警告就在对话框里', (tester) async {
    await open(tester);

    // **不能写成 `find.textContaining('明文')`。** 对话框里有**两个** Text 含
    // 「明文」：这条警告，和密码输入框的标签「密码（明文保存）」。本机
    // flutter 3.44.4 实测（起一个只有这两样东西的 scratch 用例跑出来的）：
    //   Expected: exactly one matching candidate
    //     Actual: Found 2 widgets with text containing 明文
    // 所以断言要挑那句独特的话，两处各断一次。
    expect(find.textContaining('明文保存在 devices.json'), findsOneWidget);
    expect(find.text('密码（明文保存）'), findsOneWidget);
  });

  testWidgets('新增：填完保存，设备进了列表（FR-D-01/FR-D-02）', (tester) async {
    await open(tester);

    await fill(tester, 'device-name', '边界防火墙');
    await fill(tester, 'device-host', '10.0.0.2');
    await fill(tester, 'device-username', 'admin');
    await fill(tester, 'device-password', 'p@ss');
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    final device = stored(tester);
    expect(device.name, '边界防火墙');
    expect(device.host, '10.0.0.2');
    expect(device.port, 22, reason: 'FR-D-03：SSH 默认端口 22');
    expect(device.password, 'p@ss');
    expect(device.id, isNotEmpty);
  });

  testWidgets('取消：什么都不写（FR-D-02）', (tester) async {
    await open(tester);

    await fill(tester, 'device-name', '写了也不该存');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await settleDisk(tester);

    expect(containerOf(tester).read(devicesProvider), isEmpty);
    expect(File('${root.path}/devices.json').existsSync(), isFalse);
  });

  testWidgets('重名被挡下，且一条都不写盘（FR-D-04）', (tester) async {
    await open(tester, devices: [existing()]);

    await fill(tester, 'device-name', '核心交换机');
    await fill(tester, 'device-host', '10.0.0.9');
    await fill(tester, 'device-username', 'admin');
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(find.textContaining('已有一台设备叫'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget, reason: '没保存成功，对话框不该关');
    expect(containerOf(tester).read(devicesProvider), hasLength(1));
  });

  testWidgets('编辑自己时重名检查把自己排除在外（FR-D-05）', (tester) async {
    await open(tester, devices: [existing()], device: existing());

    // 只改主机，名字原样不动 —— 这时"名字已存在"指的就是它自己。
    await fill(tester, 'device-host', '10.0.0.99');
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(stored(tester).host, '10.0.0.99');
    expect(stored(tester).id, 'd1', reason: 'id 是身份，编辑不改它');
  });

  testWidgets('端口不是 1..65535 的整数时挡下（FR-D-03）', (tester) async {
    await open(tester);
    await fill(tester, 'device-name', 'A');
    await fill(tester, 'device-host', 'h');
    await fill(tester, 'device-username', 'u');

    for (final bad in ['0', '65536', 'abc', '']) {
      await fill(tester, 'device-port', bad);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('端口必须是'),
        findsOneWidget,
        reason: '「$bad」应当被挡下',
      );
    }
    expect(containerOf(tester).read(devicesProvider), isEmpty);
  });

  testWidgets('切换协议时端口跟着换成默认端口（FR-D-03）', (tester) async {
    await open(tester);
    expect(fieldOf(tester, 'device-port'), '22');

    await chooseProtocol(tester, 'telnet');
    expect(fieldOf(tester, 'device-port'), '23');

    await chooseProtocol(tester, 'ssh');
    expect(fieldOf(tester, 'device-port'), '22');
  });

  testWidgets('用户自己填过端口之后，切协议不再改它（FR-D-03 的边界）', (tester) async {
    await open(tester);
    await fill(tester, 'device-port', '2222');

    await chooseProtocol(tester, 'telnet');

    expect(
      fieldOf(tester, 'device-port'),
      '2222',
      reason: '2222 是用户的选择，不该被协议默认值顶掉',
    );
  });

  testWidgets('编辑已有设备时，盘上那个端口算"用户填过"', (tester) async {
    await open(
      tester,
      device: existing().copyWith(port: 2222),
      devices: [existing().copyWith(port: 2222)],
    );
    expect(fieldOf(tester, 'device-port'), '2222');

    await chooseProtocol(tester, 'telnet');

    expect(fieldOf(tester, 'device-port'), '2222');
  });

  testWidgets('提示符正则编译不了时挡下（FR-G-03）', (tester) async {
    await open(tester);
    await fill(tester, 'device-name', 'A');
    await fill(tester, 'device-host', 'h');
    await fill(tester, 'device-username', 'u');
    await fill(tester, 'device-prompt-regex', '[unclosed');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('提示符正则无法编译'), findsOneWidget);
    expect(containerOf(tester).read(devicesProvider), isEmpty);
  });

  testWidgets('清空密码存下来的是 null 而不是空串（`_unset` 的语义）', (tester) async {
    await open(tester, devices: [existing()], device: existing());

    await fill(tester, 'device-password', '');
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(
      stored(tester).password,
      isNull,
      reason: '空串会让「不启用密码认证」这条路径变成"用一个空密码去认证"',
    );
  });

  testWidgets('「登录后执行」按行切、丢掉空行（FR-D-11）', (tester) async {
    await open(tester);
    await fill(tester, 'device-name', 'A');
    await fill(tester, 'device-host', 'h');
    await fill(tester, 'device-username', 'u');
    await fill(tester, 'device-post-login', 'enable\n\n  \nterminal length 0');

    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(stored(tester).postLoginCommands, [
      'enable',
      'terminal length 0',
    ]);
  });

  testWidgets('「启动时自动连接」存得下来（FR-D-12）', (tester) async {
    await useTallSurface(tester);
    await open(tester);
    await fill(tester, 'device-name', 'A');
    await fill(tester, 'device-host', 'h');
    await fill(tester, 'device-username', 'u');

    await tester.tap(find.byKey(const ValueKey('device-autoconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(stored(tester).autoConnect, isTrue);
  });

  testWidgets('新增时没有「断开」按钮（FR-C-05 只对已存在的设备）', (tester) async {
    await open(tester);

    expect(find.text('断开'), findsNothing);
  });

  testWidgets('编辑已有设备时可以就地断开（FR-C-05）', (tester) async {
    final factory = FakeSessionFactory();
    await open(tester, device: existing(), devices: [existing()], factory: factory);

    containerOf(tester).read(sessionProvider('d1').notifier).connect();
    await tester.pumpAndSettle();
    expect(
      containerOf(tester).read(sessionProvider('d1')).state,
      DeviceConnectionState.connected,
    );

    await tester.tap(find.text('断开'));
    await pumpUntilSnackBar(tester);

    expect(
      containerOf(tester).read(sessionProvider('d1')).state,
      DeviceConnectionState.disconnected,
    );
    expect(find.textContaining('已断开'), findsOneWidget);
  });

  testWidgets('行尾符是可选的两种（FR-G-03）', (tester) async {
    await useTallSurface(tester);
    await open(tester);
    await fill(tester, 'device-name', 'A');
    await fill(tester, 'device-host', 'h');
    await fill(tester, 'device-username', 'u');

    await tester.tap(find.byKey(const ValueKey('device-line-ending')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CRLF (\\r\\n)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(stored(tester).lineEnding, '\r\n');
  });
}
