import 'connection_failure.dart';
import 'session.dart';

/// 一台设备的连接状态。与 spec §5.4 的按钮颜色一一对应。
///
/// 颜色映射（供计划 5 使用）：disconnected→灰、connecting→黄、
/// connected→绿、reconnecting→黄、failed→红。
enum DeviceConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,

  /// 连接失败且不再自动重试（用户主动断开，或重连被关闭）。
  failed;

  /// 该状态下设备按钮是否应显示为"有连接"。重连中算"没有连接"——
  /// 此时发给设备的命令会失败，界面必须让用户看出来。
  bool get isLive => this == DeviceConnectionState.connected;
}

sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// 状态迁移。界面据此更新按钮颜色与输出区提示。
class ConnectionStateChanged extends ConnectionEvent {
  const ConnectionStateChanged(this.state);

  final DeviceConnectionState state;
}

/// 会话已就绪（首次连接或重连成功），可以下发命令了。
class SessionReady extends ConnectionEvent {
  const SessionReady(this.session);

  final Session session;
}

/// 即将在 [delay] 之后发起第 [attempt] 次重连（从 1 开始）。
class ReconnectScheduled extends ConnectionEvent {
  const ReconnectScheduled(this.attempt, this.delay);

  final int attempt;
  final Duration delay;
}

/// 重连成功。FR-C-09 要求输出区插入醒目分隔标记，[downtime] 即断线时长。
class Reconnected extends ConnectionEvent {
  const Reconnected(this.downtime, this.attempt);

  final Duration downtime;
  final int attempt;
}

/// 连接失败。[failure] 携带可读原因（FR-C-06）。
class ConnectionFailed extends ConnectionEvent {
  const ConnectionFailed(this.failure);

  final ConnectionFailure failure;
}

/// 会话断开。未发出的命令已被丢弃（FR-C-10）。
class SessionLost extends ConnectionEvent {
  const SessionLost(this.failure);

  final ConnectionFailure? failure;
}
