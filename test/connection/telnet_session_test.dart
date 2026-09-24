import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/telnet_session.dart';
import 'package:win_cli_tool/models/device_profile.dart';

import '../fixtures/fake_device_server.dart';

DeviceProfile _profile(int port, {String name = '测试设备'}) => DeviceProfile(
      id: 'd1',
      name: name,
      protocol: DeviceProtocol.telnet,
      host: '127.0.0.1',
      port: port,
      username: 'admin',
    );

void main() {
  group('TelnetSession', () {
    test('连接后能收到横幅与提示符', () async {
      final device = await FakeDeviceServer.start(prompt: '[CoreSW]');
      addTearDown(device.stop);

      final session = TelnetSession(profile: _profile(device.port));
      addTearDown(session.close);

      final output = <String>[];
      session.output.listen(output.add);

      await session.connect();
      await _waitUntil(() => output.join().contains('[CoreSW]'));

      expect(output.join(), contains('Fake Device'));
    });

    test('write 的内容被设备收到', () async {
      final device = await FakeDeviceServer.start(prompt: '[CoreSW]');
      addTearDown(device.stop);

      final session = TelnetSession(profile: _profile(device.port));
      addTearDown(session.close);
      await session.connect();

      session.write('display version\n');
      await _waitUntil(() => device.receivedCommands.isNotEmpty);

      expect(device.receivedCommands, ['display version']);
    });

    test('会话能正确处理跨分片的中文 UTF-8 字符', () async {
      final device = await FakeDeviceServer.start(
        prompt: '[CoreSW]',
        responseFor: {
          'show': ['设备型号：华为 S5700'],
        },
      );
      addTearDown(device.stop);

      final session = TelnetSession(profile: _profile(device.port));
      addTearDown(session.close);

      final output = <String>[];
      session.output.listen(output.add);

      await session.connect();
      session.write('show\n');
      await _waitUntil(() => output.join().contains('华为 S5700'));

      expect(output.join(), contains('设备型号：华为 S5700'));
    });

    test('对端协商被自动应答，不进入输出流', () async {
      final device = await FakeDeviceServer.start(
        prompt: '[CoreSW]',
        negotiate: true,
      );
      addTearDown(device.stop);

      final session = TelnetSession(profile: _profile(device.port));
      addTearDown(session.close);

      final output = <String>[];
      session.output.listen(output.add);

      await session.connect();
      await _waitUntil(() => output.join().contains('[CoreSW]'));

      // 0xFF 不是合法 UTF-8，若协商字节没被剥离，解码时会变成替换字符 U+FFFD
      expect(output.join(), isNot(contains('�')));
      expect(output.join(), contains('Fake Device'));
    });

    test('服务端关闭连接时 done 完成', () async {
      final device = await FakeDeviceServer.start(prompt: '[CoreSW]');
      final session = TelnetSession(profile: _profile(device.port));
      addTearDown(session.close);
      await session.connect();

      var done = false;
      unawaited(session.done.then((_) => done = true));

      await device.stop();
      await _waitUntil(() => done);

      expect(done, isTrue);
    });

    test('端口无人监听时 connect 抛异常', () async {
      final device = await FakeDeviceServer.start();
      final port = device.port;
      await device.stop();

      final session = TelnetSession(profile: _profile(port));
      await expectLater(session.connect(), throwsA(isA<SocketException>()));
    });
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
