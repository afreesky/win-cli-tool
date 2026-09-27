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
    root = await Directory.systemTemp.createTemp('wct_params_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  DeviceProfile base() => const DeviceProfile(
    id: 'd1',
    name: '核心交换机',
    protocol: DeviceProtocol.ssh,
    host: '10.0.0.1',
    port: 22,
    username: 'admin',
    postLoginCommands: ['enable'],
  );

  group('connectionParamsDiffer（字段分类的穷举）', () {
    test('显示字段不算连接参数', () {
      final before = base();

      expect(connectionParamsDiffer(before, before.copyWith(name: '改名')), isFalse);
      expect(
        connectionParamsDiffer(before, before.copyWith(autoConnect: true)),
        isFalse,
      );
      expect(
        connectionParamsDiffer(
          before,
          before.copyWith(
            snippets: const [Snippet(id: 's1', name: 'n', content: 'c')],
          ),
        ),
        isFalse,
      );
    });

    test('每一个连接参数字段改了都算', () {
      final before = base();
      final changed = <String, DeviceProfile>{
        'protocol': before.copyWith(protocol: DeviceProtocol.telnet),
        'host': before.copyWith(host: '10.0.0.2'),
        'port': before.copyWith(port: 2222),
        'username': before.copyWith(username: 'root'),
        'password': before.copyWith(password: 'x'),
        'privateKeyPath': before.copyWith(privateKeyPath: '/tmp/k'),
        'lineEnding': before.copyWith(lineEnding: '\r\n'),
        'promptRegex': before.copyWith(promptRegex: r'[>#]\s*$'),
        'postLoginCommands': before.copyWith(postLoginCommands: ['enable', 'conf t']),
      };

      for (final entry in changed.entries) {
        expect(
          connectionParamsDiffer(before, entry.value),
          isTrue,
          reason: '${entry.key} 是连接参数，改了就该断开',
        );
      }
    });

    test('同内容的新列表实例算相同（list 不按 identity 比）', () {
      // **两个 list 必须真的是两个实例。** 初稿两边都写 `const []`，而 Dart 会把
      // 它们**规范化成同一个对象** —— 那样 `a == b` 靠 identity 就成立了，这条
      // 用例在**没有** `_sameJsonValue` 那份列表逻辑时照样绿（和 Task 1 的 const
      // 规范化是同一类：断言在测空气）。`List.of` 保证拿到新实例。
      final before = base().copyWith(
        postLoginCommands: List<String>.of(const ['enable']),
      );
      final after = base().copyWith(
        postLoginCommands: List<String>.of(const ['enable']),
      );

      expect(
        identical(before.postLoginCommands, after.postLoginCommands),
        isFalse,
        reason: '前提：两个不同的列表实例',
      );
      expect(connectionParamsDiffer(before, after), isFalse);
      expect(
        connectionParamsDiffer(
          before,
          before.copyWith(postLoginCommands: ['other']),
        ),
        isTrue,
      );
    });
  });

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.text('打开')));

  DeviceConnectionState stateOf(WidgetTester tester) =>
      containerOf(tester).read(sessionProvider('d1')).state;

  Future<void> openConnected(
    WidgetTester tester, {
    required DeviceProfile device,
  }) async {
    // 对话框内容比默认的 800×600 窗口高，靠下的开关点不到 —— 见 `useTallSurface`。
    // 四条用例都走这个口，所以放在这里。
    await useTallSurface(tester);
    await pumpDialogHost(
      tester,
      root: root,
      buttonLabel: '打开',
      devices: [device],
      factory: FakeSessionFactory(),
      open: (context) => DeviceEditDialog.show(context, existing: device),
    );
    containerOf(tester).read(sessionProvider('d1').notifier).connect();
    // 连接要开日志文件（真 I/O），假时钟推不动 —— 等的是**状态本身**，
    // 不是帧数，也不是某个 Finder（这时对话框还没开）。
    await pumpUntilTrue(
      tester,
      () => stateOf(tester) == DeviceConnectionState.connected,
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(stateOf(tester), DeviceConnectionState.connected, reason: '前置条件');
  }

  Future<void> fill(WidgetTester tester, String key, String text) =>
      tester.enterText(find.byKey(ValueKey(key)), text);

  // `drainCommandTimeout`（把"会话还连着"留下的挂起定时器推过）在
  // `ui_harness.dart` 里 —— 它不是这一个文件的事，凡是有用例让会话保持连接
  // 到结束，都会撞上 `flutter_test` 那条 `!timersPending`。

  testWidgets('改了主机：保存后会话被断开，并提示重连', (tester) async {
    await openConnected(tester, device: base());

    await fill(tester, 'device-host', '10.0.0.2');
    await tester.tap(find.text('保存'));
    // **不能用 `settleDisk`。** 这条路上有两段真 I/O：`update(draft)` 落盘，
    // 然后是 `disconnect()` 收尾（含 `restrictToOwner` 起的 chmod 真进程）。
    // 按条件等 SnackBar，出现即走。
    await pumpUntilSnackBar(tester);

    expect(stateOf(tester), DeviceConnectionState.disconnected);
    expect(find.textContaining('连接参数已改变'), findsOneWidget);
    expect(
      containerOf(tester).read(devicesProvider).single.host,
      '10.0.0.2',
      reason: '断开不影响保存本身',
    );
  });

  testWidgets('改了「登录后执行」：也算连接参数，断开', (tester) async {
    await openConnected(tester, device: base());

    await fill(tester, 'device-post-login', 'enable\nconf t');
    await tester.tap(find.text('保存'));
    // 这条只断状态、不断 SnackBar，但断到的那个状态要等真 I/O 走完
    // （同样不能用 `settleDisk`）。
    await pumpUntilTrue(
      tester,
      () => stateOf(tester) == DeviceConnectionState.disconnected,
    );

    expect(
      stateOf(tester),
      DeviceConnectionState.disconnected,
      reason: '登录后命令要重连才会重新下发（FR-C-08）',
    );
  });

  testWidgets('只改名字：会话不动', (tester) async {
    await openConnected(tester, device: base());

    await fill(tester, 'device-name', '核心交换机 A');
    await tester.tap(find.text('保存'));
    // **这两条"不该断开"的用例要等到对话框真的关掉为止，不能只 `settleDisk`。**
    // `_submit` 是**先 `await update(draft)`、再（若需要）`await disconnect()`、
    // 最后才 `pop()`**，所以"对话框关了"这件事本身就证明了整条保存路径已经跑完
    // —— 包括那个本该发生却没发生的断开。只推 60ms 真实时间的话，万一这条路上
    // 还有没走完的真 I/O，`findsNothing` 与 `connected` 都会在你还没等到的时候
    // 就先绿了（负向断言尤其容易被这种"还没轮到"骗过去）。
    await pumpUntilTrue(tester, () => find.text('保存').evaluate().isEmpty);

    expect(
      stateOf(tester),
      DeviceConnectionState.connected,
      reason: '改名字不该打断一条好好跑着的会话',
    );
    expect(find.textContaining('连接参数已改变'), findsNothing);
    expect(containerOf(tester).read(devicesProvider).single.name, '核心交换机 A');

    // 会话在这里是**故意**还连着的（上面刚断言过），而 `base()` 的
    // `postLoginCommands` 在连接时排进队列、起了一个 10s 命令超时定时器。
    // 不推过它，本用例会红在断言之外。详见 `ui_harness.dart` 的文档。
    await drainCommandTimeout(tester);
  });

  testWidgets('只改「启动时自动连接」：会话不动', (tester) async {
    await openConnected(tester, device: base());

    await tester.tap(find.byKey(const ValueKey('device-autoconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    // 同「只改名字」：等对话框关掉，才算保存路径整条走完。
    await pumpUntilTrue(tester, () => find.text('保存').evaluate().isEmpty);

    expect(stateOf(tester), DeviceConnectionState.connected);
    expect(containerOf(tester).read(devicesProvider).single.autoConnect, isTrue);

    // 同上：会话还连着，收尾要把那个命令超时定时器推过去。
    await drainCommandTimeout(tester);
  });

  testWidgets('改提权设置算连接参数变更 → 断开（决策①）', (tester) async {
    // 提权参数不在 `_displayOnlyFields` 里，所以它自动算连接参数。
    // 这条用例把这个"自动"钉住：哪天有人往白名单里加了 enableCommand，
    // 改提权设置就会静默地不断线，而界面上设备行看起来已经改好了。
    await openConnected(tester, device: base());
    await fill(tester, 'device-enable-command', 'en');
    await tester.tap(find.text('保存'));
    // 这条路上有两段真 I/O：`update(draft)` 落盘 + `disconnect()` 收尾
    // （含 chmod 真进程）。`settleDisk` 不够，要按条件等 SnackBar。
    await pumpUntilSnackBar(tester);

    expect(find.text('连接参数已改变，已断开该设备，请重新连接'), findsOneWidget);
  });
}
