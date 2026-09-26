import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/file_reader.dart';

/// 导入方式（FR-E-15）。
enum ImportMode { replace, append }

/// 一次导入请求：文本 + 用户选的落法。
class ImportRequest {
  const ImportRequest(this.text, this.mode);

  final String text;
  final ImportMode mode;
}

/// 导入文件对话框（FR-E-15/16）。
///
/// **零依赖：路径输入框，不用系统文件选择器**（用户决策④）。加一个
/// `file_picker` / `file_selector` 会把 Linux 侧的 GTK 依赖与打包配置一起带进来，
/// 而这条需求的全部内容是"把磁盘上一个文本文件读成编辑区的内容"。
///
/// **「替换」与「追加」是两个按钮**，不是"先选单选再按确定"：FR-E-15 说的
/// "询问替换还是追加"就是这两个按钮在问，选哪一个本身就是回答 —— 少一步。
class ImportDialog extends ConsumerStatefulWidget {
  const ImportDialog({super.key});

  static Future<ImportRequest?> show(BuildContext context) =>
      showDialog<ImportRequest>(
        context: context,
        builder: (_) => const ImportDialog(),
      );

  @override
  ConsumerState<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<ImportDialog> {
  final _path = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _import(ImportMode mode) async {
    final path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _error = '请填写文件路径');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final List<int> bytes;
    try {
      bytes = await ref.read(fileReaderProvider)(path);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 不把 `FileSystemException.toString()` 直接摆给用户 —— 那串里混着
        // 系统错误号与内部路径，读起来像程序坏了而不是"路径写错了"。
        _error = '读不到这个文件：$error';
      });
      return;
    }

    final String text;
    try {
      // FR-E-16：**必须是 UTF-8。** `utf8.decode` 默认就是严格模式
      // （`allowMalformed: false`）—— 宽松解码会把 GBK 的设备配置静默变成
      // 一串 U+FFFD，而用户看到的是"导入成功"。
      text = utf8.decode(bytes);
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '这个文件不是 UTF-8 编码，无法导入（FR-E-16）';
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(ImportRequest(text, mode));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入文件'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('import-path'),
              controller: _path,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '文件路径',
                helperText: '仅支持 UTF-8 编码的文本文件',
              ),
            ),
            const SizedBox(height: 12),
            const Text('导入的内容怎么放？', style: TextStyle(fontSize: 12)),
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
          onPressed: _busy ? null : () => _import(ImportMode.replace),
          child: const Text('替换现有内容'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _import(ImportMode.append),
          child: const Text('追加到末尾'),
        ),
      ],
    );
  }
}
