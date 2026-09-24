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

  Connection? _conn;
  StreamSubscription<List<int>>? _inputSub;
  StreamSubscription<String>? _decodeSub;
  var _closed = false;

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> connect() async {
    final conn =
        await connector.open(profile.host, profile.port, timeout: connectTimeout);
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

  void _onDisconnected([Object? _]) {
    if (_closed) return;
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
    await _dataBytes.close();
    await _output.close();
  }
}
