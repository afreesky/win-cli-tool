import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/device_profile.dart';
import '../../state/output_buffer.dart';
import '../../state/providers.dart';
import '../widgets/ansi_text.dart';
import '../widgets/auto_scroll.dart';
import '../widgets/refresh_throttle.dart';

/// 输出区（FR-O）：当前设备的输出、自动滚动、清屏。
///
/// **它订阅 `outputBufferProvider`，不订阅任何 `Session`。** 缓冲活得比一次
/// 会话长（FR-O-09：切走再切回来还看得到完整过程），所以重连换掉整个会话时
/// 这里什么都不用做。
///
/// **刷新走 [RefreshThrottle]，不直接监听缓冲。** NFR-F-02 要求节流到约 60ms
/// 一次 —— 设备可以 200 行/秒地吐，直接监听就是一秒重建 200 次这棵树。
class OutputPanel extends ConsumerStatefulWidget {
  const OutputPanel({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<OutputPanel> createState() => OutputPanelState();
}

class OutputPanelState extends ConsumerState<OutputPanel> {
  final ScrollController _scroll = ScrollController();
  late final AutoScroll _auto = AutoScroll(controller: _scroll);

  RefreshThrottle? _throttle;
  OutputBuffer? _buffer;

  @override
  void dispose() {
    _throttle?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 订阅当前设备的缓冲。**换设备时要把上一个节流器拆掉** —— 否则它会一直
  /// 挂在那台设备的缓冲上，而它的 `_onRefresh` 会去动一个已经换了内容的滚动区。
  void _bind(OutputBuffer buffer) {
    if (identical(buffer, _buffer)) return;
    _throttle?.dispose();
    _buffer = buffer;
    _throttle = RefreshThrottle(source: buffer)..addListener(_onRefreshed);
  }

  void _onRefreshed() {
    if (!mounted) return;
    setState(() {});
    // 新内容要**下一帧**才布局完，跟底那一跳必须排在它后面。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _auto.onContentChanged());
    });
  }

  /// 清屏（FR-O-05 / Ctrl+L）。**只在显示层动手**：`OutputBuffer.clear()` 按
  /// 设计不调 `onText`，所以日志分毫不动。
  void clearOutput() {
    _buffer?.clear();
    setState(_auto.jumpToBottom);
  }

  String _deviceName(List<DeviceProfile> devices) {
    for (final device in devices) {
      if (device.id == widget.deviceId) return device.name;
    }
    return widget.deviceId;
  }

  @override
  Widget build(BuildContext context) {
    _bind(ref.watch(outputBufferProvider(widget.deviceId)));
    final devices = ref.watch(devicesProvider);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(theme, devices),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            children: [
              NotificationListener<UserScrollNotification>(
                // 用户自己滚动时重新判定跟不跟底。**用 UserScrollNotification
                // 而不是 ScrollNotification**：前者只在**滚动方向变化**时报
                // （`updateUserScrollDirection`），也就是拖拽、以及 goIdle /
                // goBallistic 把方向改回 idle 时。
                //
                // **这只是稳健性偏好，不是承重。** 程序化跟底那一跳确实**可能**
                // 报（`jumpTo` → `goIdle()` → `beginActivity` 见到非滚动活动就
                // 把方向置回 idle，若此前是 forward/reverse 就会报一次），但那一
                // 刻 pixels 已经在底部、`extentAfter` ≈ 0，`onUserScroll` 判出来
                // 的结论相同 —— 见 [AutoScroll.onUserScroll] 的文档。
                onNotification: (_) {
                  _auto.onUserScroll();
                  setState(() {});
                  return false;
                },
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(8),
                  child: SelectableText.rich(
                    ansiLinesToTextSpan(
                      ref.watch(outputBufferProvider(widget.deviceId)).lines,
                    ),
                    // 等宽：设备回显的表格与命令靠它对齐。
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: ['DejaVu Sans Mono'],
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
              if (!_auto.stickToBottom)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton.small(
                    tooltip: '回到底部',
                    onPressed: () => setState(_auto.jumpToBottom),
                    child: const Icon(Icons.arrow_downward),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(ThemeData theme, List<DeviceProfile> devices) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.terminal, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _deviceName(devices),
              style: theme.textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '清屏',
            icon: const Icon(Icons.clear_all, size: 18),
            onPressed: clearOutput,
          ),
        ],
      ),
    );
  }
}
