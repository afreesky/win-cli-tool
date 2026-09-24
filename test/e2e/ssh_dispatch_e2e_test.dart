import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/command_dispatcher.dart';
import 'package:win_cli_tool/command/more_pager.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/connection/ssh_session.dart';
import 'package:win_cli_tool/models/device_profile.dart';

import '../fixtures/sshd_harness.dart';

void main() {
  final skipReason = SshdHarness.unavailableReason;
  late SshdHarness sshd;

  setUpAll(() async {
    if (skipReason == null) sshd = await SshdHarness.start();
  });

  tearDownAll(() async {
    if (skipReason == null) await sshd.stop();
  });

  test('命令经 SSH 下发、被对端执行、输出回流', () async {
    final session = SshSession(
      profile: DeviceProfile(
        id: 'd1',
        name: '本地 sshd',
        protocol: DeviceProtocol.ssh,
        host: '127.0.0.1',
        port: sshd.port,
        username: sshd.user,
        privateKeyPath: sshd.privateKeyPath,
        lineEnding: '\n',
      ),
      hostKeyStore: InMemoryHostKeyStore(),
      onUnknownHostKey: (h) async => true,
    );

    await session.connect();

    final promptDetector = PromptDetector();

    // 把提示符设成一个网络设备风格的串，让默认提示符正则能命中。
    final dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: promptDetector,
      morePager: MorePager(),
      lineEnding: '\n',
    );

    final output = StringBuffer();
    final events = <DispatchEvent>[];
    dispatcher.events.listen(events.add);

    session.output.listen((chunk) {
      output.write(chunk);
      dispatcher.onOutput(chunk);
    });

    // 先摆好提示符，再等它**真的**出现。
    //
    // 判据不能是 `output.contains('RTR> ')`：PTY 会把这一行命令原样回显，
    // 于是那个串在**回显**里就已经出现了 —— 循环会在一行提示符都没打印
    // 出来之前退出（实测确实如此），调度器紧接着就往一个还没走到提示符的
    // shell 里写命令。改成「缓冲区里最后一个非空行就是提示符」，与
    // [PromptDetector] 判定命令结束用的是**同一个谓词**：回显行
    // `PS1='RTR> '` 以引号结尾，匹配不上默认正则（`[>#\]]\s*$`），
    // 因此只有对端真的把提示符打出来，这个循环才会退出。
    session.write("PS1='RTR> '\n");
    final settle = DateTime.now().add(const Duration(seconds: 10));
    while (!promptDetector.matches(output.toString()) &&
        DateTime.now().isBefore(settle)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    dispatcher.enqueue(['echo E2E_MARKER', 'echo SECOND']);

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (events.whereType<QueueFinished>().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    // 两条命令都被对端真正执行了
    expect(output.toString(), contains('E2E_MARKER'));
    expect(output.toString(), contains('SECOND'));

    // 两条命令都正常完成（没有靠超时兜底）
    final completed = events.whereType<CommandCompleted>().toList();
    expect(completed.length, 2);
    expect(completed.every((c) => !c.timedOut), isTrue,
        reason: '提示符判定应该命中，不应走到超时');

    // 顺序正确
    expect(completed.map((c) => c.command).toList(),
        ['echo E2E_MARKER', 'echo SECOND']);

    await dispatcher.dispose();
    await session.close();
  }, skip: skipReason);
}
