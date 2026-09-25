import 'package:flutter/material.dart';

import '../../connection/connection_manager.dart';

/// 设备状态点（§7.1 的左侧列表）。
///
/// **颜色与文案由 [state] 一处决定**，不要在别处再写一份 `switch` —— 两处
/// 各写一份的下场是加了新状态之后其中一处悄悄落进 `default`。
class DeviceStatusDot extends StatelessWidget {
  const DeviceStatusDot({super.key, required this.state, this.size = 10});

  final DeviceConnectionState state;
  final double size;

  static Color colorOf(BuildContext context, DeviceConnectionState state) =>
      switch (state) {
        DeviceConnectionState.disconnected => Theme.of(context).disabledColor,
        DeviceConnectionState.connecting => Colors.amber,
        DeviceConnectionState.connected => Colors.green,
        DeviceConnectionState.reconnecting => Colors.orange,
        DeviceConnectionState.failed => Theme.of(context).colorScheme.error,
      };

  /// 悬停说明。**`failed` 用"连接失败"而不是"已断开"** —— 两者的下一步动作
  /// 不同（一个要查配置，一个可以直接重连）。
  static String labelOf(DeviceConnectionState state) => switch (state) {
    DeviceConnectionState.disconnected => '未连接',
    DeviceConnectionState.connecting => '连接中',
    DeviceConnectionState.connected => '已连接',
    DeviceConnectionState.reconnecting => '重连中',
    DeviceConnectionState.failed => '连接失败',
  };

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: labelOf(state),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: colorOf(context, state),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
