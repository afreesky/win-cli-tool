/// 一次 [TelnetProtocol.feed] 的解析结果。
class TelnetParseResult {
  const TelnetParseResult({required this.data, required this.response});

  /// 剥掉协商序列后的用户数据。
  final List<int> data;

  /// 需要回送给对端的协商字节。调用方应立即写出。
  final List<int> response;
}

/// Telnet IAC 协商的纯状态机。
///
/// 只处理与网络设备 CLI 相关的两个选项：ECHO（回显）与 SGA（抑制 GA，
/// 即逐字符模式）。其余选项一律拒绝，因为我们不需要它们，而拒绝是安全的
/// —— 设备会退回默认行为。
///
/// 刻意不做 TTYPE / NAWS 子协商：我们从不主动 WILL 这两个选项，因此设备
/// 不会向我们发起 `SB TTYPE SEND`。收到 SB 一律吞掉。
class TelnetProtocol {
  static const int iac = 255; // Interpret As Command
  static const int se = 240; // Subnegotiation End
  static const int sb = 250; // Subnegotiation Begin
  static const int will = 251;
  static const int wont = 252;
  static const int doVerb = 253;
  static const int dont = 254;

  static const int optEcho = 1;
  static const int optSuppressGoAhead = 3;

  _State _state = _State.data;
  int _pendingVerb = 0;
  final List<int> _data = [];
  final List<int> _response = [];

  /// 吃进一段字节，返回用户数据与需要回送的协商字节。
  TelnetParseResult feed(List<int> chunk) {
    _data.clear();
    _response.clear();
    for (final b in chunk) {
      _consume(b);
    }
    return TelnetParseResult(
      data: List<int>.of(_data),
      response: List<int>.of(_response),
    );
  }

  void _consume(int b) {
    switch (_state) {
      case _State.data:
        if (b == iac) {
          _state = _State.iac;
        } else {
          _data.add(b);
        }
      case _State.iac:
        if (b == iac) {
          // 转义的 0xFF：数据里真的有一个 0xFF
          _data.add(iac);
          _state = _State.data;
        } else if (b == will || b == wont || b == doVerb || b == dont) {
          _pendingVerb = b;
          _state = _State.negotiation;
        } else if (b == sb) {
          _state = _State.subnegotiation;
        } else {
          // 其余两字节命令（NOP / GA / DM 等），忽略
          _state = _State.data;
        }
      case _State.negotiation:
        _negotiate(b);
        _state = _State.data;
      case _State.subnegotiation:
        if (b == iac) {
          _state = _State.subnegotiationIac;
        }
      case _State.subnegotiationIac:
        if (b == se) {
          _state = _State.data;
        } else if (b == iac) {
          // 子协商里转义的 0xFF，继续留在子协商中
          _state = _State.subnegotiation;
        } else {
          _state = _State.subnegotiation;
        }
    }
  }

  void _negotiate(int option) {
    switch (_pendingVerb) {
      case doVerb:
        // 对端要我们启用某选项
        if (option == optSuppressGoAhead) {
          _respond(will, option);
        } else {
          _respond(wont, option);
        }
      case will:
        // 对端声明自己要启用某选项
        if (option == optEcho || option == optSuppressGoAhead) {
          _respond(doVerb, option);
        } else {
          _respond(dont, option);
        }
      case wont:
      case dont:
        // 对端拒绝或要求关闭，不需要回应
        break;
    }
  }

  void _respond(int verb, int option) {
    _response.addAll([iac, verb, option]);
  }
}

enum _State { data, iac, negotiation, subnegotiation, subnegotiationIac }
