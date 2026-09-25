import 'package:flutter/widgets.dart';

/// 输出区的"跟着最新一行走"（FR-O-04）。
///
/// 规则：默认贴底；用户自己滚离底部就**停止**跟底（他在读上面的行，新输出不该
/// 把他拽走）；用户滚回底部就恢复；另有 [jumpToBottom] 给"回到底部"按钮用。
///
/// **抽成独立的类而不是面板的私有方法，是为了可测。** 判别力完全取决于滚动
/// 位置，而面板里那块是 `SelectableText.rich` —— 它自带选择手势，用
/// `tester.drag` 去驱动得到的结果可能是手势竞争的产物。这里不碰任何手势：
/// 调用方（面板）从滚动通知里调 [onUserScroll]，从刷新回调里调
/// [onContentChanged]。
class AutoScroll {
  AutoScroll({required this.controller, this.slack = 4});

  final ScrollController controller;

  /// 距底部多少像素以内还算"贴底"。浮点误差会让"正好滚到底"差那么零点几，
  /// 不留余量的话用户手动滚到底也恢复不了跟底。
  final double slack;

  bool _stick = true;

  /// 当前是否跟着最新一行走。面板据此决定要不要显示"回到底部"按钮。
  bool get stickToBottom => _stick;

  /// 用户自己滚动了 —— 据**当前**位置重新判定。
  ///
  /// **只在用户驱动的滚动里调**。若在程序化的跟底滚动里也调，跟底那一跳会
  /// 先把它自己判成"贴底"（结论相同），但内容刚变长、还没跳的那一瞬间会被
  /// 判成"离底"从而永久停跟 —— 那正是这个类要避免的。
  void onUserScroll() {
    if (!controller.hasClients) return;
    _stick = controller.position.extentAfter <= slack;
  }

  /// 内容变长了 —— 若还贴着底就跟到底。
  ///
  /// **必须在内容**布局完之后**调**（面板里是 `addPostFrameCallback`）：
  /// 早一帧的话 `maxScrollExtent` 还是旧值，跳过去就停在倒数第二屏。
  void onContentChanged() {
    if (!_stick) return;
    if (!controller.hasClients) return;
    controller.jumpTo(controller.position.maxScrollExtent);
  }

  /// 主动回到底部（"回到底部"按钮 / 清屏之后）。
  void jumpToBottom() {
    _stick = true;
    if (!controller.hasClients) return;
    controller.jumpTo(controller.position.maxScrollExtent);
  }
}
