import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/device_profile.dart';
import '../../state/providers.dart';

/// 命令库抽屉（FR-S-01…04）。
///
/// **它是主窗口的 `Scaffold.endDrawer`**，打开它的按钮在编辑区工具栏里
/// （`Scaffold.of(context).openEndDrawer()`）。
///
/// 片段存在 `DeviceProfile.snippets` 里 —— 归属设备、跟着设备走（FR-S-01），
/// 所以增删改一律走 `devicesProvider.notifier.update`，**不另开一份存储**。
/// 这也是 FR-D-06"删设备时一并删掉命令库"天然成立的原因。
class SnippetDrawer extends ConsumerWidget {
  const SnippetDrawer({
    super.key,
    required this.deviceId,
    required this.onInsert,
  });

  final String deviceId;

  /// 双击一条片段时调用。**由主窗口实现** —— 插入的落点在编辑区的 State 里，
  /// 而抽屉够不到它（编辑区是抽屉的兄弟，不是子节点）。
  final void Function(String content) onInsert;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final index = devices.indexWhere((d) => d.id == deviceId);
    if (index < 0) {
      // 设备被删掉的那一帧，抽屉可能还在树上（`MainWindow` 的 `active` 要到
      // 下一帧才变成 null）。给一个空抽屉，别抛。
      return const Drawer(child: SizedBox.shrink());
    }
    final device = devices[index];

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(
                '命令库 · ${device.name}',
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: '添加命令片段',
                icon: const Icon(Icons.add),
                onPressed: () => _edit(context, ref, device, null),
              ),
            ),
            const Divider(height: 1),
            if (device.snippets.isEmpty)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('还没有命令片段', textAlign: TextAlign.center),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: device.snippets.length,
                  itemBuilder: (context, i) {
                    final snippet = device.snippets[i];
                    // `ListTile` 只有 `onTap`/`onLongPress`，没有 `onDoubleTap`
                    // —— 双击要靠外面这层 `GestureDetector`。
                    //
                    // ⚠ **两个按钮必须放在 `GestureDetector` 外面**，不能图省事
                    // 当 `ListTile.trailing`。`DoubleTapGestureRecognizer` 在第一次
                    // 按下时会 `gestureArena.hold(pointer)`（`gestures/multitap.dart:330`，
                    // `_registerFirstTap` 里），把手势竞技场**按住**到双击超时
                    // （300ms）才释放。按钮是 `GestureDetector` 的后代，于是单击
                    // 要等满 300ms 才轮到它赢；**双击按钮还会顺带触发插入**。
                    // 实测（本机 flutter 3.44.4）：写成 `trailing` 的话，
                    // `tap` 完 `pumpAndSettle()` 之后对话框是 0 个 ——
                    // `pumpAndSettle` 在 ~100ms 后就没有待处理的帧了，而 hold
                    // 还没释放；再推 400ms 才出现。这不是测试写法的问题，
                    // 是真机上按钮真的迟 300ms。
                    return Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onDoubleTap: () => onInsert(snippet.content),
                            child: ListTile(
                              title: Text(
                                snippet.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                snippet.content,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ),
                        ),
                        // tooltip 带片段名：两条片段的按钮必须能彼此区分。
                        IconButton(
                          tooltip: '编辑 ${snippet.name}',
                          icon: const Icon(Icons.edit, size: 18),
                          onPressed: () => _edit(context, ref, device, snippet),
                        ),
                        IconButton(
                          tooltip: '删除 ${snippet.name}',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () =>
                              _delete(context, ref, device, snippet),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    DeviceProfile device,
    Snippet? existing,
  ) async {
    final result = await showDialog<Snippet>(
      context: context,
      builder: (_) => _SnippetEditDialog(existing: existing),
    );
    if (result == null || !context.mounted) return;

    final next = [...device.snippets];
    final at = next.indexWhere((s) => s.id == result.id);
    if (at < 0) {
      next.add(result);
    } else {
      next[at] = result;
    }
    await _save(context, ref, device, next);
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    DeviceProfile device,
    Snippet snippet,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        // 标题与按钮的文字**必须不同**：两边一样的话，`find.text` 会同时匹配到
        // 标题与按钮，`findsOneWidget` 与 `tap` 双双失败。删除设备那条对话框
        // 的注释里记着同一条实测教训。
        title: const Text('删除命令片段'),
        content: Text('删除「${snippet.name}」？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    await _save(
      context,
      ref,
      device,
      device.snippets.where((s) => s.id != snippet.id).toList(growable: false),
    );
  }

  /// 存片段。写的是**整台设备**（片段归属设备），所以走 `devicesProvider.update`
  /// —— 它先存盘再改内存，失败时异常原样抛出来给用户看。
  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    DeviceProfile device,
    List<Snippet> snippets,
  ) async {
    try {
      await ref
          .read(devicesProvider.notifier)
          .update(device.copyWith(snippets: snippets));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('命令库未能保存：$error')));
    }
  }
}

/// 加/改一条片段。
class _SnippetEditDialog extends StatefulWidget {
  const _SnippetEditDialog({this.existing});

  final Snippet? existing;

  @override
  State<_SnippetEditDialog> createState() => _SnippetEditDialogState();
}

class _SnippetEditDialogState extends State<_SnippetEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _content = TextEditingController(
    text: widget.existing?.content ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '名称不能为空');
      return;
    }
    // 内容**不 trim**：片段的多行结构是用户排的，首尾的空行也算数。
    if (_content.text.isEmpty) {
      setState(() => _error = '内容不能为空');
      return;
    }
    Navigator.of(context).pop(
      // **编辑时保留原 id**：id 是身份，`Snippet.copyWith` 也刻意不接受它。
      widget.existing?.copyWith(name: name, content: _content.text) ??
          Snippet(id: newSnippetId(), name: name, content: _content.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '添加命令片段' : '编辑命令片段'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('snippet-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('snippet-content'),
              controller: _content,
              maxLines: 6,
              minLines: 3,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: '内容（可多行）',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
