import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/host_key_prompt.dart';
import '../dialogs/host_key_dialog.dart';

/// 把 [hostKeyPromptProvider] 的询问变成对话框的宿主。
///
/// 它包在 `MainWindow` **外面**（`app.dart` 的 `home:`），因为询问来自会话层
/// （`SessionFactory` 的 `onUnknownHostKey`），而那时界面可能还没有任何
/// 与设备相关的部件挂在树上。
class HostKeyPromptHost extends ConsumerStatefulWidget {
  const HostKeyPromptHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<HostKeyPromptHost> createState() => _HostKeyPromptHostState();
}

class _HostKeyPromptHostState extends ConsumerState<HostKeyPromptHost> {
  /// 已经有一个对话框开着了。**不能靠 `state != null` 判** —— 队列里还有
  /// 第二个的时候 `state` 也不为 null，而那时不该再开一个。
  var _showing = false;

  @override
  void initState() {
    super.initState();
    // **riverpod 3.x 的 `ref.listen` 没有 `fireImmediately`。** 带这个开关的
    // 是 `ref.listenManual`，而它的文档点明了两个用法：`initState` 这类生命
    // 周期，以及"弹模态" —— 本部件两个都占（它 `addPostFrameCallback` 里
    // `showDialog`）。计划里写的是 `ref.listen(..., fireImmediately: true)`，
    // 那个签名在 3.4.3 上不存在；这里只换 API，下面的监听体与意图一字未动。
    ref.listenManual(hostKeyPromptProvider, (previous, next) {
      // `fireImmediately` 是为了"本部件挂载时就已经有一个在等"这种时序
      // （`ask` 发生在建连那一刻，可能早于本部件的第一帧）。
      if (next == null || _showing) return;
      _showing = true;
      // **不能在这个回调里直接 `showDialog`。** 监听回调发生在 provider
      // 刷新的过程中，此刻 `Navigator` 正在构建这一帧；在这里 push 一个路由
      // 会拿到 "setState() or markNeedsBuild() called during build"。
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final accepted = await showHostKeyDialog(context, next.host);
        _showing = false;
        if (!mounted) return;
        // **`next` 而不是"当前 state"** —— 用户回答的就是它。
        // `reply` 内部还会再核对一次身份（见它的文档）。
        ref.read(hostKeyPromptProvider.notifier).reply(next, accepted);
      });
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
