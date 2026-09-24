import '../render/ansi.dart';

/// 判定接收缓冲区末尾是否出现了设备提示符。
///
/// 判定规则（spec §5.2）：取缓冲区中**最后一个非空行**（去掉行尾空白后），
/// 用正则匹配它。只看最后一行是关键 —— 否则设备回显里任何以 `>` 或 `]`
/// 结尾的内容行都会造成误判。
///
/// 单靠本类无法完全消除误判（例如输出行 `... is up [OK]`）。真正的防线是
/// `CommandDispatcher` 的静默去抖：匹配到之后还要等数据停住才算数。
class PromptDetector {
  PromptDetector({RegExp? pattern}) : pattern = pattern ?? defaultPattern;

  /// 覆盖华为 VRP、Cisco IOS、H3C 等主流形态的默认正则。
  static final RegExp defaultPattern = RegExp(r'[>#\]]\s*$');

  final RegExp pattern;

  /// 缓冲区末尾是否为提示符。
  bool matches(String buffer) {
    final line = lastNonEmptyLine(buffer);
    if (line == null) return false;
    return pattern.hasMatch(line);
  }

  /// 取出缓冲区里最后一个非空行（已剥离 ANSI、已去掉首尾空白）。
  ///
  /// 返回 null 表示缓冲区里没有非空内容。
  static String? lastNonEmptyLine(String buffer) {
    final cleaned = stripAnsi(buffer);
    final lines = cleaned.split('\n');
    for (var i = lines.length - 1; i >= 0; i--) {
      final trimmed = lines[i].trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }
}
