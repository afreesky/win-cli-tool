import 'dart:async';

/// 编辑区草稿的落盘节流（FR-E-03 / FR-E-04）。
///
/// **保存时机是"停顿后防抖 + 退出兜底"，不是 FR-E-04 字面上的"只在退出时
/// 落盘"。** 退出才写的实现在崩溃/断电时丢掉全部编辑内容；而草稿是纯文本小
/// 文件，`DraftStore` 走原子写，多写几次的代价可以忽略。这是知情下的取舍。
///
/// **它不认识 Riverpod，也不认识 `DraftStore`** —— 落盘动作由构造时传入的
/// [save] 承担。这样它可以脱开界面用 `fakeAsync` 精确验证（防抖时序最容易写错，
/// 而它恰好是纯逻辑）。
class DraftAutosave {
  DraftAutosave({
    required this.save,
    this.debounce = const Duration(milliseconds: 500),
    this.onError,
  });

  /// 真正落盘的动作。异常由本类捕获并交给 [onError]。
  final Future<void> Function(String text) save;

  /// 编辑停止多久之后落盘。
  final Duration debounce;

  /// 落盘失败的回调。**别在这里抛** —— 它在 `catch` 里被调用，抛出去会冒到
  /// 编辑区的输入路径上。
  final void Function(Object error)? onError;

  Timer? _timer;

  /// 待落盘的内容。null 表示"没有待写的东西"。
  String? _pending;

  /// 上一次**交给 [save]** 的内容（**不是"最后成功落盘的"** —— 见 [_write]）。
  /// 用来跳过无谓的重复写 —— 切设备会重建编辑区、`setState` 会重跑
  /// `initState` 之外的路径，那些都不该产生磁盘写。
  String? _lastSaved;

  bool _disposed = false;

  /// 编辑区内容变了。停顿 [debounce] 之后落盘。
  void schedule(String text) {
    if (_disposed) return;
    if (text == _lastSaved && _pending == null) return;
    _pending = text;
    _timer?.cancel();
    _timer = Timer(debounce, _write);
  }

  /// 立刻落盘并取消待定的防抖。**应用退出时调用**（FR-E-04 的"退出时落盘"）。
  void flush() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _write();
  }

  void _write() {
    _timer = null;
    final text = _pending;
    if (text == null) return;
    _pending = null;
    // **先记下再写**，而不是等 `save` 成功之后再记。本类不认识存储层，也拿不到
    // "写成功了"这个事实 —— `save(text)` 是异步的，这里并不 await 它。所以
    // `_lastSaved` 的准确含义是"最后一次**交给** `save` 的内容"，不是"最后一次
    // **成功落盘**的内容"。失败了由 [onError] 报给调用方去提示，本类**不重试**。
    if (text == _lastSaved) return;
    _lastSaved = text;
    // `save` 返回的 Future 必须被接住 —— 它是异步的，异常不会在这里同步抛出。
    // 用 `catchError` 而不是 `try/catch`：后者接不住没有 await 的 Future。
    save(text).catchError((Object error) {
      onError?.call(error);
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
