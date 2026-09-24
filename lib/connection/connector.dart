import 'dart:async';
import 'dart:io';

/// 一条已建立的双向字节流。
///
/// 刻意保持极简：只有"读、写、关"三件事。SSH 与 Telnet 都建在它之上，
/// 因此代理/跳板机的实现只需写一遍。
abstract class Connection {
  /// 对端发来的原始字节。
  Stream<List<int>> get input;

  /// 写入字节。不保证立即发出，必要时调用 [flush]。
  void write(List<int> data);

  /// 把缓冲区中的数据推出去。
  Future<void> flush();

  /// 关闭连接。可重复调用。
  Future<void> close();
}

/// 建立到 `host:port` 的连接。
abstract class Connector {
  Future<Connection> open(String host, int port, {Duration? timeout});
}

/// 直连实现。
class DirectConnector implements Connector {
  const DirectConnector();

  @override
  Future<Connection> open(String host, int port, {Duration? timeout}) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    // 交互式会话禁用 Nagle：命令都是短包，攒包会引入几十毫秒的额外延迟。
    socket.setOption(SocketOption.tcpNoDelay, true);
    return _SocketConnection(socket);
  }
}

class _SocketConnection implements Connection {
  _SocketConnection(this._socket);

  final Socket _socket;
  var _closed = false;

  // 显式 cast 不能省：Socket 实际是 Stream<Uint8List>，而本接口承诺的是
  // Stream<List<int>>。两者在静态类型上兼容（Uint8List 是 List<int> 的子类型），
  // 但 Stream.transform 会按**运行时**类型去校验 transformer —— 不 cast 的话
  // 消费方写 .transform(utf8.decoder) 能通过编译却在运行时抛
  // "type 'Utf8Decoder' is not a subtype of type 'StreamTransformer<Uint8List, String>'"。
  // cast 之后声明类型与运行时类型一致，抽象才是可信的。
  @override
  Stream<List<int>> get input => _socket.cast<List<int>>();

  @override
  void write(List<int> data) {
    if (_closed) return;
    _socket.add(data);
  }

  @override
  Future<void> flush() async {
    if (_closed) return;
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _socket.close();
    _socket.destroy();
  }
}
