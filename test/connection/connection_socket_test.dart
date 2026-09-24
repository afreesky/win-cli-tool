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
  var closed = false;

  @override
  Stream<List<int>> get input => _input.stream;

  void feed(List<int> bytes) {
    if (closed) return;
    _input.add(bytes);
  }

  Future<void> feedDone() => _input.close();

  @override
  void write(List<int> data) => written.addAll(data);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(_input.close());
  }
}

void main() {
  test('对端字节从 socket.stream 出来，且是 Uint8List', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    final got = <int>[];
    socket.stream.listen(got.addAll);

    conn.feed([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);

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

  test('destroy() 关闭底层 Connection', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    socket.destroy();
    await Future<void>.delayed(Duration.zero);

    expect(conn.closed, isTrue);
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

    conn._input.addError(const SocketException('连接被重置'));
    await Future<void>.delayed(Duration.zero);

    expect(caught, isA<SocketException>());
  });
}
