import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/draft_store.dart';
import '../../state/providers.dart';

/// 同步方式（FR-E-17：「指定『覆盖』或『追加』」）。
enum SyncMode { overwrite, append }

/// 一次同步的结果：写给了谁、怎么写的。用来拼提示。
class SyncResult {
  const SyncResult(this.targetName, this.mode);

  final String targetName;
  final SyncMode mode;
}

/// 「同步到另一台」对话框（FR-E-17）。
///
/// **它自己完成写入**（而不是把选择返回给调用方）—— 因为"追加"要先读目标
/// 设备现有的草稿，而那是一次异步 IO；让调用方再读一次，两处就要各写一遍
/// `DraftUnreadableException` 的处理。
///
/// 成功时 pop 出 [SyncResult]，取消时 pop 出 null。
class SyncDialog extends ConsumerStatefulWidget {
  const SyncDialog({
    super.key,
    required this.sourceDeviceId,
    required this.text,
  });

  /// 源设备 —— 它**不出现在目标候选里**。
  final String sourceDeviceId;

  /// 要写过去的内容。**由编辑区传进来**（见计划里那个设计点）。
  final String text;

  static Future<SyncResult?> show(
    BuildContext context, {
    required String sourceDeviceId,
    required String text,
  }) => showDialog<SyncResult>(
    context: context,
    builder: (_) => SyncDialog(sourceDeviceId: sourceDeviceId, text: text),
  );

  @override
  ConsumerState<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends ConsumerState<SyncDialog> {
  String? _targetId;
  String? _error;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final targets = ref
        .watch(devicesProvider)
        .where((d) => d.id != widget.sourceDeviceId)
        .toList(growable: false);

    if (targets.isEmpty) {
      return AlertDialog(
        title: const Text('同步到另一台'),
        content: const Text('没有别的设备可以同步 —— 先在设备列表里添加一台。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('好的'),
          ),
        ],
      );
    }

    // **`!` 不能省。** `_targetId` 是 `String?`，三元的两支是 `String?` 与
    // `String`，于是 `selected` 推断出来是 **`String?`** —— 而 `_run` 收的是
    // `String`，不写 `!` 这里**根本编译不过**（`The argument type 'String?'
    // can't be assigned to the parameter type 'String'`）。
    //
    // **它不可能抛**：能走到真分支，就说明 `targets` 里有一台的 `id` 与
    // `_targetId` 相等，而 `id` 是 `String`（非空），所以 `_targetId` 必非空。
    // 别改成 `_targetId ?? targets.first.id` —— 那会丢掉 `any(...)` 这道守卫：
    // 目标设备**已被删掉**时 `_targetId` 还留着旧 id，`??` 会原样用它，
    // 而 `any(...)` 会正确地退回 `targets.first.id`。
    final selected = targets.any((d) => d.id == _targetId)
        ? _targetId!
        : targets.first.id;

    return AlertDialog(
      title: const Text('同步到另一台'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('sync-target'),
              initialValue: selected,
              decoration: const InputDecoration(labelText: '目标设备'),
              items: [
                for (final d in targets)
                  DropdownMenuItem(value: d.id, child: Text(d.name)),
              ],
              onChanged: (next) => setState(() => _targetId = next),
            ),
            const SizedBox(height: 12),
            const Text(
              '写入的是目标设备的草稿 —— 切到那台设备时会在编辑区里看到。',
              style: TextStyle(fontSize: 12),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
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
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _busy ? null : () => _run(selected, SyncMode.overwrite),
          child: const Text('覆盖'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _run(selected, SyncMode.append),
          child: const Text('追加'),
        ),
      ],
    );
  }

  Future<void> _run(String targetId, SyncMode mode) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final String existing;
    try {
      // **经 provider 读，不直接读盘。** provider 缓存着这台设备的草稿，
      // 绕过它写盘会让缓存过期（见计划里的设计点 2）。
      existing = await ref.read(draftProvider(targetId).future);
    } on DraftUnreadableException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // **不降级成空串**：那会把用户原有的草稿当成"没有"而覆盖掉。
        _error = '目标设备的草稿无法读取（不是 UTF-8 或读盘失败），为免覆盖已停止同步';
      });
      return;
    }

    final next = switch (mode) {
      SyncMode.overwrite => widget.text,
      SyncMode.append when existing.isEmpty => widget.text,
      SyncMode.append => '$existing${existing.endsWith('\n') ? '' : '\n'}${widget.text}',
    };

    final name = ref
        .read(devicesProvider)
        .firstWhere((d) => d.id == targetId)
        .name;
    try {
      await ref.read(draftProvider(targetId).notifier).save(next);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '同步失败：$error';
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(SyncResult(name, mode));
  }
}
