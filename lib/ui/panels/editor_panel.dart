import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../command/command_dispatcher.dart';
// **`DeviceConnectionState` 只能从这里来。** 它在 `connection_manager.dart` 里
// 定义，而 Dart 的 import **不传递** —— `providers.dart` 虽然 import 了它，
// 却不会把它再导出给本文件。
import '../../connection/connection_manager.dart';
import '../../data/draft_store.dart';
import '../../state/providers.dart';
import '../dialogs/import_dialog.dart';
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
  ConsumerState<EditorPanel> createState() => EditorPanelState();
}

class EditorPanelState extends ConsumerState<EditorPanel> {
  final SentLineController _text = SentLineController();
  final ScrollController _gutter = ScrollController();
  final ScrollController _editor = ScrollController();

  /// 当前设备的草稿 notifier。**攒在字段里，不现 `ref.read`。**
  ///
  /// `dispose()` 里那一次 flush（FR-E-04 的退出兜底）发生时元素正在被拆 ——
  /// 那一刻碰 `ref` 会被 riverpod 判成 unsafe 并抛 `StateError`（实测：面板带着
  /// 未落盘的防抖被卸载时必现，异常从 `finalizeTree` 里冒出来）。riverpod 给的
  /// 出路就是这句：把 provider 的状态留在 State 的字段里。
  ///
  /// `draftProvider` 不是 autoDispose，notifier 活得比面板长，所以攒下来是安全的。
  late DraftNotifier _drafts;

  /// 落盘节流。**换设备时整份换新** —— 见 [didUpdateWidget]。
  late DraftAutosave _autosave = _newAutosave();

  DraftAutosave _newAutosave() => DraftAutosave(
    save: (text) => _drafts.save(text),
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
    // **必须在任何人读 `_autosave` 之前**：它的 `save` 闭包用的是 `_drafts`。
    _drafts = ref.read(draftProvider(widget.deviceId).notifier);
    _text.addListener(_onTextChanged);
    _editor.addListener(_syncGutter);
    _loadDraft();
  }

  @override
  void didUpdateWidget(EditorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId == widget.deviceId) return;
    // 换设备。**下面几步的顺序是承重的** —— 两条走错都会丢数据，都实测过：
    //
    // 1. `flush()` 必须在 `_drafts` 还指着**旧**设备时调。否则旧设备那段还没落盘
    //    的文本会被写进**新设备**的草稿文件（实测：切走那一刻打的字出现在另一台
    //    的草稿里，而原设备那份是空的）。
    // 2. 换完落点要换一份**新的** `_autosave`：`dispose()` 之后旧实例永久失效
    //    （`_disposed = true` 让 `schedule` 直接返回），实测表现为"切过一次设备
    //    之后草稿再也不会落盘"。新实例的 `_lastSaved` 一并清空 —— 否则新设备的
    //    第一次编辑若与旧设备末次内容相同，会被判成重复写而跳过。
    _autosave.flush();
    _autosave.dispose();
    _drafts = ref.read(draftProvider(widget.deviceId).notifier);
    _autosave = _newAutosave();
    // **先关 `_seeded` 再清文本**：清空会触发 `_onTextChanged`，它一旦认为"已就绪"
    // 就会把空串排进落盘队列。
    _seeded = false;
    _text
      ..sentLines.clear()
      ..text = '';
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
    // **续体要回认设备。** 本方法是异步的：切到 B 之后 B 那次读还没回来，
    // 用户又切回 A —— B 的续体会把**A 的**编辑区刷成 B 的草稿。实测的表现是
    // "切回 A 之后草稿是空的"（`draftProvider('d1')` 已经是 `AsyncData('sys')`，
    // 而编辑区的 text 是 `''`）。`didUpdateWidget` 只管得住换设备的那一刻，
    // 管不住换完之后回来的续体，所以这里自己比一次。
    final deviceId = widget.deviceId;
    try {
      final text = await ref.read(draftProvider(deviceId).future);
      if (!mounted || deviceId != widget.deviceId) return;
      setState(() {
        _seeded = true;
        _text.text = text;
      });
    } on DraftUnreadableException {
      // FR-E-03 的失败分支：草稿文件读不了（不是 UTF-8 / 读盘失败）。
      // **不降级成空串** —— 那会让用户以为草稿没了而其实文件还在。
      if (!mounted || deviceId != widget.deviceId) return;
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

  /// FR-E-15：导入一个本地文件到编辑区。
  Future<void> _importFile() async {
    final request = await ImportDialog.show(context);
    if (request == null || !mounted) return;
    // 两个落法都经 `_setText`，所以落盘防抖与行号栏重画都自动接上了。
    switch (request.mode) {
      case ImportMode.replace:
        replaceAllText(request.text);
      case ImportMode.append:
        appendText(request.text);
    }
  }

  /// FR-S-03：把一段文本插入**当前光标处**。
  ///
  /// **光标所在行非空时先换行**（FR-S-03 原文）。判的是光标所在那一行，不是
  /// "文本末尾" —— 把片段接在 `display version` 的尾巴上会拼出一条谁也没写过
  /// 的命令，而那条命令会真的发到设备上。
  ///
  /// **只有空白字符的行不算非空行。** FR-E-08 规定"确需发送空行时，在行内输入
  /// 一个空格"，所以一行 `'   '` 是**空的**；它上面没有命令可拼，添一个换行只会
  /// 平白多出一个空行。
  void insertAtCursor(String content) {
    final text = _text.text;
    final selection = _text.selection;
    // 从未获得过焦点时 selection 是 `collapsed(offset: -1)`（`isValid` 为
    // false）。此时按"插到末尾"处理 —— 直接抛或什么都不做，都会让"双击命令库
    // 但编辑区还没点过"变成一个静默失败。
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;

    // `lastIndexOf` 在 start-1 < 0 时返回 -1，加一正好是 0。
    final lineStart = text.lastIndexOf('\n', start - 1) + 1;
    final lineEndIndex = text.indexOf('\n', start);
    final lineEnd = lineEndIndex < 0 ? text.length : lineEndIndex;
    final lineIsBlank = text.substring(lineStart, lineEnd).trim().isEmpty;

    final insertion = lineIsBlank ? content : '\n$content';
    _setText(
      text.replaceRange(start, end, insertion),
      caret: start + insertion.length,
    );
  }

  /// 用 [content] **整份替换**编辑区内容（FR-E-15 的「替换现有内容」）。
  void replaceAllText(String content) => _setText(content, caret: content.length);

  /// 把 [content] **追加到末尾**（FR-E-15 的「追加到末尾」）。
  ///
  /// 原文本非空且不以换行结尾时补一个换行 —— 不补的话，原来的最后一行会和导入
  /// 进来的第一行粘成一条，而那正是用户最不容易发现的一种错。
  void appendText(String content) {
    final text = _text.text;
    if (text.isEmpty) {
      replaceAllText(content);
      return;
    }
    replaceAllText('$text${text.endsWith('\n') ? '' : '\n'}$content');
  }

  /// 三个改文本的入口都走这里。
  ///
  /// 一次写 `value`（而不是先改 `text` 再改 `selection`）有两个好处：
  /// `_text.text = ...` 会把 selection 收成无效值，而 listeners 会在那一次就
  /// 被通知 —— `_onTextChanged` 于是排一次落盘、`setState` 重画一次行号栏；
  /// 写两次就是白做一轮。
  void _setText(String next, {required int caret}) {
    _text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
  }

  void send() {
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
              onPressed: connected ? send : null,
            ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '命令库',
            icon: const Icon(Icons.menu_book, size: 18),
            // **`Scaffold.of` 找的是主窗口那个 Scaffold** —— 抽屉挂在它的
            // `endDrawer` 上，编辑区只是它 `body` 里的一棵树。
            // 这也是"编辑区的用例不能点这个按钮"的原因：`ui_harness.dart` 的
            // `pumpUi` 包的那个 `Scaffold` 没有 `endDrawer`。
            // 点下去**不炸** —— `ScaffoldState.openEndDrawer()` 是
            // `_endDrawerKey.currentState?.open();`（`scaffold.dart:2310`），
            // 没有 `endDrawer` 时 `currentState` 也是 null，静默无操作。它比炸
            // 更坏：那种用例会**绿着什么都没测**。命令库的用例一律走 `MainWindow`。
            onPressed: () => Scaffold.of(context).openEndDrawer(),
          ),
          IconButton(
            tooltip: '导入文件',
            icon: const Icon(Icons.file_open, size: 18),
            onPressed: _importFile,
          ),
          const Spacer(),
          if (progress != null)
            Text(progress, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
