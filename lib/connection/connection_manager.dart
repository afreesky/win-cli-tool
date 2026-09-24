import '../command/command_dispatcher.dart';
import 'connection_failure.dart';

/// 一台设备的连接状态。与 spec §5.4 的按钮颜色一一对应。
///
/// 颜色映射（供计划 5 使用）：disconnected→灰、connecting→黄、
/// connected→绿、reconnecting→黄、failed→红。
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
