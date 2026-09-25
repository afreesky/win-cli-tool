import 'package:flutter/material.dart';

/// 会**把已发送的行标暗**的编辑控制器（FR-E-10）。
///
/// 覆写 [buildTextSpan] 而不是在编辑区上叠一层自绘：`TextField` 只认控制器给出
/// 的 span，另起一层就得自己同步滚动位置、字体度量、光标位置 —— 那三样
/// 任何一样错了都会让高亮和文字错位。
class SentLineController extends TextEditingController {
  /// 已发送的**行号**（0 起）。发送时由 `linesToSend` 给出的那批。
  final Set<int> sentLines = <int>{};

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // **组字期间一律交回父类。** 父类会把组字区间加上下划线，而中文输入法的
    // 候选窗要靠那段下划线定位。自己拼 span 会让组字提示消失 —— 本应用的
    // 用户要输中文设备名与中文命令，这不是边角情况。
    if (withComposing && !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    if (sentLines.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final dimmed = (style ?? const TextStyle()).copyWith(
      color: Theme.of(context).disabledColor,
    );

    final children = <TextSpan>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) children.add(const TextSpan(text: '\n'));
      children.add(
        TextSpan(text: lines[i], style: sentLines.contains(i) ? dimmed : null),
      );
    }
    return TextSpan(style: style, children: children);
  }
}
