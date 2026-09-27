import 'dart:async';

import '../command/prompt_detector.dart';
import 'connection_failure.dart';

/// 提权序列进行到哪一步。
enum _Phase {
  /// 还没开始，或已经结束。
  idle,

  /// 已发出提权命令，等设备的反应（口令提示 / 提权后的提示符）。
  awaitingEnable,

  /// 已发出口令，等提权后的提示符。
  awaitingPassword,
}

/// 登录之后的提权序列：发 `en` → 若设备要口令则提交 → 等特权提示符。
///
/// **它必须在 `SessionReady` 之前跑完。** 这段交互里设备停在口令提示符
/// （`Password:`）而不是命令行提示符上；此时若把用户命令交给
/// `CommandDispatcher`，命令会被当成口令喂进去 —— 轻则提权失败，重则反复
/// 输错口令把账号锁掉。
///
/// **纯逻辑，零 IO**：只经 [write] 往设备写字，输出由调用方经 [onOutput] 喂
/// 进来。所以它可以脱离 socket 单测（`test/connection/enable_sequence_test.dart`）。
///
/// ## 回显闸门
///
/// 建连横幅（`Ruijie>`）与我们发 `en` 之后设备回的提示符，在缓冲区里长得
/// 一样 —— 直接拿"最后一行是不是提示符"当判据，横幅一到就会宣布提权成功，
/// 而那时口令一个字都还没发。所以 `awaitingEnable` 阶段的成功判据是：
/// **缓冲区里既有换行、又能看到 `en` 的回显，且换行之后的那一段以提示符
/// 结尾**。理由是设备的回显必然在第一行：我们写下 `en`，设备先回
/// `en\r\r\n`，之后才是 `Password:` 或 `Ruijie#`。
///
/// **"看到回显"这一条不是多余的。** [_writeAndWait] 的清缓冲挡不住横幅 ——
/// 横幅完全可能在清完之后才落地，而它自带的换行与提示符足以骗过"有换行 +
/// 后面是提示符"这个近似判据。真机实测就是这么翻的车
/// （2026-09-27，锐捷 S6990，10.166.96.41）：横幅的尾巴比 [settleDelay]
/// 晚约 15ms 落地，当场被判成提权成功，口令一个字都没发出去，界面却进了
/// "已连接"。详见 [_promptSeen]。
///
/// `awaitingPassword` 阶段**不**要求回显 —— 口令本来就不回显，那一段的
/// 缓冲区必然是 `\r\r\nRuijie#` 这个形状。
///
/// 代价是**不回显的设备走不通这条路**。它由 [echoGrace] 兜底：到那一刻仍没见过
/// 换行，就退回看整个缓冲区。这个口子开得有限 —— 横幅若被延迟投递，紧接着
/// 设备的回应就到了，最后一行会被它顶掉。
class EnableSequence {
  EnableSequence({
    required this._write,
    required this._promptDetector,
    required this.command,
    this.password,
    this.lineEnding = '\n',
    this.maxAttempts = 2,
    this.attemptTimeout = const Duration(seconds: 6),
    this.settleDelay = const Duration(milliseconds: 300),
    this.echoGrace = const Duration(seconds: 1),
  });

  final void Function(String) _write;

  /// 提权命令，如 `en`。
  final String command;

  /// 提权口令。null 表示设备不问口令（Cisco 形态的 `en` 直达 `#`）。
  final String? password;

  final String lineEnding;

  /// 提权命令最多发几次。"设备没反应"时重发，口令被拒时从头发一遍。
  final int maxAttempts;

  /// **单次**尝试的上限。
  ///
  /// 真机实测（2026-09-26，锐捷 S6990）：`en` 的回显 ~28ms、口令到 `#` ~3s。
  /// 6s 是后者的两倍余量；两次尝试合计 12s ≈ FR-C-13 的默认连接超时 15s ——
  /// 提权不该比建连本身还慢。
  final Duration attemptTimeout;

  /// 建连之后先等这么久再发提权命令。
  ///
  /// 存在的理由是**建连横幅可能被延迟投递**：横幅在设备时间上先于我们写的
  /// `en`，但它在缓冲区里的落点可能晚于 `en` 的回显。等一小会让横幅先落下来，
  /// 紧接着 [_writeAndWait] 会清空缓冲区把它丢掉，后面就再也干扰不到判定了。
  final Duration settleDelay;

  /// 到这一刻仍没见过换行 ⇒ 认为设备不回显，退回看整个缓冲区。
  /// 见类文档的"回显闸门"。
  final Duration echoGrace;

  final PromptDetector _promptDetector;

  /// 设备的口令提示。**实测原文是 `Password:`**（锐捷），以冒号结尾。
  ///
  /// 默认提示符正则 `[>#\]]\s*$` 匹配不上它，但用户可以在设备上自定义
  /// `promptRegex` —— 那个正则**可能**匹配。所以每个状态下都**先判它**。
  static final RegExp passwordPromptPattern =
      RegExp(r'password\s*[:：]?\s*$', caseSensitive: false);

  _Phase _phase = _Phase.idle;
  String _buffer = '';
  int _attemptsLeft = 0;
  bool _graceElapsed = false;
  Timer? _attemptTimer;
  Timer? _settleTimer;
  Timer? _graceTimer;
  Completer<ConnectionFailure?>? _done;

  bool get _finished => _done?.isCompleted ?? false;

  /// 开始提权。
  ///
  /// 返回 **null 表示已进入特权模式**；否则是可直接展示给用户的失败
  /// （`ConnectionFailure.message`，FR-C-06）。
  ///
  /// **一个实例只能跑一次**（重复调用抛 `StateError`）—— 调用方每次连接新建
  /// 一个，这样"试到第几次了"这类状态不会跨会话串味。
  Future<ConnectionFailure?> start() {
    if (_done != null) {
      throw StateError('EnableSequence 只能跑一次：每次连接新建一个');
    }
    final completer = _done = Completer<ConnectionFailure?>();
    _attemptsLeft = maxAttempts;
    _settleTimer = Timer(
      settleDelay,
      () => _writeAndWait(command, _Phase.awaitingEnable),
    );
    return completer.future;
  }

  /// 会话输出，由 `ConnectionManager` 在它的 output 订阅里喂进来。
  ///
  /// **在 [start] 之前喂进来的输出被直接丢弃**（`_done` 还没建，下面第一行
  /// 就返回了），不是攒着。建连横幅（`Ruijie>`）正是这种 —— 丢掉它是对的：
  /// 本类只关心我们写下 `en` **之后**设备说了什么。真正需要防的是横幅在
  /// **`start()` 之后**才落地（订阅先于 `start()` 挂上，见 Task 4），那由
  /// [settleDelay] + [_writeAndWait] 的清缓冲兜住。
  void onOutput(String chunk) {
    if (_done == null || _finished) return;
    _buffer += chunk;
    _check();
  }

  /// 放弃这次提权（会话正在被拆掉时调用）。
  ///
  /// **以 null 完成 future**，看着像"成功"—— 调用方必须靠**身份**判断这次
  /// 提权还算不算数（`identical(_enable, sequence)`），而不是靠这个返回值。
  /// `ConnectionManager` 正是这么写的。
  void dispose() {
    _cancelTimers();
    _phase = _Phase.idle;
    if (!_finished) _done?.complete(null);
  }

  void _writeAndWait(String text, _Phase phase) {
    if (_finished) return;
    // **每次发送前清空缓冲。** 不清的话，建连横幅与上一条口令提示符会留在
    // 里面，被下一次 [_check] 当成"设备已经给了提示符 / 又在要口令"。
    _buffer = '';
    _graceElapsed = false;
    _phase = phase;
    _write('$text$lineEnding');
    _graceTimer?.cancel();
    _graceTimer = Timer(echoGrace, () {
      _graceElapsed = true;
      _check();
    });
    _attemptTimer?.cancel();
    _attemptTimer = Timer(attemptTimeout, _onAttemptTimeout);
  }

  void _check() {
    switch (_phase) {
      case _Phase.idle:
        return;
      case _Phase.awaitingEnable:
        if (_passwordPromptSeen()) {
          final pw = password;
          if (pw == null) {
            _fail(_missingPasswordFailure());
            return;
          }
          _writeAndWait(pw, _Phase.awaitingPassword);
          return;
        }
        if (_promptSeen()) _succeed();
      case _Phase.awaitingPassword:
        if (_passwordPromptSeen()) {
          // 又被要了一次口令 ⇒ 刚才那条不对。
          if (_attemptsLeft > 1) {
            _attemptsLeft--;
            _writeAndWait(command, _Phase.awaitingEnable);
          } else {
            _fail(_rejectedPasswordFailure());
          }
          return;
        }
        if (_promptSeen()) _succeed();
    }
  }

  /// 缓冲区末尾（回显之后的那一段）是否为设备提示符。
  ///
  /// 见类文档的"回显闸门"。
  bool _promptSeen() {
    final at = _buffer.indexOf('\n');
    if (at >= 0) {
      final after = _buffer.substring(at + 1);
      if (after.isEmpty) return false;
      // **`awaitingEnable` 阶段还要求先看到回显。**
      //
      // 只判"有换行 + 后面是提示符"不够：那个换行可能**不是** `en` 的回显，
      // 而是建连横幅自己的。真机实测（2026-09-27，锐捷 S6990）横幅的尾巴
      // （`…ssh.\r\r\nRuijie>`）比 `settleDelay` 晚约 15ms 落地，于是它落在
      // `_writeAndWait` 清缓冲**之后** —— 缓冲里有了换行、换行后正好是提示符
      // `Ruijie>`，当场被判成提权成功。回显是"设备确实收到并处理了这条命令"
      // 的直接证据，而横幅的尾巴里没有它。
      if (_phase == _Phase.awaitingEnable && !_echoSeen) return false;
      return _promptDetector.matches(after);
    }
    // 到这一刻还没见过换行 ⇒ 设备不回显。只在 echoGrace 过了之后才认，
    // 以免把被延迟投递的建连横幅当成提权结果。
    return _graceElapsed && _promptDetector.matches(_buffer);
  }

  /// 设备是否已经把我们写下的 [command] 回显出来了。
  ///
  /// 大小写不敏感：部分设备会把输入转成大写再回显。
  bool get _echoSeen {
    if (command.isEmpty) return true;
    return _buffer.toLowerCase().contains(command.toLowerCase());
  }

  bool _passwordPromptSeen() {
    final line = PromptDetector.lastNonEmptyLine(_buffer);
    return line != null && passwordPromptPattern.hasMatch(line);
  }

  void _onAttemptTimeout() {
    if (_finished) return;
    if (_attemptsLeft > 1) {
      _attemptsLeft--;
      _writeAndWait(command, _Phase.awaitingEnable);
      return;
    }
    _fail(_timeoutFailure());
  }

  void _succeed() {
    _cancelTimers();
    _phase = _Phase.idle;
    if (!_finished) _done!.complete(null);
  }

  void _fail(ConnectionFailure failure) {
    _cancelTimers();
    _phase = _Phase.idle;
    if (!_finished) _done!.complete(failure);
  }

  void _cancelTimers() {
    _attemptTimer?.cancel();
    _settleTimer?.cancel();
    _graceTimer?.cancel();
  }

  static ConnectionFailure _missingPasswordFailure() => const ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '提权口令缺失：设备要求输入提权口令，但该设备没有配置。'
        '请在设备编辑对话框里填写「提权口令」。',
      );

  static ConnectionFailure _rejectedPasswordFailure() => const ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '提权口令被拒：设备连续两次要求重新输入口令。'
        '请检查设备编辑对话框里的「提权口令」。',
      );

  static ConnectionFailure _timeoutFailure() => const ConnectionFailure(
        ConnectionFailureKind.timeout,
        '提权超时：设备没有在超时时间内进入特权模式。'
        '请检查「提权命令」是否是该设备的正确写法。',
      );
}
