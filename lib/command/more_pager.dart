import '../render/ansi.dart';

/// 判定接收缓冲区末尾是否为设备的翻页提示。
///
/// 翻页提示通常**没有换行结尾** —— 设备会原地覆盖它。因此判定只看最后一
/// 行，且要求该行为非空。
class MorePager {
  MorePager({List<String>? patterns})
      : patterns = patterns ??
            const ['---- More ----', '--More--', '<--- More --->'];

  final List<String> patterns;

  /// 翻页时回送的内容。
  static const String continueKey = ' ';

  /// 缓冲区末尾是否为翻页提示。
  bool matchesTail(String buffer) {
    if (buffer.isEmpty) return false;
    final cleaned = stripAnsi(buffer);
    final idx = cleaned.lastIndexOf('\n');
    final tail = idx < 0 ? cleaned : cleaned.substring(idx + 1);
    final trimmed = tail.trim();
    if (trimmed.isEmpty) return false;
    return patterns.any((p) => trimmed.contains(p));
  }
}
