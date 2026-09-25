import 'dart:async';

import 'package:flutter/foundation.dart';

/// 把 [source] 的高频变更压成**至多每 [interval] 一次**的通知（NFR-F-02）。
///
/// 为什么需要它：设备可以 200 行/秒地吐数据（NFR-F-03），而每一块到达都会让
/// `OutputBuffer` 通知一次。若界面直接监听缓冲，那一秒内就会重建 200 次
/// `SelectableText.rich` 树——NFR-F-02 明写"不得逐字节触发界面重绘"。
///
/// **形状是"首次立刻放行，之后按窗口合并"**，不是"一律延迟 [interval]"：
/// 用户点清屏、切设备这类操作走的是同一条通知路径，让人等 60ms 才看到反应是
/// 没必要的。所以第一次变更立刻通知，随后在窗口内的连串变更合并成窗口结束时
/// 的一次。
///
/// **窗口结束时若没有再攒下变更，定时器就停掉**——不空转。所以静止下来的
/// 界面不持有任何定时器。
class RefreshThrottle extends ChangeNotifier {
  RefreshThrottle({
    required this.source,
    this.interval = const Duration(milliseconds: 60),
  }) {
    source.addListener(_onSourceChanged);
  }

  /// 上游变更源（界面里是 `OutputBuffer`）。
  final Listenable source;

  /// 合并窗口。默认 60ms，来自 NFR-F-02 的"约 60ms 一次"。
  final Duration interval;

  Timer? _timer;

  /// 窗口内是否又攒下了变更 —— 决定窗口到点时要不要补一次通知。
  bool _pending = false;

  void _onSourceChanged() {
    if (_timer != null) {
      // 已经在窗口里：只记下"还有变更"，到点一并通知。
      _pending = true;
      return;
    }
    notifyListeners();
    _timer = Timer(interval, _onWindowClosed);
  }

  void _onWindowClosed() {
    _timer = null;
    if (!_pending) return;
    _pending = false;
    notifyListeners();
    _timer = Timer(interval, _onWindowClosed);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    source.removeListener(_onSourceChanged);
    super.dispose();
  }
}
