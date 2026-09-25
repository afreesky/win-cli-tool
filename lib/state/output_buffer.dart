import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../render/ansi_parser.dart';

/// 一台设备的输出缓冲：把流式到达的块攒成**按行分组**的样式片段。
///
/// **它是这条流唯一的消费者。** 输出区要的样式片段与日志要的纯文本都从这里
/// 出来 —— 见 [parseAnsiChunk] 的前提：解析每次调用独立，一条控制序列被切开
/// 分两次喂就会退化成字面文本。两处各攒各的缓冲，就必然有一处（或两处）踩上；
/// 从同一处取则**构造上**不可能不一致，§5.6 因此不靠约定维持。
///
/// 生命周期：活得比一次会话长。FR-O-09 要求切换设备后切回来还能看到完整的输出，
/// 而 `ConnectionManager` 会在重连时换掉整个会话 —— 所以它由状态层持有，
/// 会话只往里灌数据。
///
/// **它同时是个 [ChangeNotifier]**：界面靠它知道"该重绘了"。这是 5a 有意留下的
/// 接缝 —— provider 返回的是本对象，`buffer.add(...)` 不会让任何 provider 失效，
/// 界面若没有这条通知就只能轮询。
///
/// **通知是"变了"，不是"可以重绘了"。** NFR-F-02 要求输出渲染节流到约 60ms
/// 一次，而这里**每次喂进都通知**（设备可以 200 行/秒地吐，见 NFR-F-03）——
/// 节流是订阅方的事，见 `lib/ui/widgets/refresh_throttle.dart`。把节流做进本类
/// 会让它拥有一个定时器，而 `clear()` / `addMarker()` 这种**用户操作**必须即时
/// 生效，两者混在一起会把"谁负责及时"搞乱。
///
/// **本类不 `dispose()`。** 它由 `outputBufferProvider` 持有，那个 provider 不是
/// `autoDispose`（缓冲要活得和容器一样久），所以 `ref.onDispose` 只在容器整体
/// 销毁时才跑 —— 而那时 `SessionController` 可能仍持有它。不加 `dispose` 的代价
/// 是进程退出时留下几十字节的监听者列表，收益是不去赌两条销毁路径的先后。
class OutputBuffer extends ChangeNotifier {
  OutputBuffer({required this.maxLines});

  /// 保留的最大行数（FR-O-07，取 `AppSettings.outputBufferLines`，默认 5000）。
  final int maxLines;

  /// 已定型的行为单位。**最后一项是正在累积的那一行**（可能为空）。
  final List<List<AnsiSpan>> _lines = [<AnsiSpan>[]];

  /// 还没能定型的尾巴 —— 可能是一条半的控制序列。
  String _pending = '';

  /// 块末样式。必须跨块延续，否则 `'\x1b[32m'` 与紧随其后的文本分属两块时
  /// 颜色会丢（那时 `spans` 是空的，`spans.last.style` 给不出任何东西）。
  AnsiStyle _style = AnsiStyle.none;

  /// 每喂进一段**完整**文本时回调一次，参数与喂给 [parseAnsiChunk] 的**逐字
  /// 相同**。日志挂在这里，于是"日志与输出区所见一致"不是约定而是同一份入参。
  ///
  /// **每次会话开始时换上新的、结束时置空** —— 日志是"一次会话一个实例"
  /// （`LogWriter` 的文档），而本缓冲活得比一次会话长。置空期间攒下的输出
  /// 不会进日志，这是有意的：那段时间本来就没有会话在写日志。
  void Function(String text)? onText;

  /// 当前所有行（含未完成的那一行）。**是活视图**：不要改它，也不要长期持有。
  List<List<AnsiSpan>> get lines => UnmodifiableListView(_lines);

  /// 喂进一块。块边界**不必**与任何东西对齐 —— 半条控制序列会被留住。
  void add(String chunk) {
    if (chunk.isEmpty) return;
    final input = _pending + chunk;
    // 留住的尾巴**不喂给日志**，于是两边的边界逐字相同（见类的说明）。
    final hold = ansiHoldBackLength(input);
    final complete = input.substring(0, input.length - hold);
    _pending = input.substring(input.length - hold);
    if (complete.isEmpty) return;
    _consume(complete);
    notifyListeners();
  }

  /// 放出残留的尾巴。会话结束/断开时调用。
  ///
  /// 残留多半是一条永远等不到后半截的畸形序列，按字面文本处理 —— 与
  /// [parseAnsi] 对它的处置一致。
  void flush() {
    final rest = _pending;
    if (rest.isEmpty) return;
    _pending = '';
    _consume(rest);
    notifyListeners();
  }

  /// 往输出区插一段**不由会话产生**的文本（断开/重连标记、命令超时告警行）。
  ///
  /// **不回调 [onText]。** 那是有意的：日志有它自己的一组标记
  /// （`LogWriter.disconnected()` / `reconnected()`，§5.6 逐字规定），
  /// 两处的内容本就不同，让这些标记也进日志会把 §5.6 的格式弄脏。
  ///
  /// 标记自占一行：接在未完成的那一行后面会让人以为它是设备输出。
  void addMarker(String text, {AnsiStyle style = AnsiStyle.none}) {
    // 当前那一行**还是空的就写在它上面**：设备的输出常常以换行结束（此刻光标
    // 正停在一个空行的开头），无条件另起一行会在每次断开时都多插一个空行。
    // 反过来，半行输出后面直接接标记会让人以为标记也是设备输出 —— 所以非空时
    // 才另起一行。
    if (_lines.last.isNotEmpty) _lines.add(<AnsiSpan>[]);
    _lines.last.add(AnsiSpan(text, style));
    // 标记之后另起一行，后续输出不会接在它后面。
    _lines.add(<AnsiSpan>[]);
    _trim();
    notifyListeners();
  }

  /// 清屏（FR-O-05）：**只清显示内容**。
  ///
  /// **不清 [_pending] 与 [_style]。** 清屏时流还在继续，丢掉半条序列会让紧随
  /// 其后的那半截变成字面文本，丢掉样式会让后续文本用错颜色 —— 这两样都是
  /// **解析状态**，不是"显示内容"。也不动日志（`onText` 根本不被调用）。
  void clear() {
    _lines
      ..clear()
      ..add(<AnsiSpan>[]);
    notifyListeners();
  }

  void _consume(String complete) {
    final result = parseAnsiChunk(complete, initial: _style);
    _style = result.finalStyle;
    _append(result.spans);
    // 顺序是承重的：先让**这一次**的片段落进缓冲，再通知日志。反过来的话，
    // 日志里出现的一行在输出区还看不到，两者会出现一帧的错位。
    onText?.call(complete);
  }

  void _append(List<AnsiSpan> spans) {
    for (final span in spans) {
      final parts = span.text.split('\n');
      for (var i = 0; i < parts.length; i++) {
        // 第一个分段接在当前行后面，其后每段都意味着"上一条换行符到了"。
        if (i > 0) _lines.add(<AnsiSpan>[]);
        if (parts[i].isNotEmpty) {
          _lines.last.add(AnsiSpan(parts[i], span.style));
        }
      }
    }
    _trim();
  }

  void _trim() {
    // **`maxLines + 1` 里的那个 +1 是 [_lines] 的形状带来的，不是笔误。**
    // `_lines.last` 永远是"正在累积、可能还是空的那一行"，所以它**不算**一行输出。
    // 只留 `maxLines` 个元素的话，用户把上限设成 5000 实际只看到 4999 行完整输出
    // —— 差一行不致命，但它是那种"看着像对的"错。
    //
    // 下限兜到 2（=1 行输出 + 那一行在途）：`maxLines` 是设置里的值，用户把它
    // 写成 0 或负数不该让 `_lines` 空掉、下一次 `add` 直接抛。
    final keep = maxLines < 1 ? 2 : maxLines + 1;
    if (_lines.length > keep) {
      _lines.removeRange(0, _lines.length - keep);
    }
  }
}
