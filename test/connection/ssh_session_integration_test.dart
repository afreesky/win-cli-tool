import 'dart:async';

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
    expect(asked!.fingerprint, startsWith('SHA256:'));
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
    final session = sessionWith(store, onUnknown: (h) async => false);

    await expectLater(session.connect(), throwsA(anything));
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

    await expectLater(session.connect(), throwsA(anything));
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

    // 用 printf 输出多字节字符，验证流式解码器跨分片正确
    session.write('printf "中文测试OK\\n"\n');

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
