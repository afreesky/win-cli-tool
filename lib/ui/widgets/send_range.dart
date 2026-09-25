import 'package:flutter/services.dart';

/// 按 spec §5.1 算出这一次「发送」该下发哪些行。
///
/// 规则逐条（§5.1 原文）：
/// - 有非空选中 → 取选中范围**覆盖到的所有行**，某一行只要被覆盖到任意一个
///   字符就**整行**参与；
/// - 没有选中 → 取光标所在的那一行（光标视为落在该行内）；
/// - 顺序始终按编辑区**自上而下**，与拖拽方向无关；
/// - 过滤掉完全空白的行；结果为空则由调用方给轻提示。
///
/// **过滤规则必须与 `CommandDispatcher.enqueue` 逐字一致**（它自己也会
/// `trim()` 并丢弃空串）。两边不一致的后果不是"多发一条"，而是**判错**：
/// 本函数说"有内容要发"、dispatcher 清洗后全丢，用户既没看到命令发出、
/// 也没看到"没有可发送的命令"的提示。所以这里用同一个 `trim().isEmpty`。
///
/// **关于 FR-E-08 的逃生口**：原文说"确需发送空行时，在行内输入一个空格"，
/// 但 `enqueue` 的 `trim()` 会把 `' '` 变成 `''` 再丢掉，所以那个逃生口当前
/// **不成立**。本函数与 dispatcher 保持一致（也丢），不假装它成立 —— 修它要
/// 动已合并的命令层语义，见计划末尾的未决项。
///
/// 实现上它只是 [linesToSend] 的一层投影。**两个函数必须同源** —— 编辑区拿
/// [linesToSend] 去高亮"已发送的行"（FR-E-10），拿本函数去真正下发；各算各的
/// 会让高亮的行与实际发出去的行错位。
List<String> commandsToSend(String text, TextSelection selection) {
  final lines = text.split('\n');
  return linesToSend(text, selection)
      .map((index) => lines[index].trim())
      .toList(growable: false);
}

/// 这一次「发送」实际会下发**哪些行**（自上而下的行号）。
///
/// 空白行**不占行号**：它不会被发出去，编辑区也就不该把它标成"已发送"。
///
/// 规则与边界见 [commandsToSend] 的文档，两条用例组各自钉着同一批边界。
List<int> linesToSend(String text, TextSelection selection) {
  if (text.isEmpty) return const [];

  final lines = text.split('\n');

  // 每一行的起始字符偏移，长度 lines.length + 1。最后一项**恒为文本总长 + 1**
  // （最后一行并不真的有换行符，这一项却按有算了），而 `lineOf` 的搜索上界是
  // `lines.length - 1`，所以**它从不被读到**。留着只是让 `starts` 对每一行的
  // 起点都有定义 —— 别把它当成"文本总长"用。
  final starts = <int>[];
  var offset = 0;
  for (final line in lines) {
    starts.add(offset);
    offset += line.length + 1; // +1 是被 split 吃掉的 '\n'
  }
  starts.add(offset);

  /// 某个字符偏移落在第几行。用二分而不是逐行扫：编辑区可能有几千行。
  int lineOf(int position) {
    var low = 0;
    var high = lines.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (starts[mid] <= position) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  final int firstLine;
  final int lastLine;
  if (selection.isCollapsed) {
    // `TextSelection.start` / `.end` 已经把方向归一化了（start <= end），
    // 所以"拖拽方向无关"是**构造上**成立的，不需要额外的判断。
    firstLine = lineOf(selection.start);
    lastLine = firstLine;
  } else {
    firstLine = lineOf(selection.start);
    // 覆盖区间是 [start, end) —— 最后一个被覆盖的字符在 end - 1。
    // 用 end 而不是 end - 1 是个真实的错：选中范围正好停在下一行行首时，
    // 会把下一行整行拖进来。
    lastLine = lineOf(selection.end - 1);
  }

  return [
    for (var i = firstLine; i <= lastLine; i++)
      if (lines[i].trim().isNotEmpty) i,
  ];
}
