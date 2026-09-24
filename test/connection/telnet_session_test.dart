import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connector.dart';
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

/// 建连时机可控的 Connector：`open` 返回调用方给的 Future。
class _GatedConnector implements Connector {
  _GatedConnector(this.result);

  final Future<Connection> result;

  @override
  Future<Connection> open(String host, int port, {Duration? timeout}) => result;
}

/// 一条记名式的假连接：能人为喂入字节，并记录是否被关闭。
class _FakeConnection implements Connection {
  final _input = StreamController<List<int>>();
  var closed = false;

  @override
  Stream<List<int>> get input => _input.stream;

  /// 喂入一段来自对端的字节。已关闭的连接直接忽略。
  void feed(List<int> bytes) {
    if (closed) return;
    _input.add(bytes);
  }

  @override
  void write(List<int> data) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    // 不 await：单订阅流在无人监听时，close() 的 Future 要等到有人订阅
    // 才会兑现（见下面那个 close-during-connect 的用例）。
    unawaited(_input.close());
  }
}

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

    test('connect 等待期间被 close：连接被关闭且没有异常逃逸到 zone', () async {
      final conn = _FakeConnection();
      final gate = Completer<Connection>();
      final session = TelnetSession(
        profile: _profile(1),
        connector: _GatedConnector(gate.future),
      );

      Object? zoneError;
      StackTrace? zoneStack;

      await runZonedGuarded(() async {
        // 建连还挂在 open 上时用户切了设备/关了窗口
        final connecting = session.connect();
        // 只发起、不等待 close()：_dataBytes 是单订阅流且此时还无人监听，
        // 它的 close() 直到有人订阅才会完成。真正要验的是 close() 的效果，
        // 不是它的 Future 何时兑现。
        unawaited(session.close());
        // 先把 close() 的拆除动作放干净（此时 _conn 还是 null，它什么也拆不掉，
        // 随后挂在 _dataBytes.close() 上），再让 connect() 醒来。
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        gate.complete(conn);
        await connecting;

        // 让刚建立的连接吐点字节：修复前 _dataBytes 已关闭，
        // 这里会从 _onBytes 抛出 "Cannot add event after closing"
        conn.feed(utf8.encode('banner'));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }, (e, s) {
        zoneError = e;
        zoneStack = s;
      });

      expect(
        zoneError,
        isNull,
        reason: '不该有异常逃逸到 zone，实际拿到：$zoneError\n$zoneStack',
      );
      expect(conn.closed, isTrue, reason: '建连期间被 close，刚建好的连接必须关掉');
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
