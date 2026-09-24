import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一个最小的假网络设备，用于测试。
///
/// 行为：接受 TCP 连接 →（可选）发一轮 Telnet 协商 → 发横幅与提示符 →
/// 收到命令后回显、输出响应、再发提示符。
class FakeDeviceServer {
  FakeDeviceServer._(
    this._server,
    this._prompt,
    this._banner,
    this._negotiate,
    this._pagerEvery,
    this._responseFor,
    this._hangCommands,
  );

  final ServerSocket _server;
  final String _prompt;
  final String _banner;
  final bool _negotiate;

  /// 每输出这么多行插入一次翻页提示；0 表示不分页。
  final int _pagerEvery;

  /// 命令 → 响应行。
  final Map<String, List<String>> _responseFor;

  /// 这些命令只回显、不回提示符，用于测试超时。
  final Set<String> _hangCommands;

  /// 服务端收到过的命令，按顺序。
  final List<String> receivedCommands = [];

  final _clients = <_FakeClient>[];
  StreamSubscription<Socket>? _serverSub;

  int get port => _server.port;

  static Future<FakeDeviceServer> start({
    String prompt = '[CoreSW]',
    String banner = 'Fake Device v1.0',
    bool negotiate = false,
    int pagerEvery = 0,
    Map<String, List<String>> responseFor = const {},
    Set<String> hangCommands = const {},
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final device = FakeDeviceServer._(
      server,
      prompt,
      banner,
      negotiate,
      pagerEvery,
      responseFor,
      hangCommands,
    );
    device._serverSub = server.listen(device._onClient);
    return device;
  }

  Future<void> stop() async {
    for (final c in List.of(_clients)) {
      await c.dispose();
    }
    _clients.clear();
    await _serverSub?.cancel();
    await _server.close();
  }

  void _onClient(Socket socket) {
    final client = _FakeClient(socket);
    _clients.add(client);

    if (_negotiate) {
      // IAC WILL ECHO, IAC WILL SGA, IAC DO SGA
      socket.add(const [255, 251, 1, 255, 251, 3, 255, 253, 3]);
    }
    socket.add(utf8.encode('$_banner\r\n$_prompt'));

    client.sub = socket.listen(
      (data) => _onData(client, data),
      onDone: () => _clients.remove(client),
      onError: (_) => _clients.remove(client),
    );
  }

  void _onData(_FakeClient client, List<int> raw) {
    final bytes = _stripIac(raw);
    for (final b in bytes) {
      if (client.pagerPending) {
        // 翻页等待中：任何输入都视为"继续"
        client.pagerPending = false;
        client.pagerContinuation?.complete();
        client.pagerContinuation = null;
        continue;
      }
      if (b == 0x0A) {
        // LF：若上一个字节是 CR，忽略
        if (client.lastWasCr) {
          client.lastWasCr = false;
          continue;
        }
        _finishLine(client);
      } else if (b == 0x0D) {
        client.lastWasCr = true;
        _finishLine(client);
      } else {
        client.lastWasCr = false;
        client.lineBuffer.writeCharCode(b);
      }
    }
  }

  void _finishLine(_FakeClient client) {
    final cmd = client.lineBuffer.toString();
    client.lineBuffer.clear();
    if (cmd.isEmpty) {
      client.socket.add(utf8.encode('\r\n$_prompt'));
      return;
    }
    receivedCommands.add(cmd);
    unawaited(_respond(client, cmd));
  }

  Future<void> _respond(_FakeClient client, String cmd) async {
    final out = StringBuffer('$cmd\r\n');

    if (_hangCommands.contains(cmd)) {
      // 只回显，不给提示符
      client.socket.add(utf8.encode(out.toString()));
      return;
    }

    final lines = _responseFor[cmd] ?? const <String>[];

    if (_pagerEvery <= 0 || lines.length <= _pagerEvery) {
      for (final l in lines) {
        out.write('$l\r\n');
      }
      out.write(_prompt);
      client.socket.add(utf8.encode(out.toString()));
      return;
    }

    // 分页：先发第一页，插入翻页提示，等客户端回送后再发剩下的
    for (var i = 0; i < _pagerEvery; i++) {
      out.write('${lines[i]}\r\n');
    }
    out.write('  ---- More ----');
    client.socket.add(utf8.encode(out.toString()));

    client.pagerPending = true;
    client.pagerContinuation = Completer<void>();
    await client.pagerContinuation!.future;

    final rest = StringBuffer();
    for (var i = _pagerEvery; i < lines.length; i++) {
      rest.write('${lines[i]}\r\n');
    }
    rest.write(_prompt);
    client.socket.add(utf8.encode(rest.toString()));
  }

  /// 剥掉客户端发来的 IAC 序列（协商回送），只保留用户数据。
  static List<int> _stripIac(List<int> raw) {
    final out = <int>[];
    var i = 0;
    while (i < raw.length) {
      if (raw[i] != 255) {
        out.add(raw[i]);
        i++;
        continue;
      }
      if (i + 1 >= raw.length) break;
      final verb = raw[i + 1];
      if (verb == 255) {
        // 转义的 0xFF
        out.add(255);
        i += 2;
      } else if (verb == 250) {
        // IAC SB ... IAC SE
        var j = i + 2;
        while (j + 1 < raw.length && !(raw[j] == 255 && raw[j + 1] == 240)) {
          j++;
        }
        i = j + 2;
      } else if (verb >= 251 && verb <= 254) {
        // IAC WILL/WONT/DO/DONT <option>
        i += 3;
      } else {
        // 其余两字节命令
        i += 2;
      }
    }
    return out;
  }
}

class _FakeClient {
  _FakeClient(this.socket);

  final Socket socket;
  final lineBuffer = StringBuffer();
  StreamSubscription<List<int>>? sub;
  var lastWasCr = false;
  var pagerPending = false;
  Completer<void>? pagerContinuation;

  Future<void> dispose() async {
    await sub?.cancel();
    socket.destroy();
  }
}
