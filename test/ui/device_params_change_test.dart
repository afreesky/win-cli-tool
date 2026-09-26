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

  /// 清掉"会话到用例结束还是活的"留下的挂起定时器。
  ///
  /// 两条**不该断开**的用例里，会话是**故意**保持连接的，而 `connect()` 会把
  /// `base()` 的 `postLoginCommands`（`['enable']`）排进 `CommandDispatcher`
  /// —— 那会起一个 10s 的**命令超时**定时器（`commandTimeout` 没被覆盖，就是
  /// 默认的 10s）。`FakeSession` 从不吐提示符，所以它一直挂着；而 `flutter_test`
  /// 在用例体结束时断言"没有挂着的定时器"（`binding.dart` 的 `!timersPending`），
  /// 不推过它，用例就红在**断言之外**（两条正向用例不红，正是因为它们的断开把
  /// dispatcher 连同定时器一起拆了）。
  ///
  /// 推过它是安全的、也不改任何断言的意图：定时器到点只是把那条命令记成"超时"、
  /// 队列收尾（`_finish()` 取消所有定时器），**连接状态不受影响** —— 这两条用例
  /// 要断言的恰恰就是"这条会话还连着"。调用点都在所有断言**之后**。
  Future<void> drainCommandTimeout(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
  }

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

    await drainCommandTimeout(tester);
  });
}
