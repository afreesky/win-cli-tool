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
///
/// 契约上有两处需要调用方知道：`dispose()` **不**关闭底层 [Connection]；
/// `done` 的完成依赖对端真的结束 [Connection.input]。
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
      // Connection.write 是同步的 void，身上没有错误通道；写出失败的唯一
      // 上报口是 done。所以这条 onError 目前不可达 —— 留着只为满足
      // StreamSink 的契约形态，别指望它兜住写入失败。
      onError: (Object _) {},
      // dartssh2 从不调用 sink.close()（只 sink.add），所以这条在计划 2 里
      // 也不可达。dispose() 里 _sinkSub.cancel() 排在 _sink.close() 之前，
      // 正是为了不走到这里 —— 否则 dispose() 会顺手把连接关掉。
      onDone: () => unawaited(_conn.close()),
    );
  }

  final Connection _conn;
  final _stream = StreamController<Uint8List>();

  /// `sync: true` **不能省**。默认的异步 controller 会把 `sink.add` 推迟一个
  /// microtask 才调用 [_conn.write]，而 `Connection.close()` 的关闭标记是
  /// **同步**置上的：同一个同步块里"写出去 + close()"的字节会被底层连接
  /// 静默丢弃，一个错误都不报。
  ///
  /// 实测（真 sshd + 真 SSHClient，见 spec §13.18）：`client.close()` 先在
  /// 同一同步块里往 sink 写 `CHANNEL_EOF` / `CHANNEL_CLOSE`，再关传输层 ——
  /// 异步 controller 下这两个报文全部丢掉，设备侧看到的是连接被粗暴掐断
  /// 而非优雅断开。裸 socket 不会这样，所以这层适配器把一个原本正确的
  /// 行为改坏了。
  ///
  /// 代价：[_conn.write] 若同步抛错，现在会直接从 `sink.add` 里抛出来，
  /// 而不是变成异步未捕获错误。这是刻意的 —— 快速失败好过静默。前提是
  /// 监听回调不会回头再往 `_sink` 里写（那会让 sync controller 抛
  /// StateError）；[_conn.write] 不碰 `_sink`，前提成立。
  final _sink = StreamController<List<int>>(sync: true);
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
  /// 无人监听时永久挂起（spec §13.11）。本方法返回 void 也正是这个缘故：
  /// void 让"await 一个可能永不完成的 future"根本写不出来。
  ///
  /// **不关闭 [Connection]** —— 连接是借来的，由调用方用 `close()` /
  /// `destroy()` 释放。计划 2 的 `SshSession.close()` 就是先 `client.close()`
  /// 再 `dispose()`。
  void dispose() {
    unawaited(_sub.cancel());
    unawaited(_sinkSub.cancel());
    unawaited(_sink.close());
    unawaited(_stream.close());
  }
}
