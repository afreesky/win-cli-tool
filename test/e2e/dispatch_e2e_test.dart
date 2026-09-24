import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/command_dispatcher.dart';
import 'package:win_cli_tool/command/more_pager.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';
import 'package:win_cli_tool/connection/telnet_session.dart';
import 'package:win_cli_tool/models/device_profile.dart';

import '../fixtures/fake_device_server.dart';

/// 把会话与命令队列接起来，模拟界面层要做的接线。
class _Wired {
  _Wired(this.session) {
    dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: PromptDetector(),
      morePager: MorePager(),
      lineEnding: '\n',
      promptDebounce: const Duration(milliseconds: 120),
      commandTimeout: const Duration(seconds: 10),
    );
    _sub = session.output.listen(dispatcher.onOutput);
    // session.done 是 Future 不是 Stream，所以用 then 而非 listen
    session.done.then((_) => dispatcher.onDisconnected());
  }

  final TelnetSession session;
  late final CommandDispatcher dispatcher;
  StreamSubscription<String>? _sub;

  Future<void> dispose() async {
    await _sub?.cancel();
    await dispatcher.dispose();
    await session.close();
  }
}

DeviceProfile _profile(int port) => DeviceProfile(
      id: 'd1',
      name: '假设备',
      protocol: DeviceProtocol.telnet,
      host: '127.0.0.1',
      port: port,
      username: 'admin',
    );

void main() {
  test('三条命令在真实连接上按序、串行完成', () async {
    final device = await FakeDeviceServer.start(
      prompt: '[CoreSW]',
      responseFor: {
        'sys': ['Enter system view'],
        'interface GE0/0/1': ['Interface created'],
        'quit': ['Back to user view'],
      },
    );
    addTearDown(device.stop);

    final session = TelnetSession(profile: _profile(device.port));
    final wired = _Wired(session);
    addTearDown(wired.dispose);

    final output = <String>[];
    session.output.listen(output.add);

    await session.connect();

    wired.dispatcher.enqueue(['sys', 'interface GE0/0/1', 'quit']);
    await _waitUntil(() => !wired.dispatcher.isBusy);

    expect(device.receivedCommands, ['sys', 'interface GE0/0/1', 'quit']);

    final all = output.join();
    expect(all, contains('Enter system view'));
    expect(all, contains('Interface created'));
    expect(all, contains('Back to user view'));
  });

  test('空行被跳过，设备收不到空命令', () async {
    final device = await FakeDeviceServer.start(prompt: '[CoreSW]');
    addTearDown(device.stop);

    final session = TelnetSession(profile: _profile(device.port));
    final wired = _Wired(session);
    addTearDown(wired.dispose);
    await session.connect();

    wired.dispatcher.enqueue(['sys', '', '   ', 'save']);
    await _waitUntil(() => !wired.dispatcher.isBusy);

    expect(device.receivedCommands, ['sys', 'save']);
  });

  test('分页输出被自动翻页，最终完整到达', () async {
    final device = await FakeDeviceServer.start(
      prompt: '[CoreSW]',
      pagerEvery: 2,
      responseFor: {
        'display current-configuration': [
          'line1',
          'line2',
          'line3',
          'line4',
          'line5',
        ],
      },
    );
    addTearDown(device.stop);

    final session = TelnetSession(profile: _profile(device.port));
    final wired = _Wired(session);
    addTearDown(wired.dispose);

    final output = <String>[];
    session.output.listen(output.add);
    final pagerEvents = <DispatchEvent>[];
    wired.dispatcher.events.listen(pagerEvents.add);

    await session.connect();
    wired.dispatcher.enqueue(['display current-configuration', 'done-marker']);
    await _waitUntil(() => !wired.dispatcher.isBusy);

    final all = output.join();
    for (final l in ['line1', 'line2', 'line3', 'line4', 'line5']) {
      expect(all, contains(l), reason: '分页内容 $l 应当完整到达');
    }
    expect(pagerEvents.whereType<PagerContinued>(), isNotEmpty);
    expect(device.receivedCommands, ['display current-configuration', 'done-marker']);
  });

  test('命令不回应时超时，队列继续往下走', () async {
    final device = await FakeDeviceServer.start(
      prompt: '[CoreSW]',
      hangCommands: {'reboot'},
    );
    addTearDown(device.stop);

    final session = TelnetSession(profile: _profile(device.port));
    addTearDown(session.close);
    await session.connect();

    // 真实超时默认 10s，测试里等不起，所以单独构造一个短超时的调度器。
    // 这里不用 _Wired：本测试只关心调度器本身，且两个调度器同时消费
    // session.output 会让数据流互相干扰。
    final dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: PromptDetector(),
      morePager: MorePager(),
      commandTimeout: const Duration(milliseconds: 500),
      promptDebounce: const Duration(milliseconds: 100),
    );
    final sub = session.output.listen(dispatcher.onOutput);
    addTearDown(sub.cancel);
    addTearDown(dispatcher.dispose);

    final completions = <CommandCompleted>[];
    dispatcher.events.listen((e) {
      if (e is CommandCompleted) completions.add(e);
    });

    dispatcher.enqueue(['reboot', 'display version']);
    await _waitUntil(
      () => !dispatcher.isBusy,
      timeout: const Duration(seconds: 8),
    );

    expect(completions, hasLength(2));
    expect(completions.first.command, 'reboot');
    expect(completions.first.timedOut, isTrue);
    expect(completions.first.index, 1);
    expect(completions.first.total, 2);
    expect(completions.last.command, 'display version');
    expect(completions.last.timedOut, isFalse);
    expect(device.receivedCommands, contains('display version'));
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('设备断开时队列被丢弃且不重放', () async {
    // 'a' 永不返回提示符，队列因此必然停在半途：
    // 'a' 在途、'b' 与 'c' 还在排队。否则三条命令可能瞬间跑完，
    // 断开时已经没有东西可丢，测试会变成一道竞态。
    final device = await FakeDeviceServer.start(
      prompt: '[CoreSW]',
      hangCommands: {'a'},
    );
    final session = TelnetSession(profile: _profile(device.port));
    final wired = _Wired(session);
    addTearDown(wired.dispose);
    await session.connect();

    final dropped = <QueueDropped>[];
    wired.dispatcher.events.listen((e) {
      if (e is QueueDropped) dropped.add(e);
    });

    wired.dispatcher.enqueue(['a', 'b', 'c']);
    await _waitUntil(() => device.receivedCommands.contains('a'));
    expect(wired.dispatcher.isBusy, isTrue);

    await device.stop();
    await _waitUntil(() => dropped.isNotEmpty);

    // 在途的 'a' 加排队的 'b'、'c'，共 3 条
    expect(dropped.single.count, 3);
    expect(wired.dispatcher.isBusy, isFalse);
    // 断线后不得重放：设备侧只见过 'a'
    expect(device.receivedCommands, ['a']);
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
