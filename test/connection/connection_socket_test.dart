import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_socket.dart';
import 'package:win_cli_tool/connection/connector.dart';

/// 可手动喂入字节、并记录写出的字节的假连接。
class _FakeConnection implements Connection {
  final _input = StreamController<List<int>>();
  final written = <int>[];

  /// `close()` 之后仍被写入的字节。真实的 `_SocketConnection` 会在这一步
  /// **静默丢弃**，所以必须记下来 —— 否则"写出去后立刻 close()"的丢包
  /// 是断言不到的（写丢了一个字节都不报错，正是它危险的地方）。
  final writeAfterClose = <int>[];
  var closed = false;
  var flushCalls = 0;

  @override
  Stream<List<int>> get input => _input.stream;

  void feed(List<int> bytes) {
    if (closed) return;
    _input.add(bytes);
  }

  void feedError(Object error) {
    if (closed) return;
    _input.addError(error);
  }

  Future<void> feedDone() => _input.close();

  @override
  void write(List<int> data) {
    if (closed) {
      writeAfterClose.addAll(data);
      return;
    }
    written.addAll(data);
  }

  @override
  Future<void> flush() async {
    flushCalls++;
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(_input.close());
  }
}

void main() {
  test('对端字节按原样从 socket.stream 出来', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    final got = <int>[];
    socket.stream.listen(got.addAll);

    conn.feed([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);

    // 只断言内容：got 是 List<int>，元素运行时类型在这里被丢掉了。
    // 类型由下一条用例专门守着。
    expect(got, [1, 2, 3]);
  });

  test('stream 的运行时元素类型必须是 Uint8List', () async {
    // SSHTransport 内部按 Uint8List 消费，若透传出 List<int> 会在运行时
    // 抛类型错误。这正是计划 1 记录过的协变陷阱的同一形态。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    Object? seen;
    socket.stream.listen((d) => seen = d);

    conn.feed([9]);
    await Future<void>.delayed(Duration.zero);

    // 必须断言"值本身是 Uint8List"，不能写 expect(d.runtimeType, Uint8List)：
    // Uint8List 的 runtimeType 与类型字面量并不 ==（实测 false），失败信息
    // 还是 "Expected: Uint8List, Actual: Uint8List"，极具误导性。
    expect(seen, isA<Uint8List>());
  });

  test('写进 sink 的字节落到 Connection.write', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    socket.sink.add([65, 66]);
    await Future<void>.delayed(Duration.zero);

    expect(conn.written, [65, 66]);
  });

  test('写出去后立刻 close()，字节仍须先落到 Connection（丢了就是优雅关闭被掐断）', () async {
    // 这条守的是 _sink 的同步性。若用默认的异步 controller，sink.add 要等
    // 一个 microtask 才调用 write，而 close() 的关闭标记是**同步**置上的 ——
    // 于是这一批字节被底层连接静默丢弃。
    //
    // 实测（真 sshd + 真 SSHClient，见 spec §13.18）：client.close() 在同一个
    // 同步块里先往 sink 写 CHANNEL_EOF / CHANNEL_CLOSE 再关闭传输层，异步
    // controller 下这两个报文全部丢失 —— 设备侧看到的是连接被粗暴掐断，
    // 而不是优雅断开（网络设备上这会把 vty 占住到超时）。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    socket.sink.add([65]);
    unawaited(socket.close()); // 与上一行同一个同步块，中间不让出 microtask

    await Future<void>.delayed(Duration.zero);

    expect(
      conn.writeAfterClose,
      isEmpty,
      reason: 'close 之后才落到的写入会被真实连接静默丢弃',
    );
    expect(conn.written, [65]);
  });

  test('destroy() 关闭底层 Connection', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    socket.destroy();
    await Future<void>.delayed(Duration.zero);

    expect(conn.closed, isTrue);
  });

  test('flush() 透传给底层 Connection', () async {
    // Connection.write 不保证立即发出，flush() 才是那个保证。适配器自己
    // 多了一层 sink，若不透传，"flush 过了"就成了一句空话。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    await socket.flush();

    expect(conn.flushCalls, 1);
  });

  test('对端结束传输时 socket.done 完成', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    var done = false;
    unawaited(socket.done.then((_) => done = true));

    await conn.feedDone();
    await Future<void>.delayed(Duration.zero);

    expect(done, isTrue);
  });

  test('对端报错时 socket.done 以错误完成（而非静默完成）', () async {
    // 静默完成会让上层把"连接被重置"看成一次正常结束，
    // FR-C-06 的可读原因就没了来源。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    Object? caught;
    unawaited(socket.done.catchError((Object e) {
      caught = e;
    }));

    conn.feedError(const SocketException('连接被重置'));
    await Future<void>.delayed(Duration.zero);

    expect(caught, isA<SocketException>());
  });

  test('dispose() 释放订阅：之后不再交付对端数据', () async {
    // dispose() 存在的全部意义就是摘掉订阅。摘不掉 = 旧会话的输出会继续
    // 流进已经换代的界面（计划 2 开头那个"输出区永久静止 / 按钮是绿的"
    // 就是这一族的故障）。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    final got = <int>[];
    socket.stream.listen(got.addAll);

    socket.dispose();
    conn.feed([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);

    expect(got, isEmpty);
  });

  test('dispose() 不关闭底层 Connection（关闭是 close()/destroy() 的职责）', () async {
    // Connection 是**借来的**，生命周期归调用方。Task 4 的 SshSession.close()
    // 正是先 client.close() 再 dispose()。若 dispose() 顺手关了连接，那个
    // 顺序就变成"先关两次"，而顺序反过来的调用方会拿到一个已死的连接。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    socket.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(conn.closed, isFalse, reason: 'dispose() 只释放订阅，连接由调用方关闭');
  });
}
