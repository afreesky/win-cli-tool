import 'dart:async';

import 'package:clock/clock.dart';

import '../command/command_dispatcher.dart';
import '../command/more_pager.dart';
import '../command/prompt_detector.dart';
import '../models/device_profile.dart';
import 'connection_failure.dart';
import 'session.dart';
import 'session_factory.dart';

/// 一台设备的连接状态。与 spec §5.4 的按钮颜色一一对应。
///
/// 颜色映射（供计划 5 使用）：disconnected→灰、connecting→黄、
/// connected→绿、reconnecting→黄、failed→红。
///
/// 注意"红"：§5.4 的逐事件表里**没有**红（只有黄/黄/绿/灰），红来自
/// FR-C-06 的"连接失败"。`failed` 何时可达目前尚未定论，见 spec §13.17-3。
enum DeviceConnectionState {
  /// 未连接。与 [connecting]/[reconnecting] 同为"没有连接"，
  /// 但颜色不同：这两个是黄，本状态是灰。
  disconnected,
  connecting,
  connected,

  /// 重连中。与 [connecting] **颜色相同**（都是黄），区别只在输出区文案。
  reconnecting,

  /// 连接失败且**不再自动重试**（`autoReconnect` 为 false 时）。
  ///
  /// 注意：用户主动断开**不是**这个状态 —— §5.4 要求那种情况按钮变灰，
  /// 也就是 [disconnected]。
  failed;

  /// 该状态下设备按钮是否应显示为"有连接"。重连中算"没有连接"——
  /// 此时发给设备的命令会失败，界面必须让用户看出来。
  bool get isLive => this == DeviceConnectionState.connected;
}

/// [ConnectionManager] 对外发出的事件。每台设备一个 manager，各自一条流。
///
/// 声明为 `sealed`：界面（计划 5）对它的 switch 会被编译器要求穷尽，
/// 将来新增一种事件会成为**编译错误**，而不是某个分支悄悄不渲染。
sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// 状态迁移。界面据此更新按钮颜色与输出区提示。
final class ConnectionStateChanged extends ConnectionEvent {
  const ConnectionStateChanged(this.state);

  final DeviceConnectionState state;
}

/// 会话已就绪（首次连接或重连成功），可以下发命令了。
///
/// 携带的是本次会话的 [CommandDispatcher]：每次重连都会**新建**一个，
/// 所以界面必须在这里重新订阅 `dispatcher.events`（命令输出与
/// [QueueDropped] 都从那里来）。
///
/// **界面不得订阅 `Session.output`** —— 会话对象在重连时会被整个替换，
/// 直接订阅它会让输出区在第一次断线后永久静止而按钮是绿的。
/// 输出请订阅 `ConnectionManager.output`。
final class SessionReady extends ConnectionEvent {
  const SessionReady(this.dispatcher);

  final CommandDispatcher dispatcher;
}

/// 即将在 [delay] 之后发起第 [attempt] 次重连（从 1 开始）。
final class ReconnectScheduled extends ConnectionEvent {
  const ReconnectScheduled(this.attempt, this.delay);

  final int attempt;
  final Duration delay;
}

/// 重连成功。FR-C-09 要求输出区插入醒目分隔标记，[downtime] 即断线时长。
final class Reconnected extends ConnectionEvent {
  const Reconnected(this.downtime, this.attempt);

  /// 从断开到重连成功经过的时长（FR-C-09 的标记要显示它）。
  final Duration downtime;

  /// 是第几次重连尝试成功的（从 1 开始）。
  ///
  /// 计数在**连接成功**时归零，所以它只统计本次断线期间的重试次数。
  /// 首次就连接成功不发本事件（attempt 恒 > 0）。
  final int attempt;
}

/// 连接失败。[failure] 携带可读原因（FR-C-06）。
final class ConnectionFailed extends ConnectionEvent {
  const ConnectionFailed(this.failure);

  final ConnectionFailure failure;
}

/// 会话断开。
///
/// 被丢弃的命令数**不在**这里 —— 它在 [CommandDispatcher] 的 [QueueDropped]
/// 上（那是计划 1 已有的契约，界面直接订阅 `dispatcher.events` 取用）。
/// 一次断线只发**一个**本事件。
final class SessionLost extends ConnectionEvent {
  const SessionLost(this.failure);

  /// null 表示对端正常结束，或本次断开没有可分类的错误 ——
  /// 界面需要自备兜底文案。
  final ConnectionFailure? failure;
}

/// 一台设备的会话生命周期、重连与命令队列。
///
/// **所有权约定**：界面只订阅本类的 [events] 与 [dispatcher]，
/// **不直接订阅 [Session]**。会话在重连时会被整个替换，本类是唯一
/// 知道"什么时候换了"的角色；若界面直接持有旧的 Session，重连之后
/// 输出区会永久静止而按钮却是绿的。
class ConnectionManager {
  ConnectionManager({
    required this.profile,
    required this.factory,
    this.autoReconnect = true,
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ],
    this.promptDetector,
    this.morePager,
  });

  final DeviceProfile profile;
  final SessionFactory factory;
  final bool autoReconnect;

  /// 退避序列。最后一项即封顶值，之后一直用它（FR-C-07）。
  final List<Duration> backoff;

  final PromptDetector? promptDetector;
  final MorePager? morePager;

  final _events = StreamController<ConnectionEvent>.broadcast();
  final _output = StreamController<String>.broadcast();

  Session? _session;
  CommandDispatcher? _dispatcher;
  StreamSubscription<String>? _outputSub;
  Timer? _retryTimer;
  var _state = DeviceConnectionState.disconnected;
  var _attempt = 0;
  var _disconnectedAt = clock.now();
  var _disposed = false;
  var _userClosed = false;

  Stream<ConnectionEvent> get events => _events.stream;

  /// 该设备的合并输出流。跨重连连续 —— 界面只订阅这一个。
  Stream<String> get output => _output.stream;

  DeviceConnectionState get state => _state;

  /// 当前会话的命令队列。未连接时为 null。
  CommandDispatcher? get dispatcher => _dispatcher;

  void _setState(DeviceConnectionState s) {
    if (_state == s) return;
    _state = s;
    if (!_events.isClosed) _events.add(ConnectionStateChanged(s));
  }

  /// 发起连接。用户点击设备按钮时调用（FR-C-03）。
  Future<void> connect() async {
    if (_disposed) return;
    _userClosed = false;
    await _attemptConnect();
  }

  Future<void> _attemptConnect() async {
    if (_disposed || _userClosed) return;

    _setState(
      _attempt == 0
          ? DeviceConnectionState.connecting
          : DeviceConnectionState.reconnecting,
    );

    final session = factory.create(profile);
    _session = session;

    try {
      await session.connect();
    } catch (e) {
      if (_disposed) return;
      // 不 await：拆除是清理，不能挡住重连排程。_teardownSession 会在任何
      // await 之前同步清空 _session/_outputSub 等状态，所以 fire-and-forget
      // 不会与随后的重连串到一起去。
      unawaited(_teardownSession());
      // 用户已断开或应用已退出：这次失败是我们自己关掉 socket 造成的。
      // 报给用户就是假告警，改状态则会让按钮从灰变红（§5.4 要求是灰的）。
      if (_disposed || _userClosed) return;
      if (!_events.isClosed) {
        _events.add(ConnectionFailed(classifyConnectionFailure(e)));
      }
      _scheduleRetry();
      return;
    }

    if (_disposed || _userClosed) {
      // 建连期间用户已经断开或应用已退出：直接关掉，不进入已连接状态。
      await _teardownSession();
      return;
    }

    _outputSub = session.output.listen((chunk) {
      if (!_output.isClosed) _output.add(chunk);
      _dispatcher?.onOutput(chunk);
    }, onError: (Object _) {});

    _dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: promptDetector ?? PromptDetector(),
      morePager: morePager ?? MorePager(),
      lineEnding: profile.lineEnding,
    );
    // `done` **不会**以错误完成（两个实现都只 `complete()`，不带参数），所以这里
    // **不接** `onError:` —— 那条分支永远不会执行，而它读起来像"断开原因就是从
    // 这儿传下去的"，比没有更糟。原因走 [Session.lastError]：`done` 完成之后再读，
    // 此时它一定已经写好（两个实现的 `_onDisconnected` 都是先存再 `complete()`，
    // spec §13.12 / §13.20）。
    session.done.then((_) => _onSessionDone(session.lastError));

    final wasReconnect = _attempt > 0;
    if (wasReconnect) {
      // 用 clock.now() 而不是 DateTime.now()：fake_async 推进的是 clock，
      // 用真实时间会让 FR-C-09 的断线时长在测试里恒为 0。
      final downtime = clock.now().difference(_disconnectedAt);
      if (!_events.isClosed) _events.add(Reconnected(downtime, _attempt));
    }
    if (!_events.isClosed) _events.add(SessionReady(_dispatcher!));

    // 退避计数在**连接成功**时归零：FR-C-07 的 1→2→4→… 描述的是
    // "一直连不上时等多久"，不是"这台设备历史上断过几次"。一台能连上、
    // 只是偶尔掉线的设备，每次都应该 1s 后就重连，而不是无限升级到 30s。
    _attempt = 0;
    _setState(DeviceConnectionState.connected);

    // FR-C-08：连接成功后自动下发登录后命令。追加到队列尾部，
    // 因此用户此时发出的命令会排在其后。
    if (profile.postLoginCommands.isNotEmpty) {
      _dispatcher!.enqueue(profile.postLoginCommands);
    }
  }

  /// [error] 只有一个来源：`session.done` 完成之后读到的 `session.lastError`。
  /// 形参**不再是可选的** —— 可选会让人以为还有别的调用点（原先那条 `onError:`
  /// 已经删掉，见上面注册处）。
  void _onSessionDone(Object? error) {
    if (_disposed || _userClosed) return;
    _disconnectedAt = clock.now();

    // FR-C-10：未发出的命令一律丢弃，不自动重放。
    // onDisconnected 会把在途的那条也计入丢弃数 —— 它的输出永远收不到了。
    _dispatcher?.onDisconnected();
    _teardownSession();

    if (!_events.isClosed) {
      _events.add(
        SessionLost(error == null ? null : classifyConnectionFailure(error)),
      );
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    // 用户主动断开或应用退出：状态已由 disconnect()/dispose() 定好，
    // 这里再改一次就会把按钮从灰刷成红（§5.4 要求灰色）。
    if (_disposed || _userClosed) return;

    if (!autoReconnect) {
      _setState(DeviceConnectionState.failed);
      return;
    }

    _setState(DeviceConnectionState.reconnecting);
    _attempt++;

    // 超出序列时用最后一项（封顶，FR-C-07）。
    final delay =
        backoff[_attempt - 1 < backoff.length
            ? _attempt - 1
            : backoff.length - 1];

    if (!_events.isClosed) _events.add(ReconnectScheduled(_attempt, delay));

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (_disposed || _userClosed) return;
      unawaited(_attemptConnect());
    });
  }

  /// 用户主动断开（FR-C-05）。停止重连，按钮变灰（§5.4）。
  Future<void> disconnect() async {
    _userClosed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _attempt = 0;
    // 立即置为已断开：用户点了"断开"，按钮就该马上变灰，而不是等拆除
    // 流程走完（关闭 socket 可能要等对端响应）。state 是同步可读的，
    // 界面下一帧就会看到。
    _setState(DeviceConnectionState.disconnected);
    await _teardownSession();
  }

  /// 应用退出时调用（FR-C-12）。
  ///
  /// **不向设备发送任何命令** —— 包括不清除分页、不执行任何登出序列。
  /// 目的是避免意外改变设备状态。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _userClosed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _teardownSession();
    await _events.close();
    await _output.close();
  }

  /// 拆除当前会话。可重入：状态在任何 await 之前就被清空并取走，
  /// 因此重复调用是空操作，也不会出现"慢的那个把新会话的字段置空"。
  Future<void> _teardownSession() async {
    final session = _session;
    final outputSub = _outputSub;
    final dispatcher = _dispatcher;
    _session = null;
    _outputSub = null;
    _dispatcher = null;

    await outputSub?.cancel();

    // 不 await dispatcher.dispose()：它是广播 StreamController，close() 的
    // future 要等订阅者全部摘干净才完成，而订阅者不止我们 —— 界面会直接
    // 订阅 dispatcher.events。把 session.close() 挂在它后面，就等于让
    // FR-C-12（退出时必须关闭会话）依赖一个我们控制不了的 future。
    // 实测：await 它会让本函数停在此处不再往下走，session.close() 永远
    // 执行不到。dispose() 的同步部分（_disposed=true、清空队列）立即生效，
    // 所以 fire-and-forget 不会再发出任何命令。
    if (dispatcher != null) unawaited(dispatcher.dispose());

    if (session != null) {
      // done 完成不等于资源已释放（spec §13.12）：close() 仍必须调用。
      await session.close();
    }
  }
}
