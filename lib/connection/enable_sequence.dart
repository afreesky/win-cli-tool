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
/// ## 两道闸门
///
/// 建连横幅（`Ruijie>`）与我们发 `en` 之后设备回的提示符，在缓冲区里长得
/// 一样 —— 直接拿"最后一行是不是提示符"当判据，横幅一到就会宣布提权成功，
/// 而那时口令一个字都还没发。挡这件事的是两道闸门：
///
/// **一、回显闸门（`awaitingEnable` 阶段）。** 成功判据是：**缓冲区里既有
/// 换行、又能看到 `en` 的回显，且换行之后的那一段以提示符结尾**。理由是设备的
/// 回显必然在第一行：我们写下 `en`，设备先回 `en\r\r\n`，之后才是 `Password:`
/// 或 `Ruijie#`。
///
/// **"看到回显"这一条不是多余的。** [_writeAndWait] 的清缓冲挡不住横幅 ——
/// 横幅完全可能在清完之后才落地，而它自带的换行与提示符足以骗过"有换行 +
/// 后面是提示符"这个近似判据。真机实测就是这么翻的车
/// （2026-09-27，锐捷 S6990，10.166.96.41）：横幅的尾巴比 [settleDelay]
/// 晚约 15ms 落地，当场被判成提权成功，口令一个字都没发出去，界面却进了
/// "已连接"。
///
/// **二、登录提示符基准（两个阶段都管）。** 只有"**换了**提示符"才算提权
/// 成功：提权前的那个提示符（`Ruijie>`）由 [_noteLoginPrompt] 记下，之后若又
/// 看到**一模一样**的提示符，那不是成功 —— 设备是把我们退回了用户模式。
///
/// 真机实测：口令错时锐捷**不会**再要一次口令，而是打印 `% Access denied`
/// 后直接回到 `Ruijie>`。只判 `[>#\]]` 会把这判成提权成功，界面进"已连接"，
/// 而设备还在用户模式 —— 用户随后每一条命令都吃
/// `% User doesn't have sufficient privilege`。在这台设备上 `>` 与 `#` 的
/// 区别**只有**这个基准能给：spec §5.2 只有一个 `promptRegex`，没有
/// "特权提示符"这个概念。
///
/// **基准本身要记牢，第二道闸门才有意义。** 记基准时只取 [command] 回显
/// **之前**的那一段（见 [_noteLoginPrompt]）—— 回显之后是设备对 `en` 的反应，
/// 那里的提示符是"提权后"的。真机实测（2026-09-27，同上一台）第二次连接时
/// 横幅尾巴与回显**被合并进一个 chunk**：若按"见过回显就整个放弃"来记，基准
/// 永远记不下来，第二道闸门**静默失效** —— 同一份代码第一次判对"超时"、
/// 紧接着的重连却把 `% User:admin has been blocked!` 之后的 `Ruijie>` 判成
/// "重连成功"，亮绿灯而设备仍在用户模式。按位置切分两种投递方式都能记下。
///
/// `awaitingPassword` 阶段**不**要求回显（口令本来就不回显，那一段的缓冲区
/// 必然是 `\r\r\nRuijie#` 这个形状），但**同样要求**提示符与基准不同。
///
/// 代价是**不回显的设备走不通回显闸门**。它由 [echoGrace] 兜底：到那一刻仍
/// 没见过换行，就退回看整个缓冲区。这个口子开得有限 —— 横幅若被延迟投递，
/// 紧接着设备的回应就到了，最后一行会被它顶掉。
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

  /// 提权**之前**看到的那个提示符（`Ruijie>`），提权成功与否的基准。
  /// 见类文档的"登录提示符基准"。拿不到时为 null —— 那时只能退回只判
  /// `[>#\]]`，也就是这道闸门失效。
  String? _loginPrompt;

  /// 已经往设备发过至少一次口令。用来区分"退回登录提示符"这个信号
  /// 有没有意义 —— 没发过口令就谈不上"口令被拒"。
  bool _passwordSent = false;

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
  /// **在 [start] 之前喂进来的输出不判成功也不判失败，但仍会进缓冲区** ——
  /// 建连横幅（`Ruijie>`）常在这条缝里落地，而它是 [_noteLoginPrompt] 要记的
  /// 那个"登录提示符"基准。判成功/失败要等 [start]，那之前 `_done` 还是 null。
  ///
  /// 横幅在 **`start()` 之后**才落地是另一回事（订阅先于 `start()` 挂上，
  /// 见 Task 4）：那时它既不进"已清空"的缓冲，也可能自带给提示符 —— 由
  /// 回显闸门与登录提示符基准两道闸门一起挡（见类文档）。
  void onOutput(String chunk) {
    if (_finished) return;
    _buffer += chunk;
    _noteLoginPrompt();
    if (_done == null) return;
    _check();
  }

  /// 记下提权**之前**的提示符，作为"到底提权成功没有"的基准。
  ///
  /// **只在"还没发过口令"的阶段记**：`idle`（横幅早到）与 `awaitingEnable`
  /// （横幅晚到）。`awaitingPassword` 必须排除 —— 那时缓冲区里是**口令的回显**
  /// 或设备的拒绝信息，而回显可能自己就以 `#` / `>` 结尾（口令 `abc#`），
  /// 一旦被记成基准，"提权后提示符必须与基准不同"这条就永远不成立，提权成功
  /// 也会被判成失败（用例「口令以 # 结尾也不会被回显骗成成功」正是踩这个）。
  ///
  /// **只取 [command] 回显之前的那一段**（[_echoAt] 之前）。回显之后是设备对
  /// `en` 的反应（`Password:`、`Ruijie#`、或拒绝信息），那里的提示符是"提权后"
  /// 的，不能当基准 —— 而无回显时（`idle` 阶段，我们还没写过东西）整个缓冲区
  /// 都是提权前的内容，整段都算。
  ///
  /// **按位置切分，而不是"见过回显就整个放弃"。** 后者曾经是这么写的，真机上
  /// 翻过车（2026-09-27，锐捷 S6990）：横幅的尾巴与 `en` 的回显**被合并进同一个
  /// chunk** 投递，于是第一次 [_noteLoginPrompt] 进来时 `_echoSeen` 已经是 true，
  /// 缓冲区被整个放弃 —— 基准永远记不下来，第二道闸门就此失效。同一份代码在
  /// 第一次连接（横幅与回显分两个 chunk 到）判对了"超时"，在紧接着的重连
  /// （合并成一个 chunk）却把设备回的 `% User:admin has been blocked!` + `Ruijie>`
  /// 判成了"重连成功"，界面亮绿灯而设备还在用户模式。
  ///
  /// 一成不变地取"最后一个非空行"也不行：横幅自己的消息行（`Last login: …`）
  /// 会先落地，它不是提示符。所以还要求这一行**匹配提示符正则**。
  void _noteLoginPrompt() {
    if (_loginPrompt != null || _phase == _Phase.awaitingPassword) return;
    // `idle` 阶段还没写过任何东西，缓冲区里的一字一句都是提权前的；其余阶段
    // 按回显位置切开。
    final at = _phase == _Phase.idle ? -1 : _echoAt;
    final head = at >= 0 ? _buffer.substring(0, at) : _buffer;
    final line = PromptDetector.lastNonEmptyLine(head);
    if (line != null && _promptDetector.matches(line)) _loginPrompt = line;
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
    if (phase == _Phase.awaitingPassword) _passwordSent = true;
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
        // `_succeed()` 之后**必须 return**：这里的 switch 不 break（本仓库的
        // 风格，见 telnet_protocol.dart），落进下面那个 case 会让两道闸门在
        // 已经成功之后再跑一遍 —— 而那时 `_returnedToLoginPrompt` 可能为真，
        // 于是刚宣布的成功又被 `_onPasswordRejected()` 推翻。
        if (_promptSeen()) {
          _succeed();
          return;
        }
        if (_returnedToLoginPrompt) _onPasswordRejected();
      case _Phase.awaitingPassword:
        if (_passwordPromptSeen()) {
          _onPasswordRejected();
          return;
        }
        if (_promptSeen()) {
          _succeed();
          return;
        }
        if (_returnedToLoginPrompt) _onPasswordRejected();
    }
  }

  /// 口令没被接受：还有次数就从头发一遍，没有了就报认证失败。
  ///
  /// 两个来源共用它 —— 设备**又要一次口令**（`Password:` 再来一遍），
  /// 或者**把我们退回登录提示符**（锐捷的真实行为，见类文档第二道闸门）。
  void _onPasswordRejected() {
    if (_attemptsLeft > 1) {
      _attemptsLeft--;
      _writeAndWait(command, _Phase.awaitingEnable);
    } else {
      _fail(_rejectedPasswordFailure());
    }
  }

  /// 缓冲区末尾（回显之后的那一段）是否为**提权后**的设备提示符。
  ///
  /// 见类文档的"两道闸门"。
  bool _promptSeen() {
    final at = _buffer.indexOf('\n');
    if (at >= 0) {
      final after = _buffer.substring(at + 1);
      if (after.isEmpty) return false;
      // 第一道闸门：`awaitingEnable` 阶段要求先看到回显。
      //
      // 只判"有换行 + 后面是提示符"不够：那个换行可能**不是** `en` 的回显，
      // 而是建连横幅自己的。真机实测（2026-09-27，锐捷 S6990）横幅的尾巴
      // （`…ssh.\r\r\nRuijie>`）比 `settleDelay` 晚约 15ms 落地，于是它落在
      // `_writeAndWait` 清缓冲**之后** —— 缓冲里有了换行、换行后正好是提示符
      // `Ruijie>`，当场被判成提权成功。回显是"设备确实收到并处理了这条命令"
      // 的直接证据，而横幅的尾巴里没有它。
      if (_phase == _Phase.awaitingEnable && !_echoSeen) return false;
      // 第二道闸门：必须**换了**提示符。
      return _promptDetector.matches(after) && !_isLoginPromptLine(after);
    }
    // 到这一刻还没见过换行 ⇒ 设备不回显。只在 echoGrace 过了之后才认，
    // 以免把被延迟投递的建连横幅当成提权结果。
    return _graceElapsed &&
        _promptDetector.matches(_buffer) &&
        !_isLoginPromptLine(_buffer);
  }

  /// 这一段文本的最后一行是否就是提权前那个提示符。
  ///
  /// [_loginPrompt] 拿不到时恒为 false —— 这道闸门失效，退回只判 `[>#\]]`。
  /// 那是本类已知的缺口（横幅若早于订阅到达就无从取基准）。
  bool _isLoginPromptLine(String text) {
    final login = _loginPrompt;
    if (login == null) return false;
    return PromptDetector.lastNonEmptyLine(text) == login;
  }

  /// 设备把我们退回了提权前的提示符 ⇒ 口令没被接受。
  ///
  /// 没发过口令就谈不上"被拒"（比如 `en` 之后设备直接给了登录提示符，
  /// 那更像是这台设备不需要提权），所以要求 [_passwordSent]。
  bool get _returnedToLoginPrompt =>
      _passwordSent && _isLoginPromptLine(_buffer);

  /// 设备回显 [command] 的**位置**，找不到是 -1。
  ///
  /// 大小写不敏感：部分设备会把输入转成大写再回显。
  ///
  /// 用大小写不敏感的正则、而不是 `toLowerCase()` 之后 `indexOf`：下标要能
  /// 直接用在**原串**上（[_noteLoginPrompt] 拿它切前段），而 `toLowerCase()`
  /// 在部分字符上会改变长度，两边下标就对不上了。
  int get _echoAt {
    if (command.isEmpty) return -1;
    final match =
        RegExp(RegExp.escape(command), caseSensitive: false).firstMatch(_buffer);
    return match?.start ?? -1;
  }

  /// 设备是否已经把我们写下的 [command] 回显出来了。
  bool get _echoSeen => command.isEmpty || _echoAt >= 0;

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
