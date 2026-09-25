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
    DispatchEvent? lastDispatchEvent,
  }) => SessionStatus(
    state: state ?? this.state,
    reconnect: identical(reconnect, _unset)
        ? this.reconnect
        : reconnect as ReconnectScheduled?,
    droppedCommands: droppedCommands ?? this.droppedCommands,
    lastFailure: identical(lastFailure, _unset)
        ? this.lastFailure
        : lastFailure as ConnectionFailure?,
    lastDispatchEvent: lastDispatchEvent ?? this.lastDispatchEvent,
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

  var _status = const SessionStatus();

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

  Future<void> connect() => _manager.connect();

  Future<void> disconnect() async {
    await _manager.disconnect();
    await _endLog();
  }

  /// 应用退出时调用（FR-C-12）。**不向设备发送任何命令。**
  Future<void> dispose() async {
    await _dispatchSub?.cancel();
    await _eventsSub.cancel();
    await _outputSub.cancel();
    // 残留的半条序列放出来，否则它永远留在缓冲里 —— 而输出区此后不再有新数据
    // 来把它补齐。
    buffer.flush();
    _endLogSync();
    await _manager.dispose();
  }

  void _onEvent(ConnectionEvent event) {
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
      case SessionLost():
        _markWarn('--- 连接断开 ---');
        _log?.disconnected();
    }
  }

  void _onSessionReady(CommandDispatcher dispatcher) {
    _setStatus(
      _status.copyWith(
        reconnect: null,
        lastFailure: null,
        // 上一次断线的丢弃数属于上一次断线，新会话开始就归零。
        droppedCommands: 0,
      ),
    );
    // **每次重连都新建一个 dispatcher**，所以这里必须重新订阅 —— 不重订的话
    // `QueueDropped`（FR-C-10 的告警）与命令进度在第一次断线后就再也没有了。
    _dispatchSub?.cancel();
    _dispatchSub = dispatcher.events.listen(_onDispatchEvent);
    _startLog();
  }

  void _onDispatchEvent(DispatchEvent event) {
    if (event is QueueDropped) {
      _setStatus(_status.copyWith(droppedCommands: event.count));
      _markWarn('--- 连接断开，${event.count} 条未发送的命令已丢弃 ---');
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
