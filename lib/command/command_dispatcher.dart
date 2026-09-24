import 'dart:async';

import 'more_pager.dart';
import 'prompt_detector.dart';

/// 一次下发批次中发生的事件。
sealed class DispatchEvent {
  const DispatchEvent();
}

/// 一条命令已写出。
class CommandSent extends DispatchEvent {
  const CommandSent(this.command, this.index, this.total);

  final String command;

  /// 在本次批次中的序号，从 1 开始。
  final int index;
  final int total;
}

/// 一条命令已结束（正常完成或超时）。
class CommandCompleted extends DispatchEvent {
  const CommandCompleted(
    this.command, {
    required this.timedOut,
    required this.index,
    required this.total,
  });

  final String command;
  final bool timedOut;

  /// 在本次批次中的序号，从 1 开始。超时告警行要注明序号（spec §5.2）。
  final int index;
  final int total;
}

/// 识别到翻页提示并已回送继续键。
class PagerContinued extends DispatchEvent {
  const PagerContinued();
}

/// 一个批次全部执行完毕。
class QueueFinished extends DispatchEvent {
  const QueueFinished();
}

/// 用户主动中止了队列。[dropped] 是未发出的命令数。
class QueueAborted extends DispatchEvent {
  const QueueAborted(this.dropped);

  final int dropped;
}

/// 连接断开导致队列被丢弃。[count] 是丢弃的命令数。
class QueueDropped extends DispatchEvent {
  const QueueDropped(this.count);

  final int count;
}

/// 命令队列与串行下发状态机。
///
/// 核心不变式：**同一时刻只有一条命令在途**。发出一条后必须等到提示符
/// （且数据静默）或超时，才会发出下一条。这是网络设备 CLI 的硬性要求
/// —— 连着灌命令会让回显与命令错位。
class CommandDispatcher {
  CommandDispatcher({
    required this.write,
    required this.promptDetector,
    required this.morePager,
    this.lineEnding = '\n',
    this.promptDebounce = const Duration(milliseconds: 120),
    this.commandTimeout = const Duration(seconds: 10),
    this.bufferLimit = 8192,
  });

  /// 把一条命令写出去（不含行尾符，由本类补）。
  final void Function(String data) write;

  /// 提示符判定器。
  final PromptDetector promptDetector;

  /// 翻页判定器。
  final MorePager morePager;

  /// 命令行尾符。
  final String lineEnding;

  /// 静默去抖时长：命中提示符后还要等这么久没有新数据才算完成。
  final Duration promptDebounce;

  /// 单条命令的执行超时。
  final Duration commandTimeout;

  /// 接收缓冲区上限，超出丢弃最旧的数据。
  final int bufferLimit;

  final _events = StreamController<DispatchEvent>.broadcast();

  final _queue = <String>[];
  final _batch = <String>[];
  String? _current;
  var _currentIndex = 0;
  String _buffer = '';
  Timer? _debounce;
  Timer? _timeout;
  var _aborted = false;
  var _disposed = false;

  /// 事件流，供界面渲染进度与告警。
  Stream<DispatchEvent> get events => _events.stream;

  /// 是否有命令在途。
  bool get isBusy => _current != null;

  /// 当前批次的命令总数。
  int get total => _batch.length;

  /// 当前批次已发出的命令数。
  int get sentCount => _currentIndex;

  /// 把一批命令加入队列。
  ///
  /// 完全空白的行会被跳过（spec FR-E-08）—— 避免空回车污染回显。行首尾
  /// 空白会被去掉。若清洗后为空则什么都不做。
  ///
  /// 批次执行中调用会**追加**到当前批次，批次总数随之变大：先前报
  /// `3/8` 的进度事件，之后再报就是 `4/10`。因此 [CommandSent.total]
  /// / [CommandCompleted.total] 反映的是**事件发出那一刻**的批次规模，
  /// 不是最终规模。
  void enqueue(Iterable<String> commands) {
    if (_disposed) return;
    final cleaned = commands
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) return;

    if (isBusy) {
      // 批次执行中：追加到当前批次
      _queue.addAll(cleaned);
      _batch.addAll(cleaned);
      return;
    }

    _batch
      ..clear()
      ..addAll(cleaned);
    _queue
      ..clear()
      ..addAll(cleaned);
    _aborted = false;
    _emitNext();
  }

  /// 把设备输出喂进来。
  void onOutput(String chunk) {
    if (_disposed || !isBusy) return;

    _buffer += chunk;
    if (_buffer.length > bufferLimit) {
      _buffer = _buffer.substring(_buffer.length - bufferLimit);
    }

    if (morePager.matchesTail(_buffer)) {
      // 翻页（spec §5.3）：立即回送一个空格继续。翻页动作不计入命令队列，
      // 不产生队列进度变化，也**不重置命令超时** —— 一条命令翻十页仍然
      // 只受一个 10s 超时约束。
      //
      // 去抖计时照常重置：翻页提示本身就是"新数据到达"。
      // 此刻缓冲区末尾仍是翻页提示，_checkPrompt 必须显式排除它，
      // 否则 `<--- More --->` 这类以 `>` 结尾的提示会被误判成命令结束。
      write(MorePager.continueKey);
      _events.add(const PagerContinued());
      _restartDebounce();
      return;
    }

    _restartDebounce();
  }

  /// 用户主动中止。不再发送队列中剩余的命令；已发出的那条不做处理
  /// （spec FR-E-13），因此它不计入 [QueueAborted.dropped]。
  void abort() {
    if (_disposed) return;
    final dropped = _queue.length;
    final hadCurrent = _current != null;
    if (dropped == 0 && !hadCurrent) return;

    _aborted = true;
    _cancelTimers();
    _queue.clear();
    _batch.clear();
    _current = null;
    _currentIndex = 0;
    _events.add(QueueAborted(dropped));
  }

  /// 连接断开。未发出的命令一律丢弃，**不自动重放**（spec FR-C-10）：
  /// 网络设备上重放配置下发可能造成重复配置。
  ///
  /// 与 [abort] 不同，在途的那条命令**计入**丢弃数 —— 它的输出已经永远
  /// 收不到了，用户需要知道这条命令的结果是未知的。
  void onDisconnected() {
    if (_disposed) return;
    final dropped = _queue.length + (_current != null ? 1 : 0);
    _cancelTimers();
    _queue.clear();
    _batch.clear();
    _current = null;
    _currentIndex = 0;
    if (dropped > 0) {
      _events.add(QueueDropped(dropped));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelTimers();
    _queue.clear();
    _batch.clear();
    _current = null;
    _currentIndex = 0;
    await _events.close();
  }

  void _emitNext() {
    if (_aborted || _queue.isEmpty) {
      _finish();
      return;
    }
    final cmd = _queue.removeAt(0);
    _current = cmd;
    _currentIndex = _batch.length - _queue.length;
    // 清空缓冲区：否则上一条命令残留的提示符会让本条瞬间"完成"
    _buffer = '';
    // 先起超时再写出：若注入的 write 同步抛异常，队列仍有超时兜底，
    // 不会永久卡在"忙"状态（spec 要求超时必须强制放行下一条）。
    _restartTimeout();
    write('$cmd$lineEnding');
    _events.add(CommandSent(cmd, _currentIndex, _batch.length));
  }

  void _restartDebounce() {
    _debounce?.cancel();
    _debounce = Timer(promptDebounce, _checkPrompt);
  }

  void _restartTimeout() {
    _timeout?.cancel();
    _timeout = Timer(commandTimeout, () {
      if (_current == null) return;
      final cmd = _current!;
      final index = _currentIndex;
      final total = _batch.length;
      _current = null;
      _currentIndex = 0;
      _cancelTimers();
      _events.add(
        CommandCompleted(cmd, timedOut: true, index: index, total: total),
      );
      _emitNext();
    });
  }

  void _checkPrompt() {
    if (_current == null) return;
    // 翻页提示不能当成提示符。`<--- More --->` 以 `>` 结尾，本来就能匹配
    // 默认提示符正则；若在此判定完成，下一条命令会被发进仍在翻页的设备，
    // 被它当作翻页按键吃掉 —— 命令看似已下发，实际从未执行。
    if (morePager.matchesTail(_buffer)) return;
    if (!promptDetector.matches(_buffer)) {
      // 没有提示符就继续等，由超时计时器兜底
      return;
    }
    _completeCurrent(timedOut: false);
  }

  void _completeCurrent({required bool timedOut}) {
    final cmd = _current!;
    final index = _currentIndex;
    final total = _batch.length;
    _current = null;
    _currentIndex = 0;
    _cancelTimers();
    _events.add(
      CommandCompleted(cmd, timedOut: timedOut, index: index, total: total),
    );
    _emitNext();
  }

  void _finish() {
    _cancelTimers();
    _currentIndex = 0;
    if (_batch.isNotEmpty) {
      _batch.clear();
      _events.add(const QueueFinished());
    }
  }

  void _cancelTimers() {
    _debounce?.cancel();
    _debounce = null;
    _timeout?.cancel();
    _timeout = null;
  }
}
