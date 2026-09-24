import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
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

  SshSession sessionWith(
    HostKeyStore store, {
    bool verify = true,
    Future<bool> Function(KnownHost)? onUnknown,
  }) =>
      SshSession(
        profile: DeviceProfile(
          id: 'd1',
          name: '本地 sshd',
          protocol: DeviceProtocol.ssh,
          host: '127.0.0.1',
          port: sshd.port,
          username: sshd.user,
          privateKeyPath: sshd.privateKeyPath,
        ),
        hostKeyStore: store,
        verifyHostKey: verify,
        onUnknownHostKey: onUnknown,
      );

  test('首次连接会询问指纹，接受后写入 store', () async {
    final store = InMemoryHostKeyStore();
    KnownHost? asked;

    final session = sessionWith(store, onUnknown: (h) async {
      asked = h;
      return true;
    });

    await session.connect();

    expect(asked, isNotNull);
    // 与**真主机密钥**的指纹比，而不是只比一个 'SHA256:' 前缀：
    // 前缀断言放得过任何自洽但错误的指纹（截断、或串了另一把密钥）。
    expect(asked!.fingerprint, sshd.hostFingerprint());
    expect(store.all.single.fingerprint, asked!.fingerprint);

    await session.close();
  }, skip: skipReason);

  test('已记录的主机不再询问，直接连上', () async {
    final store = InMemoryHostKeyStore();
    var askCount = 0;

    final first = sessionWith(store, onUnknown: (h) async {
      askCount++;
      return true;
    });
    await first.connect();
    await first.close();
    expect(askCount, 1);

    final second = sessionWith(store, onUnknown: (h) async {
      askCount++;
      return true;
    });
    await second.connect();
    await second.close();

    expect(askCount, 1, reason: '第二次不应再询问');
  }, skip: skipReason);

  test('用户拒绝指纹则连不上', () async {
    final store = InMemoryHostKeyStore();
    var asked = false;
    final session = sessionWith(store, onUnknown: (h) async {
      asked = true;
      return false;
    });

    // 具体类型，而不是 throwsA(anything)：后者被**任何**异常满足，分不出
    // "因用户拒绝被拒"与"因别的缘故提前失败"。实测（Task 7 复检探针）：
    // 两条拒绝路径抛的都是 SSHAuthAbortError，其 .reason 是 SSHHostkeyError
    // —— 不是裸的 SSHHostkeyError。
    await expectLater(
      session.connect(),
      throwsA(isA<SSHAuthAbortError>()
          .having((e) => e.reason, 'reason', isA<SSHHostkeyError>())),
    );
    expect(asked, isTrue, reason: '拒绝分支真的被走到过 —— 否则这条用例是空转');
    expect(store.all, isEmpty);

    await session.close();
  }, skip: skipReason);

  test('指纹与已记录的不一致时拒绝连接', () async {
    final store = InMemoryHostKeyStore();
    // 预置一条错误的指纹
    await store.save(KnownHost(
      host: '127.0.0.1',
      port: sshd.port,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:this-is-not-the-real-fingerprint',
    ));

    var asked = false;
    final session = sessionWith(store, onUnknown: (h) async {
      asked = true;
      return true;
    });

    // 具体类型，与上一条同一判据：抛的必须是"因主机密钥被拒"这一类，
    // 而不是随便什么提前失败（如注入的 ConnectionFailure）。
    await expectLater(
      session.connect(),
      throwsA(isA<SSHAuthAbortError>()
          .having((e) => e.reason, 'reason', isA<SSHHostkeyError>())),
    );
    expect(asked, isFalse, reason: '有记录时不应回退到询问用户');

    await session.close();
  }, skip: skipReason);

  test('主动 close() 不触发 done —— client.close() 会完成 session.done，'
      '必须被 _closed 守卫挡住（spec §13.14-5）', () async {
    final store = InMemoryHostKeyStore();
    final session = sessionWith(store, onUnknown: (h) async => true);

    await session.connect();

    var doneFired = false;
    unawaited(session.done.then((_) => doneFired = true));

    await session.close();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(doneFired, isFalse,
        reason: '主动关闭不得被看成意外断线 —— 否则退出应用会触发一轮自动重连');
  }, skip: skipReason);

  test('真实会话的 stdout 解码正常（UTF-8 与多字节字符）', () async {
    final store = InMemoryHostKeyStore();
    final session = sessionWith(store, onUnknown: (h) async => true);

    await session.connect();

    final out = StringBuffer();
    final sub = session.output.listen(out.write);

    // 期望串在**输入里不连续**：PTY 会把命令行原样回显，若直接写
    // "中文测试OK"，回显就能满足断言，命令根本没执行也照样绿。
    // 实测回显行为：`printf '中%s\n' 文测试OK` 原样回显，其中不含连续期望串。
    session.write("printf '中%s\\n' 文测试OK\n");

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!out.toString().contains('中文测试OK') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(out.toString(), contains('中文测试OK'));

    await sub.cancel();
    await session.close();
  }, skip: skipReason);
}
