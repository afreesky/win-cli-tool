import 'package:flutter/material.dart';

import '../../render/ansi_parser.dart';

/// [AnsiColor] → Flutter 的 [Color]；`null` 给 `null`。
///
/// **`null` 不是"黑色"，是"没有指定"**——调用方据此用主题的前景色/背景色，
/// 这样深色主题下不带颜色的输出才是可读的。硬编码成黑白会让深色主题下的
/// 普通输出变成黑底黑字。
///
/// **换算本身一行都不在这里。** [AnsiColor.rgb] 是公开的，而且 `render/` 层的
/// 文档明写「换算放在这一层，不留给调用方」—— 16 色表、256 色的 6×6×6 立方与
/// 24 级灰阶都已经在那里实现、也已在那里被测。这里只是把那个三元组包成
/// Flutter 的 [Color]。
///
/// **别在这里加表或公式。** 那会制造第二个真相，而两处的差异不会有任何用例
/// 去发现 —— 本文件的第一版就是这样，把 4 号色抄成了 205（真实是 238）。
Color? ansiColorOf(AnsiColor? color) {
  if (color == null) return null;
  final (r, g, b) = color.rgb;
  return Color.fromARGB(255, r, g, b);
}

/// 反转视频时用的默认前景。取暗灰而不是纯黑：纯黑在很多主题里就是背景色，
/// 那会让反转后的文字与背景糊在一起。
const Color _kReverseFallbackForeground = Color(0xFF1E1E1E);

/// 反转视频时用的默认背景。取接近白而不是纯白，理由同上。
const Color _kReverseFallbackBackground = Color(0xFFE5E5E5);

/// 把一个 [AnsiSpan] 映射成 Flutter 的 [TextSpan]。
///
/// **无颜色的字段一律留 `null`**，让 `DefaultTextStyle` / 主题决定 —— 见
/// [ansiColorOf] 的说明。
TextSpan ansiSpanOf(AnsiSpan span) {
  final style = span.style;
  var foreground = ansiColorOf(style.foreground);
  var background = ansiColorOf(style.background);

  if (style.reverse) {
    // 反转是"交换"，而交换需要两边都有值才成立。缺哪边就补哪边的默认值，
    // 否则 `fg=红, bg=null` 反转后成了 `fg=null, bg=红` —— 前景落回主题色，
    // 看起来像是没反转。
    final fg = foreground ?? _kReverseFallbackForeground;
    final bg = background ?? _kReverseFallbackBackground;
    foreground = bg;
    background = fg;
  }

  return TextSpan(
    text: span.text,
    style: TextStyle(
      color: foreground,
      backgroundColor: background,
      fontWeight: style.bold ? FontWeight.bold : null,
      decoration: style.underline ? TextDecoration.underline : null,
    ),
  );
}

/// 把整个缓冲的行映射成一棵 [TextSpan] 树。
///
/// **行之间用 `\n` 连接**，行内的片段各自成节点 —— 这样一整块可以交给
/// 一个 `SelectableText.rich`，而**跨行拖选与复制**（FR-O-06）才能正常工作。
/// 每行一个独立的 `SelectableText` 会让选择被切成一段一段。
TextSpan ansiLinesToTextSpan(List<List<AnsiSpan>> lines) {
  final children = <TextSpan>[];
  for (var i = 0; i < lines.length; i++) {
    if (i > 0) children.add(const TextSpan(text: '\n'));
    for (final span in lines[i]) {
      children.add(ansiSpanOf(span));
    }
  }
  // **总是返回带 `children` 的节点，空的时候也不返回 `const TextSpan()`。**
  //
  // `TextSpan.children` 的类型是 `List<InlineSpan>?`，构造器直接存参、不做
  // "空表归一成 null" 的转换 —— 所以 `const TextSpan().children` 是 **null**，
  // 而不是空表。于是"空输入给得出一个空的 children"那条断言会在 `isEmpty` 上
  // 抛 `NoSuchMethodError`（该匹配器直接对值调 `.isEmpty`，不接受 null）。
  //
  // 两种写法渲染结果没有区别，但只有这一种能让那条断言成立。这不是迁就断言：
  // 那条断言要钉的是"空输入不吐出任何子节点"，而 `const TextSpan()` 恰好让它
  // 退化成一个匹配器内部的空指针错误 —— 断言表达不出它要说的话。
  return TextSpan(children: children);
}
