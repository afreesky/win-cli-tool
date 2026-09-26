import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../state/providers.dart';
import 'panels/device_list_panel.dart';
import 'panels/editor_panel.dart';
import 'panels/output_panel.dart';
import 'panels/snippet_drawer.dart';
import 'widgets/splitter.dart';

/// 主窗口（§7.1）：工具栏 + 左侧设备列表 + 右上编辑区 + 右下输出区。
///
/// **它是唯一持有那两把 `GlobalKey` 的地方**，因为窗口级的快捷键（§4.8）要
/// 调到编辑区的"发送"与输出区的"清屏" —— 那两个动作的状态在各自的 State 里。
/// 把动作上提到 provider 也能做，但那样 `TextEditingController` 与滚动位置
/// 也跟着上提，得不偿失。
class MainWindow extends ConsumerStatefulWidget {
  const MainWindow({super.key});

  @override
  ConsumerState<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends ConsumerState<MainWindow> {
  final _editorKey = GlobalKey<EditorPanelState>();
  final _outputKey = GlobalKey<OutputPanelState>();

  static const double _minPane = 160;

  /// 拖动中的临时宽度／比例（null = 没在拖）。
  ///
  /// **拖动过程里不写 settings。** 每次 `onDragUpdate` 都写一趟的话：
  /// （一）那条链里有 `chmod` —— 一个**进程** —— 60Hz 的拖动就是每秒起 60 个；
  /// （二）两次写会重叠，而 `writeFileAtomically` 是先写同目录 `.tmp` 再 rename，
  /// 重叠时先完成的那次把 `.tmp` 挪走了，后一次的 rename 就红在
  /// `Cannot rename file .../settings.json.tmp (errno = 2)`。这两条都是实测的：
  /// `tester.drag(Offset(0, 60))` 一次就被 touch slop 拆成 20 + 40 两段，
  /// 于是两条写同时上路，那条测试红在 PathNotFoundException 上。
  ///
  /// 所以拖动期间只动本地状态（界面照样实时跟手），松手才落盘一次。
  double? _draggingWidth;
  double? _draggingRatio;

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider);
    final selected = ref.watch(selectedDeviceProvider);
    final settings = ref.watch(settingsProvider);

    // **过期的选中在这里被挡掉。** 删掉一台设备之后 `selected` 可能还指着它，
    // 而 `sessionProvider(那个 id)` 会去设备列表里 `firstWhere` 并抛。挡在这一处，
    // 两个面板与快捷键就都不用各自防一遍。
    final active = devices.any((d) => d.id == selected) ? selected : null;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): _clearOutput,
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true): _clearOutput,
        const SingleActivator(LogicalKeyboardKey.escape): _abort,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _addDevice,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _addDevice,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('网络设备命令行工具'),
            actions: [
              IconButton(
                tooltip: '添加设备',
                icon: const Icon(Icons.add),
                onPressed: _addDevice,
              ),
            ],
          ),
          // 命令库抽屉（FR-S-01…04）。**没有选中设备时不给抽屉** —— 片段归属
          // 设备，一个不知道属于谁的抽屉没有意义。
          endDrawer: active == null
              ? null
              : SnippetDrawer(deviceId: active, onInsert: _insertSnippet),
          body: active == null ? _empty() : _body(active, settings),
        ),
      ),
    );
  }

  Widget _empty() => const Center(child: Text('请先添加一台设备'));

  Widget _body(String deviceId, AppSettings settings) {
    final width = _draggingWidth ?? settings.deviceListWidth;

    return Row(
      children: [
        SizedBox(
          width: width,
          child: DeviceListPanel(),
        ),
        // 设备列表与右侧之间的分隔条改动的是列表宽度。
        Splitter(
          key: const ValueKey('splitter-v'),
          axis: Axis.vertical,
          onDrag: (delta) {
            final base = _draggingWidth ?? settings.deviceListWidth;
            setState(() => _draggingWidth = (base + delta).clamp(_minPane, 480.0));
          },
          onDragEnd: () {
            final next = _draggingWidth;
            if (next == null || next == settings.deviceListWidth) {
              setState(() => _draggingWidth = null);
              return;
            }
            _commit(settings.copyWith(deviceListWidth: next));
          },
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final total = constraints.maxHeight;
              // 拖动中的比例走本地值：设置里那份要等松手才更新。
              final ratio = _draggingRatio ?? settings.editorSplitRatio;
              final editorHeight =
                  (total * ratio).clamp(_minPane, total - _minPane);
              return Column(
                children: [
                  SizedBox(
                    height: editorHeight,
                    child: EditorPanel(key: _editorKey, deviceId: deviceId),
                  ),
                  Splitter(
                    key: const ValueKey('splitter-h'),
                    axis: Axis.horizontal,
                    onDrag: (delta) {
                      if (total <= 0) return;
                      final base = _draggingRatio ?? settings.editorSplitRatio;
                      setState(
                        () => _draggingRatio =
                            (base + delta / total).clamp(0.15, 0.85),
                      );
                    },
                    onDragEnd: () {
                      final next = _draggingRatio;
                      if (next == null || next == settings.editorSplitRatio) {
                        setState(() => _draggingRatio = null);
                        return;
                      }
                      _commit(settings.copyWith(editorSplitRatio: next));
                    },
                  ),
                  Expanded(
                    child: OutputPanel(key: _outputKey, deviceId: deviceId),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// 松手时把拖动中的值写回设置。**成功与失败都要清掉本地值** —— 留着的话，
  /// 之后 `settings` 再怎么变界面都不跟着走了。
  Future<void> _commit(AppSettings next) async {
    try {
      // 存盘成功之后 `SettingsNotifier` 才改内存状态，所以 await 回来时
      // `settingsProvider` 已经是 `next`，清本地值不会闪回旧值。
      await ref.read(settingsProvider.notifier).update(next);
    } catch (_) {
      // 存盘失败时异常从 `update` 原样抛出来（见它的文档）。**不能静默回弹** ——
      // 用户会把"拖了但没生效"当成拖动失灵，而真正的原因是设置没写下去。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设置未能保存')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _draggingWidth = null;
          _draggingRatio = null;
        });
      }
    }
  }

  void _send() => _editorKey.currentState?.send();

  void _clearOutput() => _outputKey.currentState?.clearOutput();

  void _abort() {
    final id = ref.read(selectedDeviceProvider);
    if (id == null) return;
    ref.read(sessionProvider(id).notifier).abort();
  }

  /// 双击命令库里的片段：**先关抽屉，再插入**。
  ///
  /// `Navigator.pop()` 关得掉抽屉而不是把页面弹掉：`DrawerController` 打开时
  /// 往当前路由挂了一个 `LocalHistoryEntry`，`LocalHistoryEntry.didPop` 会
  /// 消费掉这次 pop 并返回 false，于是路由本身留在原地。`snippet_drawer_test.dart`
  /// 里那条"主窗口还在"的断言守的就是这件事。
  void _insertSnippet(String content) {
    Navigator.of(context).pop();
    _editorKey.currentState?.insertAtCursor(content);
  }

  void _addDevice() {
    // FR-D-01 / Ctrl+N。**设备编辑对话框属 5b-2**，这里是有意留的占位：
    // 快捷键的接线（本任务真正要交付的东西）是真的，落点还没有。
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设备编辑对话框将在 5b-2 提供')),
    );
  }
}
