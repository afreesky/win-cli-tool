import 'dart:async';
import 'dart:convert';

import '../models/device_profile.dart';
import 'connector.dart';
import 'session.dart';
import 'telnet_protocol.dart';

/// 基于 Telnet 的会话实现。
class TelnetSession implements Session {
  TelnetSession({
    required this.profile,
    this.connector = const DirectConnector(),
    this.connectTimeout = const Duration(seconds: 15),
  });

  final DeviceProfile profile;

  /// 建连方式。默认直连；计划 2 会注入带跳板机的实现。
  final Connector connector;

  final Duration connectTimeout;

  final _protocol = TelnetProtocol();
  final _output = StreamController<String>.broadcast();
  final _dataBytes = StreamController<List<int>>();
  final _done = Completer<void>();

  /// 意外断开的原始错误（FR-C-06 / spec §13.12）。null 表示正常断开。
  Object? _lastError;

  Connection? _conn;
  StreamSubscription<List<int>>? _inputSub;
  StreamSubscription<String>? _decodeSub;
  var _closed = false;

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Object? get lastError => _lastError;

  @override
  Future<void> connect() async {
    // **入口守卫（spec §13.21-2）。** 已经关闭的会话绝不能再拨号：少了它，
    // close() 之后再来一次 connect() 会照常向设备发起 TCP 连接，然后走下面
    // 那道守卫正常返回 —— 一个已关闭的会话对外报"连上了"。与 `SshSession`
    // 的入口守卫对称。
    if (_closed) return;

    final conn =
        await connector.open(profile.host, profile.port, timeout: connectTimeout);
    // **这一道仍然要留。** 上面那道管的是"调 connect 时已经关了"，这一道管的是
    // "**建连期间**被 close()"（用户切设备、关窗口）—— 两者是不同的时刻。
    // 此时必须把刚拿到的连接关掉并直接返回，否则 socket 泄漏，且 _dataBytes
    // 已关闭，后续 _onBytes 里的 add 会抛 "Cannot add event after closing"。
    if (_closed) {
      await conn.close();
      return;
    }
    _conn = conn;

    // 用流式解码器而非逐片 utf8.decode：多字节字符可能跨分片边界，
    // 逐片解码会把它切成乱码。
    _decodeSub = _dataBytes.stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_output.add);

    _inputSub = conn.input.listen(
      _onBytes,
      onError: _onDisconnected,
      onDone: _onDisconnected,
      cancelOnError: true,
    );
  }

  void _onBytes(List<int> chunk) {
    final result = _protocol.feed(chunk);
    if (result.response.isNotEmpty) {
      _conn?.write(result.response);
    }
    if (result.data.isNotEmpty) {
      _dataBytes.add(result.data);
    }
  }

  /// 对端报错或 EOF —— `conn.input` 的 `onError` / `onDone` 都落在这里，
  /// 两者都意味着**断开**。
  ///
  /// 形参**不能丢**：这里曾经写成 `[Object? _]`，错误被静态地扔掉了，于是
  /// §13.12 要求保留的断开原因在 Telnet 一侧根本没有出口（spec §13.20）。
  /// [done] 刻意不以错误完成（原因写在 [Session.done] 上），因此 [lastError]
  /// 是它唯一的出口。
  ///
  /// 存必须在 `complete()` **之前**：完成 [done] 会唤醒 `await done` 的调用方，
  /// 它紧接着就读 [lastError]。
  void _onDisconnected([Object? error]) {
    if (_closed) return;
    if (error != null) _lastError = error;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void write(String text) {
    if (_closed) return;
    _conn?.write(utf8.encode(text));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _inputSub?.cancel();
    await _decodeSub?.cancel();
    await _conn?.close();
    // 这里不能 await：单订阅 StreamController 的 close() Future 要等到有
    // 监听者订阅才会完成，而「从未连上」或「connect 抛异常」的会话永远没有
    // 监听者，await 会永久挂起（切设备、连不上后清理、关窗口时卡死）。
    // 这两个只是内存对象，真正需要释放的资源是上面的 socket。
    unawaited(_dataBytes.close());
    unawaited(_output.close());
  }
}
