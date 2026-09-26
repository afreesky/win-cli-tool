import 'dart:async';
import 'dart:io';

import '../command/command_dispatcher.dart';
import '../connection/connection_failure.dart';
import '../connection/connection_manager.dart';
import '../connection/session_factory.dart';
import '../models/device_profile.dart';
import '../render/ansi_parser.dart';
import '../data/log_writer.dart';
import 'output_buffer.dart';

/// 一台设备当下的会话状态（界面直接渲染这个）。
class SessionStatus {
  const SessionStatus({
    this.state = DeviceConnectionState.disconnected,
    this.reconnect,
    this.droppedCommands = 0,
    this.lastFailure,
    this.lastDispatchEvent,
  });

  final DeviceConnectionState state;

  /// 已排程的重连（FR-C-07 的"X 秒后重连"）。null 表示没有在等。
  ///
  /// 数据源**只有** `ReconnectScheduled` 一个；重连成功后置回 null。
  final ReconnectScheduled? reconnect;

  /// 最近一次断线丢弃的命令数（FR-C-10）。数据源是 `QueueDropped`。
  final int droppedCommands;

  /// 最近一次连接失败的可读原因（FR-C-06）。
  /// **[ConnectionFailure.message] 才是展示物，[ConnectionFailure.cause] 不是。**
  final ConnectionFailure? lastFailure;

  /// 最近一条命令队列事件（FR-E-14 的 `执行中 3/8` 与超时告警都从这里算）。
  ///
  /// 只留最近一条：进度显示要的是"现在到哪了"，不是历史。**翻页不产生队列
  /// 进度变化**（`PagerContinued` 不该动进度条）。
  final DispatchEvent? lastDispatchEvent;

  SessionStatus copyWith({
    DeviceConnectionState? state,
    Object? reconnect = _unset,
    int? droppedCommands,
    Object? lastFailure = _unset,
    // **哨兵不能省。** 配 `?? this.lastDispatchEvent` 的话，传 `null` 会被
    // `??` 吃掉 —— "清空"这个动作**静默失效**，而调用点看起来完全正确
    // （`reconnect` / `lastFailure` 早就有哨兵，这是同一个坑的第三个实例：
    // `lastDispatchEvent` 直到 5b-2 才出现第一个"传 null 有意义"的调用点）。
    Object? lastDispatchEvent = _unset,
  }) => SessionStatus(
    state: state ?? this.state,
    reconnect: identical(reconnect, _unset)
        ? this.reconnect
        : reconnect as ReconnectScheduled?,
    droppedCommands: droppedCommands ?? this.droppedCommands,
    lastFailure: identical(lastFailure, _unset)
        ? this.lastFailure
        : lastFailure as ConnectionFailure?,
    lastDispatchEvent: identical(lastDispatchEvent, _unset)
        ? this.lastDispatchEvent
        : lastDispatchEvent as DispatchEvent?,
  );
}

const Object _unset = Object();

/// §5.4 的断开标记与 §7.3 的命令超时告警都是**黄色**。
const AnsiStyle kMarkerWarnStyle = AnsiStyle(foreground: AnsiBasic(3));

/// 重连成功的分隔线。
const AnsiStyle kMarkerOkStyle = AnsiStyle(foreground: AnsiBasic(2));

/// 一台设备的会话编排：把 [ConnectionManager] 的事件翻译成界面能直接用的东西，
/// 并管住日志的生命周期。
///
/// **它订阅的是 `mgr.output`，不是 `Session.output`，而且是在构造时就订阅。**
/// 会话对象在重连时会被整个替换；直接订阅 Session 会让输出区在第一次断线后
/// **永久静止而按钮是绿的**（`ConnectionManager` 的类文档）。在这里订阅还保证了
/// "第一次连接之前就已经接上"—— 连接建立之前到达的输出不会丢。
///
/// **`SessionReady` 携带的 dispatcher 每次重连都是新的**，所以 `dispatcher.events`
/// 必须在那时重新订阅。类型上刻意给 dispatcher 而不给 Session，就是为了让这里
/// 没有任何理由去碰 Session。
class SessionController {
  SessionController({
    required this.profile,
    required SessionFactory factory,
    required this.buffer,
    required this.logsDir,
    required this.logEnabled,
    this.onLogError,
  }) : _manager = ConnectionManager(profile: profile, factory: factory) {
    _outputSub = _manager.output.listen(buffer.add);
    _eventsSub = _manager.events.listen(_onEvent);
  }

  final DeviceProfile profile;

  /// 输出缓冲。**与日志共用同一处边界**（见 `OutputBuffer` 的文档）。
  final OutputBuffer buffer;

  /// 日志根目录。设置里覆盖过就用覆盖值（FR-L-02），否则是应用数据目录下的
  /// `logs/`。
  final Directory logsDir;

  /// FR-L-07：**关日志的实现方式是不构造 `LogWriter`** —— 那个类自己不做开关。
  ///
  /// **本值是构造时读一次的**：会话已经跑起来之后改这个设置不会中途换行为，
  /// 下次连接才生效。这是知情的取舍（换日志文件写到一半会留下两个文件）。
  final bool logEnabled;

  /// 写盘失败的回调（FR-L-06）。**别在这里抛** —— 它在 `_flush` 的 `catch` 里
  /// **同步**被调用，抛出去会冒到会话循环里，而那正是 FR-L-06 要避免的
  /// "日志坏掉拖垮会话"。
  final void Function(Object error)? onLogError;

  final ConnectionManager _manager;
  late final StreamSubscription<String> _outputSub;
  late final StreamSubscription<ConnectionEvent> _eventsSub;

  /// 当前会话的 dispatcher 事件订阅。**每次 `SessionReady` 换一个。**
  StreamSubscription<DispatchEvent>? _dispatchSub;

  /// 当前会话的日志。**一次会话一个实例**，会话结束调 `end()`。
  LogWriter? _log;

  /// [dispose] 一开始就同步置位，此后**一个事件都不再处理**。
  ///
  /// 背景：`ConnectionManager.events` 是广播流，`connect()` 返回时事件可能还排在
  /// 队列里，而 `dispose()` 里任何一次 `await` 都会把控制权让出去 —— 那个事件于是
  /// 落到一个正在被拆掉的 controller 上（`_onSessionReady` 会重新订阅 dispatcher
  /// 并 `_startLog()`），或在已销毁的 provider 上写 `state`。
  ///
  /// **它和"把 `_eventsSub.cancel()` 提到第一位"是两条各自充分的机制**，实测 2×2：
  /// 原顺序 + 无本标志 = **红**（`Cannot use the Ref ...`）；其余三格全绿。
  /// `cancel()` 单独就够，是因为 Dart 的 `cancel()` **同步生效** —— 已排队但尚未
  /// 投递的事件此后不会再被投递。**所以别写成"标志承重、cancel 顺手"**：那句话是
  /// 我原先写的，被这张表推翻了。
  ///
  /// 那为什么两条都留？因为本标志还挡着**另一条**路径：新顺序把
  /// `_dispatchSub?.cancel()` 排在 `await _eventsSub.cancel()` **之后**，那次 `await`
  /// 同样让路，所以 dispatcher 广播流里已排队的 `QueueDropped` / `CommandCompleted`
  /// 仍可能在销毁途中被投递进来 —— 挡住它的正是 [_onDispatchEvent] 里那条守卫。
  /// **这一格是推理，没有实测**（现有用例没有构造"已排队的 dispatcher 事件"）。
  var _disposed = false;

  var _status = const SessionStatus();

  /// 最近一条**已经写进输出区**的失败原因（FR-C-06）。见 [_reportFailure]。
  ///
  /// null 表示"还没报过"，于是下一条失败一定会显示。
  String? _reportedFailure;

  /// 状态变化时回调（界面订阅它重绘）。
  void Function(SessionStatus status)? onStatus;

  SessionStatus get status => _status;

  /// 该设备当前的连接状态。
  DeviceConnectionState get state => _manager.state;

  /// 该设备当前会话的命令队列。未连接时为 null。
  ///
  /// 界面**不该**从这里取 dispatcher（时序约定藏起来了），应该在
  /// `SessionReady` 时拿 —— 但本类已经把那些约定处理完了，所以对界面暴露的是
  /// [enqueue] 与 [abort]。
  CommandDispatcher? get dispatcher => _manager.dispatcher;

  /// 把命令排进该设备的队列（FR-E-01）。未连接时什么都不做。
  void enqueue(List<String> commands) => _manager.dispatcher?.enqueue(commands);

  /// 中止队列（FR-E-13 / Esc）：不再发送剩余命令，已发出的不做处理。
  void abort() => _manager.dispatcher?.abort();

  Future<void> connect() {
    // FR-C-06：手动重连时重新开始"这条原因报过没有"的判断。不清的话，
    // 上一次已报过的同一原因会被当成重复而**不再显示** —— 用户按了连接，
    // 界面却连一句理由都不给。见 [_reportFailure]。
    _reportedFailure = null;
    return _manager.connect();
  }

  Future<void> disconnect() async {
    await _manager.disconnect();
    await _endLog();
  }

  /// 应用退出时调用（FR-C-12）。**不向设备发送任何命令。**
  ///
  /// **第一件事是"此后不再处理任何事件"，而且必须在任何 `await` 之前。**
  ///
  /// 本方法经 `ref.onDispose(_controller.dispose)` 注册，Riverpod **不 await
  /// 它**（`onDispose` 收的是 `void Function()`，这里给的是 async 函数，返回的
  /// Future 被丢掉）；而 `ConnectionManager.events` 是**广播流**，`connect()`
  /// 返回时 `SessionReady` / `ConnectionStateChanged` 可能**还排在队列里**。
  /// 所以这里但凡先 `await` 一次，那个已排队的事件就会被投递进来，
  /// `_onSessionReady` 于是**在销毁过程中**重新订阅 dispatcher 并 `_startLog()` ——
  /// 建出一个此后再也取消不掉的订阅，还为一个正在被拆掉的会话开一个日志文件。
  ///
  /// 这不是推理出来的：退出用例（`connect()` 之后立刻 dispose）实跑连红 4 次，
  /// 栈就是 `_onEvent → _onSessionReady → _setStatus`，抛在 `state = status` 上
  /// （`Cannot use the Ref ... after it has been disposed`）。
  ///
  /// [_disposed] 与"`_eventsSub.cancel()` 排第一"**是两条各自充分的机制**，不是
  /// "标志承重、cancel 顺手"（后者是我原先写的，被上面那张 2×2 表推翻）。两者都
  /// 留的理由见 [_disposed] 的文档：它们挡的不是同一条路径。
  Future<void> dispose() async {
    _disposed = true;
    await _eventsSub.cancel();
    await _dispatchSub?.cancel();
    await _outputSub.cancel();
    // 残留的半条序列放出来，否则它永远留在缓冲里 —— 而输出区此后不再有新数据
    // 来把它补齐。
    buffer.flush();
    _endLogSync();
    await _manager.dispose();
  }

  void _onEvent(ConnectionEvent event) {
    if (_disposed) return;
    // `ConnectionEvent` 是 `sealed`：将来新增一种会成为**编译错误**，
    // 而不是某个分支悄悄不处理。
    switch (event) {
      case ConnectionStateChanged(:final state):
        _setStatus(_status.copyWith(state: state));
      case SessionReady(:final dispatcher):
        _onSessionReady(dispatcher);
      case ReconnectScheduled():
        _setStatus(_status.copyWith(reconnect: event));
        _markWarn('--- 连接断开，${event.delay.inSeconds} 秒后重连'
            '（第 ${event.attempt} 次）---');
      case Reconnected(:final downtime, :final attempt):
        _setStatus(_status.copyWith(reconnect: null));
        _markOk('--- 重连成功（断线 ${downtime.inSeconds} 秒，'
            '第 $attempt 次尝试）---');
        _log?.reconnected();
      case ConnectionFailed(:final failure):
        _setStatus(_status.copyWith(lastFailure: failure));
        _reportFailure(failure);
      case SessionLost():
        _markWarn('--- 连接断开 ---');
        _log?.disconnected();
    }
  }

  void _onSessionReady(CommandDispatcher dispatcher) {
    // FR-C-06：新会话开始了，上一次失败的原因已经翻篇 —— 这段会话将来若
    // 再失败，即使原因与上次逐字相同，也应当重新显示。见 [_reportFailure]。
    _reportedFailure = null;
    _setStatus(
      _status.copyWith(
        reconnect: null,
        lastFailure: null,
        // 上一次断线的丢弃数属于上一次断线，新会话开始就归零。
        droppedCommands: 0,
        // **进度文案同理。** 新会话里队列是空的，上一段断线留下的
        // `QueueDropped` 若不清掉，工具栏会在**已经重连成功**之后继续显示
        // "断线，N 条命令未完成" —— 那句话说的是现在，而现在是绿的。
        lastDispatchEvent: null,
      ),
    );
    // **每次重连都新建一个 dispatcher**，所以这里必须重新订阅 —— 不重订的话
    // `QueueDropped`（FR-C-10 的告警）与命令进度在第一次断线后就再也没有了。
    _dispatchSub?.cancel();
    _dispatchSub = dispatcher.events.listen(_onDispatchEvent);
    _startLog();
  }

  void _onDispatchEvent(DispatchEvent event) {
    // dispatcher 的广播流也可能有已排队的事件，而 `_dispatchSub?.cancel()` 现在
    // 排在 `await _eventsSub.cancel()` **之后** —— 那次 `await` 会让路给它。
    // **这条守卫是推理出来的，没有实测**（没有用例构造"已排队的 dispatcher 事件"）。
    if (_disposed) return;
    if (event is QueueDropped) {
      _setStatus(_status.copyWith(droppedCommands: event.count));
      // **不说"未发送"。** `QueueDropped.count` 是"排队数 + 在途数"
      // （`command_dispatcher.dart` 的 `onDisconnected`）—— 在途那条**已经写到
      // 设备上了**，只是输出永远收不到。说它"未发送"会让用户以为设备没被改过。
      _markWarn('--- 连接断开，${event.count} 条命令未完成并已丢弃 ---');
      // **原来这里直接 return，于是 `lastDispatchEvent` 从不变成本事件，
      // 编辑区那条 `if (event is QueueDropped)` 永远走不到**（它的文案再改
      // 也没人看得见）。落一次，让工具栏也能显示"断线，N 条命令未完成"。
      //
      // **事件本身没动**（决策③）：`QueueDropped(count)` 的载荷与语义一个字
      // 不改，这里只是把这个事件也记进"最近一次派发事件"。
      _setStatus(_status.copyWith(lastDispatchEvent: event));
      return;
    }
    if (event is CommandCompleted && event.timedOut) {
      // §7.3：超时的命令，其对应输出区域插入**黄色**告警行，
      // 注明超时的命令序号与原命令文本（FR-E-12）。
      _markWarn(
        '--- 第 ${event.index}/${event.total} 条命令执行超时，已强制放行'
        '下一条：${event.command} ---',
      );
    }
    _setStatus(_status.copyWith(lastDispatchEvent: event));
  }

  void _setStatus(SessionStatus next) {
    _status = next;
    onStatus?.call(next);
  }

  /// FR-C-06：把失败原因写进**输出区**。
  ///
  /// **原先只写进了 `_status.lastFailure`，而 `lib/ui/` 里没有任何一处读它**
  /// —— 于是用户看到的是一个没有任何解释的重试循环。这正是 2026-09-26 对真机
  /// 排查时的现场：一台只提供 `ssh-rsa` 的交换机连不上，界面只有"X 秒后重连"
  /// 反复滚动。规格 §10.1 接受"不兼容旧算法"的**前提**就是"失败时按 FR-C-06
  /// 给出可读原因"，那个前提当时是空的。
  ///
  /// **同一条原因只报一次。** `ConnectionFailed` 是**每次失败尝试**都发的
  /// （`ConnectionManager._attemptConnect` 的 catch 里），而 FR-C-07 会一直重试
  /// 下去（退避到 30s 封顶后无限期），逐条写会把输出区刷满同一句话，把真正的
  /// 输出挤走。抑制的只是**重复的同一句**：
  ///
  /// - 原因**变了**（超时 → 认证失败）→ 立刻再报一条，那是新信息；
  /// - 重连成功后再次失败（[_onSessionReady] 清空）→ 再报；
  /// - 用户手动点连接（[connect] 清空）→ 再报，否则"按了连接却没有任何理由"
  ///   会比不显示更费解。
  ///
  /// "还在重试"这件事由 `ReconnectScheduled` 那条标记负责，两者不重复。
  void _reportFailure(ConnectionFailure failure) {
    if (_reportedFailure == failure.message) return;
    _reportedFailure = failure.message;
    _markWarn('--- 连接失败：${failure.message} ---');
  }

  void _markWarn(String text) => buffer.addMarker(text, style: kMarkerWarnStyle);
  void _markOk(String text) => buffer.addMarker(text, style: kMarkerOkStyle);

  /// 开始一次会话的日志。**FR-L-07：关掉日志就是不构造它。**
  void _startLog() {
    if (!logEnabled) return;
    _log ??= LogWriter(
      rootDir: logsDir,
      deviceName: profile.name,
      onError: onLogError,
    );
    // **先 `start()` 再挂出口，顺序不能反。** `LogWriter.write()` 开头是
    // `if (!_started || _closed) return;` —— 出口先挂上、`start()` 还没跑的话，
    // 这中间到达的输出会被**静默丢掉**（而 `start()` 的同步部分其实立刻就跑完了，
    // 所以反着写也"能用"，只是留下一个靠时序运气维持的窗口）。
    // `unawaited` 的理由：这里在事件回调里，不该被磁盘拖住；`start()` 的同步部分
    // 已经跑完，后续 `write()` 一定排在它后面。
    unawaited(_log!.start('${profile.username}@${profile.host}:${profile.port}'));
    // 输出缓冲的日志出口指向**本次会话**的 writer。缓冲活得比一次会话长，
    // 所以这个出口是可换的 —— 会话结束后置空，那段时间攒下的输出不进任何日志。
    buffer.onText = (text) => unawaited(_log?.write(text));
  }

  Future<void> _endLog() async {
    final log = _log;
    _log = null;
    buffer.onText = null;
    await log?.end();
  }

  /// [dispose] 用的是同步版：那里已经不能安全地 await 太多东西，
  /// 而 `end()` 的落盘在进程退出前会由缓冲的 flush 兜住。
  void _endLogSync() {
    final log = _log;
    _log = null;
    buffer.onText = null;
    unawaited(log?.end());
  }
}

/// FR-C-14：启动时对 `autoConnect == true` 的设备各发起一次连接。
///
/// 写成接收回调的纯函数而不是塞进某个 provider 的 `build()`：读设备列表与
/// 连设备是两件事，后者有副作用，不该藏在任何 provider 的构造里。
void connectAutoConnectDevices({
  required List<DeviceProfile> devices,
  required void Function(String deviceId) connect,
}) {
  for (final device in devices) {
    if (!device.autoConnect) continue;
    connect(device.id);
  }
}
