import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connector.dart';
import 'package:win_cli_tool/connection/session.dart';
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

  /// 被要求拨号的目标。**"有没有拨过号"是几条例外的唯一观测点** ——
  /// 只看 `close()` 的副作用分不出"拨了又关掉"与"压根没拨"。
  final opened = <String>[];

  @override
  Future<Connection> open(String host, int port, {Duration? timeout}) {
    opened.add(host);
    return result;
  }
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

  /// 喂入一个来自对端的**错误**（设备侧被重置时传输层报的就是这个形状）。
  /// 已关闭的连接直接忽略。
  void feedError(Object error) {
    if (closed) return;
    _input.addError(error);
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

    test('多字节 UTF-8 字符被切成两片时不会被解码成乱码', () async {
      final (conn, session, output) = await _manualSession();
      addTearDown(session.close);

      // `你` = E4 BD A0，恰好从第二个字节之后切开
      final bytes = utf8.encode('你');
      expect(bytes, [0xE4, 0xBD, 0xA0], reason: '下面切分位置的前提');
      conn.feed(bytes.sublist(0, 2));
      conn.feed(bytes.sublist(2));

      await _drain(output);

      // 逐片 utf8.decode 会把两个残片各解成一个替换字符 U+FFFD；流式解码器
      // 则会把不完整的字节留到下一片一起拼。
      expect(output.join(), '你');
    });

    test('多字节字符被切成三片、两侧都是 ASCII 时不会错位', () async {
      final (conn, session, output) = await _manualSession();
      addTearDown(session.close);

      // 分片边界落在 `你` 内部，且最后一片里同时有字符尾部与普通 ASCII：
      // 只把残缺字节攒起来、不与后续内容重新同步的实现会在这里错位。
      conn.feed([0x6F, 0x6B, 0x3A, 0xE4]); // "ok:" + `你` 的首字节
      conn.feed([0xBD]); // `你` 的中字节
      conn.feed([0xA0, 0x21]); // `你` 的末字节 + "!"

      await _drain(output);

      expect(output.join(), 'ok:你!');
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

    test('对端报错时 done 正常完成，且错误对象留在 lastError 上', () async {
      // §13.12 要求把断开原因保留下来；§13.20 记录了原实现为什么没做到 ——
      // `_onDisconnected([Object? _])` 把形参静态地丢掉了，于是原因在
      // Telnet 这一侧根本没有出口，调用方看到永远是一个 null。
      final (conn, session, _) = await _manualSession();
      addTearDown(session.close);

      final failure = const SocketException('连接被重置', osError: OSError('', 104));
      conn.feedError(failure);

      // 必须**正常完成**，不是以错误完成：断开原因是给用户看的诊断信息，
      // 不是控制流信号，以错误完成会强迫每个 `await done` 的人都处理它，
      // 而无人监听的 `completeError` 还会变成未捕获的异步错误
      // （§13.12 给的就是这两个选项，选了 lastError）。
      await session.done;

      // 静态类型刻意写成 Session：这条断言顺带钉住"lastError 在**接口**上"
      // —— `ConnectionManager` 只认 Session 这个类型，成员若只在实现类上，
      // 它照样够不着（§13.20 的缺陷正是这个形状）。
      final Session viaInterface = session;
      expect(viaInterface.lastError, same(failure));
    });

    test('端口无人监听时 connect 抛异常', () async {
      final device = await FakeDeviceServer.start();
      final port = device.port;
      await device.stop();

      final session = TelnetSession(profile: _profile(port));
      await expectLater(session.connect(), throwsA(isA<SocketException>()));
    });

    test('从未连接的会话上 close() 能完成（不挂起）', () async {
      final session = TelnetSession(profile: _profile(1));

      // 单订阅 StreamController 的 close() Future 要等到有监听者订阅才会兑现；
      // 从未连上的会话没有监听者，await 会永久挂起。加超时是为了让回归以
      // 「失败」而不是「卡死整个测试套件」的方式暴露出来。
      await session.close().timeout(const Duration(seconds: 2));
    });

    test('connect 抛异常后 close() 能完成（不挂起）', () async {
      final device = await FakeDeviceServer.start();
      final port = device.port;
      await device.stop();

      final session = TelnetSession(profile: _profile(port));
      await expectLater(session.connect(), throwsA(isA<SocketException>()));

      // 「连不上 → 清理」是最常见的调用路径。connect 抛异常时 _decodeSub 还没
      // 赋值，_dataBytes 也就从没被监听，close() 同样会永久挂起。
      await session.close().timeout(const Duration(seconds: 2));
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

    test('close() 之后再 connect() 必须直接返回，不能再拨号（§13.21-2）', () async {
      // 原实现把 `if (_closed)` 放在 `connector.open` **之后**：close() 之后
      // 再来一次 connect() 会照常向设备发起 TCP 连接，然后走完那道守卫正常
      // 返回 —— 一个已关闭的会话对外报"连上了"。`SshSession` 早就是对的
      // （入口在最顶上），这条是补上 Telnet 这一侧，与它对称。
      final gate = Completer<Connection>();
      final connector = _GatedConnector(gate.future);
      final session = TelnetSession(profile: _profile(1), connector: connector);

      // **`close()` 不 await。** 这条会话从没连上，`_dataBytes` 没有监听者，
      // 它的 close() 会一直挂着（见 close() 里的注释）。而 `_closed` 在第一个
      // await 之前就已置真，所以下面那次 connect 看到的是"已关闭"。
      unawaited(session.close());
      await Future<void>.delayed(Duration.zero);

      await session.connect().timeout(const Duration(seconds: 2));

      expect(connector.opened, isEmpty, reason: '已关闭的会话绝不能再向设备发起连接');
    });
  });
}

/// 用一条可手动喂字节的假连接建一个会话，并收集它解码出来的字符串。
///
/// 与依赖 OS/TCP 何时切分的用例不同：这里每一片的边界完全由用例决定，
/// 因此可以确定性地把多字节字符切在分片中间。
Future<(_FakeConnection, TelnetSession, List<String>)> _manualSession() async {
  final conn = _FakeConnection();
  final session = TelnetSession(
    profile: _profile(1),
    connector: _GatedConnector(Future.value(conn)),
  );
  final output = <String>[];
  // 必须先订阅再喂字节：_output 是广播流，早到的片段没有回放。
  session.output.listen(output.add);
  await session.connect();
  return (conn, session, output);
}

/// 等「连接 → 解码 → 输出」这条链跑干净：输出连续两次采样间不再变化。
Future<void> _drain(List<String> output) async {
  var previous = output.length;
  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (output.length == previous) return;
    previous = output.length;
  }
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
