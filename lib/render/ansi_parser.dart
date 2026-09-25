/// SGR 颜色。三档：16 色、256 色索引、24 位真彩。
///
/// 声明为 `sealed`：计划 5 要按颜色算 Flutter 的 `Color`，穷尽的 switch 会让
/// "将来新增一档颜色"成为**编译错误**，而不是某个分支悄悄不着色。
sealed class AnsiColor {
  const AnsiColor();

  /// 渲染用的 24 位 RGB。
  ///
  /// **换算放在这一层，不留给调用方。** 256 色表的构成（前 16 色沿用基本色、
  /// 16–231 是 6×6×6 色立方、232–255 是 24 级灰阶）是 ANSI 的一部分，不是界面
  /// 的一部分；留出去就等于让"这一段算得对不对"没有测试可钉。
  (int, int, int) get rgb;
}

/// 前 16 色（SGR 30–37 / 90–97 / 40–47 / 100–107）。
final class AnsiBasic extends AnsiColor {
  const AnsiBasic(this.index) : assert(index >= 0 && index < 16);

  /// 0–7 是标准色，8–15 是亮色。
  final int index;

  @override
  (int, int, int) get rgb => _basicRgb[index];

  @override
  bool operator ==(Object other) => other is AnsiBasic && other.index == index;

  @override
  int get hashCode => index;

  @override
  String toString() => 'AnsiBasic($index)';
}

/// 256 色索引（SGR `38;5;n` / `48;5;n`）。
final class Ansi256 extends AnsiColor {
  const Ansi256(this.index) : assert(index >= 0 && index < 256);

  final int index;

  @override
  (int, int, int) get rgb {
    if (index < 16) return _basicRgb[index];
    if (index < 232) {
      // 6×6×6 色立方，每轴 6 级：0 与 55+40k（k=1..5）→ 0,95,135,175,215,255。
      final n = index - 16;
      int level(int v) => v == 0 ? 0 : 55 + v * 40;
      return (level(n ~/ 36), level((n ~/ 6) % 6), level(n % 6));
    }
    // 24 级灰阶：8, 18, …, 238。
    final gray = 8 + (index - 232) * 10;
    return (gray, gray, gray);
  }

  @override
  bool operator ==(Object other) => other is Ansi256 && other.index == index;

  @override
  int get hashCode => index;

  @override
  String toString() => 'Ansi256($index)';
}

/// 24 位真彩（SGR `38;2;r;g;b` / `48;2;r;g;b`）。
final class AnsiRgb extends AnsiColor {
  const AnsiRgb(this.r, this.g, this.b);

  final int r;
  final int g;
  final int b;

  @override
  (int, int, int) get rgb => (r, g, b);

  @override
  bool operator ==(Object other) =>
      other is AnsiRgb && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => 'AnsiRgb($r, $g, $b)';
}

/// 标准 xterm 的前 16 色。
const List<(int, int, int)> _basicRgb = [
  (0, 0, 0), // 0 黑
  (205, 0, 0), // 1 红
  (0, 205, 0), // 2 绿
  (205, 205, 0), // 3 黄
  (0, 0, 238), // 4 蓝
  (205, 0, 205), // 5 品红
  (0, 205, 205), // 6 青
  (229, 229, 229), // 7 白
  (127, 127, 127), // 8 亮黑（灰）
  (255, 0, 0), // 9 亮红
  (0, 255, 0), // 10 亮绿
  (255, 255, 0), // 11 亮黄
  (92, 92, 255), // 12 亮蓝
  (255, 0, 255), // 13 亮品红
  (0, 255, 255), // 14 亮青
  (255, 255, 255), // 15 亮白
];

/// 一段文本的显示样式。默认（[none]）表示不着色、不加粗。
class AnsiStyle {
  const AnsiStyle({
    this.foreground,
    this.background,
    this.bold = false,
    this.underline = false,
    this.reverse = false,
  });

  final AnsiColor? foreground;
  final AnsiColor? background;
  final bool bold;
  final bool underline;
  final bool reverse;

  static const AnsiStyle none = AnsiStyle();

  /// 与 `AppSettings.copyWith` 同一个 `_unset` 哨兵模式：`foreground` /
  /// `background` 是**可空**字段，用 `?? this.foreground` 就永远没法把它们设回
  /// null，而 SGR 39 / 49 恰恰就是"恢复默认色"。
  AnsiStyle copyWith({
    Object? foreground = _unset,
    Object? background = _unset,
    bool? bold,
    bool? underline,
    bool? reverse,
  }) =>
      AnsiStyle(
        foreground: identical(foreground, _unset)
            ? this.foreground
            : foreground as AnsiColor?,
        background: identical(background, _unset)
            ? this.background
            : background as AnsiColor?,
        bold: bold ?? this.bold,
        underline: underline ?? this.underline,
        reverse: reverse ?? this.reverse,
      );

  @override
  bool operator ==(Object other) =>
      other is AnsiStyle &&
      other.foreground == foreground &&
      other.background == background &&
      other.bold == bold &&
      other.underline == underline &&
      other.reverse == reverse;

  @override
  int get hashCode =>
      Object.hash(foreground, background, bold, underline, reverse);

  @override
  String toString() => 'AnsiStyle(fg: $foreground, bg: $background, '
      'bold: $bold, underline: $underline, reverse: $reverse)';
}

const Object _unset = Object();

/// 一段同样式的文本。计划 5 把它逐个映射成 Flutter 的 `TextSpan`。
class AnsiSpan {
  const AnsiSpan(this.text, this.style);

  final String text;
  final AnsiStyle style;

  @override
  bool operator ==(Object other) =>
      other is AnsiSpan && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);

  @override
  String toString() => 'AnsiSpan(${text.length} 字, $style)';
}

/// 把带控制序列的文本切成样式片段（FR-O-03）。
///
/// **输出区用它，日志用 [stripToPlainText]**（就是它的拼接），所以两者的
/// **规则**是同一套 —— §5.6 的「日志与输出区所见一致」不靠两边各自遵守约定。
///
/// **但"一致"有一个前提，别读成无条件的**：本函数**每次调用都是独立的**，
/// 不保留跨调用的解析状态。把一条控制序列从中间切开分两次调用，两边就会分道
/// 扬镳 —— 实测 `'\x1b['` + `'31mred'`：整段一次喂进去得到 `red`，分两次喂得到
/// `\x1b[31mred`（第二次只看到裸文本，前半个序列成了普通字符）。所以**调用方
/// 必须按同样的边界把同一段输入喂给两边**：计划 5 的输出区若要缓存半个序列才能
/// 正确渲染，日志就必须从**同一处缓冲**取文本，否则日志里会留下字面的控制序列
/// —— 那正是 §5.6 要防的。
///
/// 与 `lib/render/ansi.dart` 的 `stripAnsi`（命令层在用）有两处**已实测、
/// 刻意不改**的分叉，各有一条用例钉着：
///
/// 1. **不含 ESC 时 `stripAnsi` 不删 `\r`**（它的 `\r` 清理在提前返回之后），
///    这里一律删。现实输入会撞上，所以日志/输出区都走这里才干净。
/// 2. **退化输入里"删掉一条序列后新拼出一条"**：`stripAnsi` 是三次全串
///    `replaceAll` —— 先删 CSI 会让**原本配不上的**序列事后变成可匹配的，而
///    逐字符扫描一次到位，看不到这个先后关系。**别以为只有相邻 ESC 才算**：
///    实测 `'[\x1b]Z?\x1b[[\x07?'` 这边得 `[Z?<BEL>?`，`stripAnsi` 得 `[?`
///    （它先把 `\x1b[[` 当合法 CSI 删掉，剩下的 `ESC ] … BEL` 才拼成 OSC），
///    这条输入里两个 ESC 并不相邻；反过来 `'\x1b\x1b[31mx'` 这种相邻 ESC 的
///    **不**分叉。共同点是都属于畸形输入。
///
/// 另有一个**两边共有**的缺陷：`ESC ( B`（选择字符集，三字节）都不被剥离 ——
/// 它不属于两字节规则覆盖的范围。修它要动已冻结的 `ansi.dart`，本计划不改
/// （见计划末尾「本计划发现的既有问题」）。
AnsiParseResult parseAnsiChunk(String input, {AnsiStyle initial = AnsiStyle.none}) {
  final spans = <AnsiSpan>[];
  final buffer = StringBuffer();
  var style = initial;

  // 当前**还没定型**的那一段文本，以及它的样式。样式一变（或输入走完）才
  // 物化成 [AnsiSpan]。
  //
  // **别写回"每次 flush 时 `spans.last.text + text`"那个形状**：它只要"新片段
  // 与上一个同样式"就要把已经攒起来的那一大段**整个复制**一遍，于是**二次**。
  // 触发它的不是"有颜色"，恰恰是**样式没变**：设备每行吐一个**冗余**的
  // `\x1b[0m`（或重述同一个 `\x1b[1m`）时，整段输出会并成一个越来越长的片段，
  // 每次都重抄一遍。实测 256 KB：逐行冗余 `\x1b[0m` 70.3 ms → 5.5 ms（12.7×），
  // 逐行重述 `\x1b[1m` 67.0 ms → 7.1 ms（9.4×）；旧实现 8/64/256 KB 是
  // 0.66/8.2/70.3 ms —— 四倍数据涨十倍，形状本身就是二次的。样式**每行都换**
  // 的输入（`\x1b[32m…\x1b[0m`）两边一样快，因为那条路上本来就不合并。
  // [flush] 在每个输出块上都会走，这个差别到了界面上就是"卡一下"。
  final run = StringBuffer();
  var runStyle = initial;

  void emitRun() {
    if (run.isEmpty) return;
    spans.add(AnsiSpan(run.toString(), runStyle));
    run.clear();
  }

  void flush() {
    if (buffer.isEmpty) return;
    final text = buffer.toString();
    buffer.clear();
    // 相邻同样式合并。`a\x1b[0mb` 必须是一个片段：不合并的话每个 SGR 边界
    // 都会切一刀，计划 5 的 TextSpan 会碎成一地，而且"样式没变"这件事在
    // 结果里看不出来。
    if (runStyle != style) emitRun();
    runStyle = style;
    run.write(text);
  }

  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch != '\x1b') {
      // `\r` 丢掉，与 stripAnsi 一致。**已知代价**：设备用 `\r` 重画进度行时
      // 这里会把两次内容首尾相接显示，而不是只留最后一次 —— 与 stripAnsi 同样
      // 的取舍，让两条路径一致比单方面"更对"更重要。
      if (ch != '\r') buffer.write(ch);
      i++;
      continue;
    }

    // **优先级顺序是承重的**：先试 CSI，再试 OSC，再试两字节，最后才把 ESC
    // 当普通字符。顺序错了 `\x1b]0;未终止` 这类输入就会与 stripAnsi 分道扬镳
    // （stripAnsi 的两字节规则会吃掉 `\x1b]`）。
    if (i + 1 < input.length && input[i + 1] == '[') {
      final csi = _matchCsi(input, i);
      if (csi != null) {
        final (paramEnd, finalAt) = csi;
        if (input[finalAt] == 'm') {
          flush();
          style = _applySgr(style, input.substring(i + 2, paramEnd));
        }
        i = finalAt + 1;
        continue;
      }
    } else if (i + 1 < input.length && input[i + 1] == ']') {
      final afterOsc = _matchOsc(input, i);
      if (afterOsc != null) {
        i = afterOsc;
        continue;
      }
    }

    if (i + 1 < input.length && _isTwoByteFinal(input.codeUnitAt(i + 1))) {
      i += 2;
      continue;
    }

    // 什么都不匹配：ESC 就是普通字符，原样留下（stripAnsi 也会留下它）。
    buffer.write('\x1b');
    i++;
  }

  flush();
  emitRun();
  return AnsiParseResult(spans, style);
}

/// [parseAnsiChunk] 的结果，多带一个**块末样式**。
///
/// 流式调用方（输出缓冲）必须把 [finalStyle] 接给下一块，否则 `'\x1b[32m'`
/// 与紧随其后的文本分属两块时颜色会丢。
class AnsiParseResult {
  const AnsiParseResult(this.spans, this.finalStyle);

  final List<AnsiSpan> spans;

  /// 输入走完时的当前样式。
  ///
  /// **它与 `spans.last.style` 不是一回事**：输入以 `'\x1b[32m'` 结尾时
  /// `spans` 是空的，而样式已经是绿的。照 `spans.last` 取会丢掉末尾那次换色。
  final AnsiStyle finalStyle;
}

/// 剥离控制符之外什么都不做，返回样式片段。
///
/// 等同于 `parseAnsiChunk(input, initial: initial).spans` —— 保留这个名字是因为
/// 一次性调用的地方（日志、测试）读起来更直接，且它保证了 [stripToPlainText]
/// 与 `parseAnsi` 走的是同一条实现路径。
List<AnsiSpan> parseAnsi(String input, {AnsiStyle initial = AnsiStyle.none}) =>
    parseAnsiChunk(input, initial: initial).spans;

/// 一条不完整的控制序列最多可能有多长。
///
/// 超过它就不再往回找：一段永远等不到后半截的畸形字节不该把输出区**永久**卡住。
/// 64 远大于现实里任何一条序列（CSI 参数很少超过 20 字符）。
const int kMaxAnsiHoldBack = 64;

/// [input] 的末尾有多少个字符必须**留在缓冲里**等下一块 —— 因为从某个 `\x1b`
/// 开始的控制序列可能还没收完。
///
/// 存在的理由只有一个，见 [parseAnsiChunk] 上面那段前提：解析**每次调用独立**，
/// 把 `'\x1b['` 与 `'31mred'` 分两次喂，前半个序列会退化成字面文本。输出区要
/// 正确渲染就得留住它，而日志要与输出区一致就得从**同一处缓冲**取文本 —— 所以
/// 这个判断属于"两边共用的那处缓冲"，不属于渲染。
///
/// **只看最后一个 `\x1b`。** 控制序列之间不会嵌套（OSC 的 ST 终止符 `ESC \`
/// 自己就是一条完整的两字节序列），所以更早的 ESC 若已经收完，就不可能被末尾的
/// 半条影响。
///
/// **返回 0 是常态**：输入里没有控制序列，或末尾那条已经完整。
int ansiHoldBackLength(String input) {
  final lowerBound = input.length - kMaxAnsiHoldBack;
  for (var i = input.length - 1; i >= 0 && i >= lowerBound; i--) {
    if (input.codeUnitAt(i) != 0x1b) continue;
    return _isCompleteSequenceAt(input, i) ? 0 : input.length - i;
  }
  return 0;
}

/// 从 [i] 处的 `\x1b` 起，后续输入**还能不能**改变它的含义 —— 不能就是"已经完整"。
///
/// 判据直接照抄 `parseAnsiChunk` 的优先级顺序（`:265-294`）：ESC 处的判定**只**
/// 取决于下一个字符。所以三种情况：下一个字符是 `[` / `]` 时序列可能还没收完
/// （要 `_matchCsi` / `_matchOsc` 说有才算完）；其余情况**此刻已经定死**，
/// 后续输入改不了它 —— 包括"ESC 被当普通字符留下"这种结局。
bool _isCompleteSequenceAt(String input, int i) {
  final next = i + 1;
  if (next >= input.length) {
    // 末尾裸露的 ESC：解析器**确实**会把它当普通字符留下，但下一块一来它就可能
    // 变成序列的开头 —— 含义**还能**变，所以是"不完整"。留 1 个字符。
    return false;
  }
  if (input.codeUnitAt(next) == 0x5b /* [ */) {
    return _matchCsi(input, i) != null;
  }
  if (input.codeUnitAt(next) == 0x5d /* ] */) {
    return _matchOsc(input, i) != null;
  }
  // 走到这里说明下一个字符既不是 `[` 也不是 `]`。解析器在 ESC 处的判定**只**取决于
  // 下一个字符（优先级顺序：CSI、OSC、两字节、最后才把 ESC 当普通字符），所以此刻
  // **已经定死**，后续输入改不了它 —— 于是"完整"。
  //
  // 原先这里问的是 `_isTwoByteFinal(...)`，那是错的：`\x1b(` 后面跟普通字符时它判
  // "不完整"，于是把已经定死的字面文本一直扣在缓冲里 —— 设备此后不再发数据的话，
  // 那段文本要等缓冲涨过 kMaxAnsiHoldBack 才放行，在此之前**不显示**。
  return true;
}

/// 剥离控制符，只留文本。**日志用它，输出区用 [parseAnsi]** —— 两条路径共用
/// 一套规则，§5.6 的「与输出区所见一致」因此不靠约定维持。
///
/// 与 [parseAnsi] 一样**每次调用独立**：跨调用被切成两半的控制序列会退化成
/// 字面文本（见 [parseAnsi] 的说明）。要一致，就得**按同样的边界喂**。
String stripToPlainText(String input) =>
    parseAnsi(input).map((span) => span.text).join();

/// 从 `\x1b`（位置 [i]）起匹配一条 CSI，返回 `(参数结束位置, 终止字节位置)`。
/// 字符范围与 `ansi.dart` 的 `_csi` 逐段对应。
(int, int)? _matchCsi(String input, int i) {
  var j = i + 2;
  while (j < input.length && _isCsiParam(input.codeUnitAt(j))) {
    j++;
  }
  final paramEnd = j;
  while (j < input.length && _isCsiIntermediate(input.codeUnitAt(j))) {
    j++;
  }
  if (j >= input.length) return null; // 没有终止字节 = 不成立
  if (!_isCsiFinal(input.codeUnitAt(j))) return null;
  return (paramEnd, j);
}

/// 从 `\x1b]`（位置 [i]）起匹配一条 OSC，返回**终止符之后**的位置；不成立返回
/// null（终止符是 BEL，或 ST 的 `\x1b\`）。
int? _matchOsc(String input, int i) {
  var j = i + 2;
  while (j < input.length && input[j] != '\x07' && input[j] != '\x1b') {
    j++;
  }
  if (j >= input.length) return null;
  if (input[j] == '\x07') return j + 1;
  if (j + 1 < input.length && input[j + 1] == '\\') return j + 2;
  return null;
}

bool _isCsiParam(int c) =>
    (c >= 0x30 && c <= 0x39) || c == 0x3B || c == 0x3F;

bool _isCsiIntermediate(int c) => c >= 0x20 && c <= 0x2F;

bool _isCsiFinal(int c) => c >= 0x40 && c <= 0x7E;

/// `stripAnsi` 的两字节规则：ESC + `@-Z` 或 `\]^_`。
/// **`[` 与 `]` 的分工不是笔误**：`[`(0x5B) 被排除是因为它由 CSI 分支负责，
/// `]`(0x5D) 在 `\]^_` 里 —— 所以 OSC 匹配失败时会退到这一支吃掉 `\x1b]`。
bool _isTwoByteFinal(int c) =>
    (c >= 0x40 && c <= 0x5A) || (c >= 0x5C && c <= 0x5F);

AnsiStyle _applySgr(AnsiStyle style, String params) {
  // `ESC[m` 与 `ESC[0m` 等价：空参数就是 0。
  if (params.isEmpty) return AnsiStyle.none;

  final parts = params.split(';');
  var i = 0;
  while (i < parts.length) {
    final part = parts[i];
    // 空串是 0（ANSI 如此，`ESC[;31m` 的第一个参数就是 0）；
    // **但解析不出来的数字参数要忽略，不能当 0** —— 当 0 就是一次意外的
    // 全样式清空，而那个数字很可能只是设备吐出的垃圾。
    final int? code = part.isEmpty ? 0 : int.tryParse(part);
    if (code == null) {
      i++;
      continue;
    }

    if (code == 0) {
      style = AnsiStyle.none;
    } else if (code == 1) {
      style = style.copyWith(bold: true);
    } else if (code == 4) {
      style = style.copyWith(underline: true);
    } else if (code == 7) {
      style = style.copyWith(reverse: true);
    } else if (code == 22) {
      style = style.copyWith(bold: false);
    } else if (code == 24) {
      style = style.copyWith(underline: false);
    } else if (code == 27) {
      style = style.copyWith(reverse: false);
    } else if (code == 39) {
      style = style.copyWith(foreground: null);
    } else if (code == 49) {
      style = style.copyWith(background: null);
    } else if (code >= 30 && code <= 37) {
      style = style.copyWith(foreground: AnsiBasic(code - 30));
    } else if (code >= 40 && code <= 47) {
      style = style.copyWith(background: AnsiBasic(code - 40));
    } else if (code >= 90 && code <= 97) {
      style = style.copyWith(foreground: AnsiBasic(code - 90 + 8));
    } else if (code >= 100 && code <= 107) {
      style = style.copyWith(background: AnsiBasic(code - 100 + 8));
    } else if (code == 38 || code == 48) {
      final extended = _readExtendedColor(parts, i + 1);
      if (extended == null) {
        // 写残了（截断、越界）。**丢掉这条 SGR 剩下的部分**，不去猜后面的
        // 数字属于谁 —— 猜错就是把一个随机数字当成颜色。
        return style;
      }
      style = code == 38
          ? style.copyWith(foreground: extended.color)
          : style.copyWith(background: extended.color);
      i = extended.next;
      continue;
    }
    // 其余（字体、闪烁、隐藏…）V1 不支持，**静默忽略**：它们只影响外观，
    // 忽略的代价是少一种装饰；而在这里抛异常会让一条设备输出把整个输出区搞挂。
    i++;
  }
  return style;
}

/// 读 `38`/`48` 之后的扩展颜色，返回 `(颜色, 下一个待处理参数下标)`。
({AnsiColor color, int next})? _readExtendedColor(List<String> parts, int start) {
  if (start >= parts.length) return null;
  final mode = int.tryParse(parts[start]);
  if (mode == 5) {
    if (start + 1 >= parts.length) return null;
    final n = int.tryParse(parts[start + 1]);
    if (n == null || n < 0 || n > 255) return null;
    return (color: Ansi256(n), next: start + 2);
  }
  if (mode == 2) {
    if (start + 3 >= parts.length) return null;
    final r = int.tryParse(parts[start + 1]);
    final g = int.tryParse(parts[start + 2]);
    final b = int.tryParse(parts[start + 3]);
    bool inByte(int? v) => v != null && v >= 0 && v <= 255;
    if (!inByte(r) || !inByte(g) || !inByte(b)) return null;
    return (color: AnsiRgb(r!, g!, b!), next: start + 4);
  }
  return null;
}
