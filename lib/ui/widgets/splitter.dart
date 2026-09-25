import 'package:flutter/material.dart';

/// 可拖拽分隔条（§7.3）。
///
/// **它只上报"新的比例"，不自己存。** 比例的真相在 `AppSettings.editorSplitRatio`
/// 里，存两份必然有一份会旧。
class Splitter extends StatelessWidget {
  const Splitter({
    super.key,
    required this.axis,
    required this.onDrag,
    this.onDragEnd,
    this.thickness = 6,
  });

  /// 分隔条的走向。**纵向**分隔条（左右分栏之间）用 [Axis.vertical]。
  final Axis axis;

  /// 拖动时回调：参数是**沿拖动方向的像素增量**。
  final void Function(double delta) onDrag;

  /// 松手时回调。**落盘要挂在这里，不要挂在 [onDrag] 上** —— 理由见
  /// `main_window.dart` 里 `_draggingWidth` 的文档。
  final VoidCallback? onDragEnd;

  final double thickness;

  @override
  Widget build(BuildContext context) {
    final cursor = axis == Axis.vertical
        ? SystemMouseCursors.resizeColumn
        : SystemMouseCursors.resizeRow;
    return MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: axis == Axis.vertical
            ? (d) => onDrag(d.delta.dx)
            : null,
        onVerticalDragUpdate: axis == Axis.horizontal
            ? (d) => onDrag(d.delta.dy)
            : null,
        onHorizontalDragEnd: axis == Axis.vertical
            ? (_) => onDragEnd?.call()
            : null,
        onVerticalDragEnd: axis == Axis.horizontal
            ? (_) => onDragEnd?.call()
            : null,
        child: SizedBox(
          width: axis == Axis.vertical ? thickness : null,
          height: axis == Axis.horizontal ? thickness : null,
          child: Center(
            child: Container(
              width: axis == Axis.vertical ? 1 : null,
              height: axis == Axis.horizontal ? 1 : null,
              color: Theme.of(context).dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}
