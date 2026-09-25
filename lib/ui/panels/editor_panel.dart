import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../command/command_dispatcher.dart';
// **`DeviceConnectionState` 只能从这里来。** 它在 `connection_manager.dart` 里
// 定义，而 Dart 的 import **不传递** —— `providers.dart` 虽然 import 了它，
// 却不会把它再导出给本文件。
import '../../connection/connection_manager.dart';
import '../../data/draft_store.dart';
import '../../state/providers.dart';
import '../draft_autosave.dart';
import '../widgets/send_range.dart';
import '../widgets/sent_line_controller.dart';

/// 命令编辑区（FR-E）：行号栏、多行输入、发送/中止、队列进度、草稿。
///
/// **它只经 `sessionProvider` 拿会话**（`enqueue` / `abort`），永远不碰
/// `Session` 对象本身 —— 所有权规则：界面只订阅 `ConnectionManager` 派生的
/// 状态，会话的时序约定由 `SessionController` 处理完。
class EditorPanel extends ConsumerStatefulWidget {
  const EditorPanel({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<EditorPanel> createState() => _EditorPanelState();
}

class _EditorPanelState extends ConsumerState<EditorPanel> {
  final SentLineController _text = SentLineController();
  final ScrollController _gutter = ScrollController();
  final ScrollController _editor = ScrollController();

  late final DraftAutosave _autosave = DraftAutosave(
    save: (text) => ref.read(draftProvider(widget.deviceId).notifier).save(text),
    onError: (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('草稿未能保存')),
      );
    },
  );

  /// 草稿是否已经灌进控制器。**每换一台设备要重置** —— 否则切到 B 设备后，
  /// A 的文本会一直留在编辑区里。
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
    _editor.addListener(_syncGutter);
    _loadDraft();
  }

  @override
  void didUpdateWidget(EditorPanel old) {
    super.didUpdateWidget(old);
    if (old.deviceId == widget.deviceId) return;
    // 换设备：先把上一台的草稿落盘（不能等防抖），再清空载入新的。
    _autosave.flush();
    _autosave.dispose();
    _text
      ..sentLines.clear()
      ..text = '';
    _seeded = false;
    _loadDraft();
  }

  @override
  void dispose() {
    // **退出兜底（FR-E-04）**：把还压在防抖里的最后一次编辑写下去。
    _autosave.flush();
    _autosave.dispose();
    _text.removeListener(_onTextChanged);
    _editor.removeListener(_syncGutter);
    _text.dispose();
    _gutter.dispose();
    _editor.dispose();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    try {
      final text = await ref.read(draftProvider(widget.deviceId).future);
      if (!mounted) return;
      setState(() {
        _seeded = true;
        _text.text = text;
      });
    } on DraftUnreadableException {
      // FR-E-03 的失败分支：草稿文件读不了（不是 UTF-8 / 读盘失败）。
      // **不降级成空串** —— 那会让用户以为草稿没了而其实文件还在。
      if (!mounted) return;
      setState(() => _seeded = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('草稿无法读取（文件不是 UTF-8 或读盘失败），已从空白开始')),
      );
    }
  }

  void _onTextChanged() {
    if (!_seeded) return;
    _autosave.schedule(_text.text);
    // 行数变了，行号栏要跟着重画。
    setState(() {});
  }

  void _syncGutter() {
    if (!_gutter.hasClients) return;
    if (_gutter.offset == _editor.offset) return;
    _gutter.jumpTo(_editor.offset);
  }

  void _send() {
    final commands = commandsToSend(_text.text, _text.selection);
    if (commands.isEmpty) {
      // §5.1 结尾：结果为空时给轻提示。**不能静默** —— 用户按了发送却什么都没
      // 发生，会以为程序卡了。
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可发送的命令'), duration: Duration(seconds: 2)),
      );
      return;
    }
    final notifier = ref.read(sessionProvider(widget.deviceId).notifier);
    notifier.enqueue(commands);
    if (mounted) {
      setState(() {
        _text.sentLines
          ..clear()
          ..addAll(linesToSend(_text.text, _text.selection));
      });
    }
  }

  /// FR-E-14 的进度文案。**`PagerContinued` 不产生进度变化**（翻页不是命令），
  /// 所以它落在最后那个 `return null` 上。
  String? _progress(DispatchEvent? event) {
    if (event is CommandSent) return '执行中 ${event.index}/${event.total}';
    if (event is CommandCompleted) {
      return event.timedOut
          ? '第 ${event.index}/${event.total} 条超时'
          : '已完成 ${event.index}/${event.total}';
    }
    if (event is QueueAborted) return '已中止（${event.dropped} 条未发送）';
    if (event is QueueDropped) return '断线，${event.count} 条未发送的命令已丢弃';
    if (event is QueueFinished) return '队列完成';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(sessionProvider(widget.deviceId));
    final connected = status.state == DeviceConnectionState.connected;
    final progress = _progress(status.lastDispatchEvent);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(context, connected: connected, progress: progress),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _gutterWidget(context),
              const VerticalDivider(width: 1),
              Expanded(
                child: TextField(
                  controller: _text,
                  scrollController: _editor,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(8),
                    hintText: '在此输入命令，每行一条',
                  ),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: ['DejaVu Sans Mono'],
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 行号栏。**行高必须与 `TextField` 的 `style` 完全一致**（同字体、同字号、
  /// 同 `height`）—— 差一点就会越往下越错位。
  Widget _gutterWidget(BuildContext context) {
    const lineStyle = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: ['DejaVu Sans Mono'],
      fontSize: 13,
      height: 1.35,
    );
    final count = '\n'.allMatches(_text.text).length + 1;
    return Container(
      width: 44,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        controller: _gutter,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 1; i <= count; i++)
              Text(
                '$i',
                key: ValueKey('gutter-$i'),
                textAlign: TextAlign.right,
                style: lineStyle.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(
    BuildContext context, {
    required bool connected,
    required String? progress,
  }) {
    final busy = progress != null && (progress.startsWith('执行中'));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '连接',
            icon: const Icon(Icons.link, size: 18),
            onPressed: connected
                ? null
                : () => ref.read(sessionProvider(widget.deviceId).notifier).connect(),
          ),
          IconButton(
            tooltip: '断开',
            icon: const Icon(Icons.link_off, size: 18),
            onPressed: connected
                ? () => ref
                      .read(sessionProvider(widget.deviceId).notifier)
                      .disconnect()
                : null,
          ),
          const SizedBox(width: 8),
          if (busy)
            IconButton(
              tooltip: '中止',
              icon: const Icon(Icons.stop, size: 18),
              onPressed: () =>
                  ref.read(sessionProvider(widget.deviceId).notifier).abort(),
            )
          else
            IconButton(
              tooltip: '发送',
              icon: const Icon(Icons.send, size: 18),
              onPressed: connected ? _send : null,
            ),
          const Spacer(),
          if (progress != null)
            Text(progress, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
