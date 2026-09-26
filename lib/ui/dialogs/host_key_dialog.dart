import 'package:flutter/material.dart';

import '../../connection/known_host.dart';

/// 首次连接一台 SSH 主机时的指纹确认（FR-C-11）。
///
/// **`barrierDismissible: false`。** 点空白关掉它也返回 false（安全侧），
/// 但那会让一次连接因为"手滑点到了旁边"而失败，而失败信息里没有"你刚才
/// 关掉了指纹确认"。让它必须明确选一个。
Future<bool> showHostKeyDialog(BuildContext context, KnownHost host) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('首次连接这台主机'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${host.host}:${host.port}'),
            const SizedBox(height: 4),
            Text('密钥算法：${host.keyType}'),
            const SizedBox(height: 12),
            const Text('指纹：', style: TextStyle(fontSize: 12)),
            SelectableText(
              host.fingerprint,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            const Text(
              '这是唯一一次核对它的机会。如果这个指纹与设备上实际的那把不符，'
              '说明中间有人在冒充它 —— 选「拒绝」。\n'
              '接受之后指纹会被记住，下次连接不再询问。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('拒绝'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('接受并保存'),
        ),
      ],
    ),
  );
  return accepted ?? false;
}
