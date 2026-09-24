import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'connector.dart';

/// 把本项目的 [Connection] 适配成 dartssh2 需要的 [SSHSocket]。
///
/// 存在的理由：`SSHClient` 只接受 `SSHSocket`，而本项目的传输抽象是
/// [Connection]。有了这层适配，SSH 就能建在**任意** [Connection] 之上 ——
/// 直连可以，跳板机隧道也可以（计划 3 正是靠它把第 N+1 跳建在第 N 跳上，
/// 且不必改动 SshSession）。
class ConnectionSocket implements SSHSocket {
  ConnectionSocket(this._conn) {
    // SSHTransport 会**同时**监听 stream 与 done，而 Connection.input 是
    // 单订阅流：桥接必须只做一次。若在这里按需 listen 两次，第二次会抛
    // "Stream has already been listened to"。
    _sub = _conn.input.listen(
      (data) =>
          _stream.add(data is Uint8List ? data : Uint8List.fromList(data)),
      onError: (Object e, StackTrace st) {
        _stream.addError(e, st);
        if (!_done.isCompleted) _done.completeError(e, st);
      },
      onDone: () {
        unawaited(_stream.close());
        if (!_done.isCompleted) _done.complete();
      },
    );
    _sinkSub = _sink.stream.listen(
      _conn.write,
      onError: (Object _) {},
      onDone: () => unawaited(_conn.close()),
    );
  }

  final Connection _conn;
  final _stream = StreamController<Uint8List>();
  final _sink = StreamController<List<int>>();
  final _done = Completer<void>();
  late final StreamSubscription<List<int>> _sub;
  late final StreamSubscription<void> _sinkSub;

  @override
  Stream<Uint8List> get stream => _stream.stream;

  @override
  StreamSink<List<int>> get sink => _sink.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() => _conn.close();

  @override
  void destroy() => unawaited(_conn.close());

  @override
  Future<void> flush() => _conn.flush();

  /// 释放两个订阅。**不 await 两个 controller 的 close()** ——
  /// 单订阅 controller 的 close() Future 要等到有监听者取走 done 才完成，
  /// 无人监听时永久挂起（spec §13.11）。
  void dispose() {
    unawaited(_sub.cancel());
    unawaited(_sinkSub.cancel());
    unawaited(_sink.close());
    unawaited(_stream.close());
  }
}
