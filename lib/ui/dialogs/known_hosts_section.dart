import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connection/known_host.dart';
import '../../state/providers.dart';

/// 设置对话框里的「已知主机密钥」区（FR-G-01 的"查看与逐条清除"）。
///
/// **它独立于 `SettingsDialog` 的"保存"按钮。** 那一边是"改了一堆字段、
/// 一次写入"，这一边的每一个动作（清除一条）都是**立即、独立、不可撤销**
/// 的。把它们塞进同一个保存语义里，会造出"清了一条然后又点了取消"这种
/// 说不清的状态。
class KnownHostsSection extends ConsumerStatefulWidget {
  const KnownHostsSection({super.key});

  @override
  ConsumerState<KnownHostsSection> createState() => _KnownHostsSectionState();
}

class _KnownHostsSectionState extends ConsumerState<KnownHostsSection> {
  List<KnownHost>? _hosts;

  /// 读盘失败时的说明。**`all()` 会抛**（`FileHostKeyStore` 的有意设计：
  /// 丢一条已知主机密钥等于让那台主机静默退回"首次连接"）。接住它换一句
  /// 人话，不能让整个设置对话框跟着炸。
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      // `AppStores.hostKeys` 的静态类型就是 `FileHostKeyStore`，`all()` 直接
      // 从具体类型上调 —— 不涉及向下转型（spec §13.5 的要求）。
      final hosts = await ref.read(appStoresProvider).hostKeys.all();
      if (!mounted) return;
      setState(() {
        _hosts = hosts;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _hosts = const [];
        _error = '已知主机密钥文件无法读取：$error';
      });
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _remove(KnownHost target) async {
    final ok = await _confirm(
      '清除这条已知主机密钥？',
      '清掉之后，${target.host}:${target.port} 会退回"首次连接" —— '
          '下次连它会重新弹出指纹让你确认。',
    );
    if (!ok || !mounted) return;
    await ref
        .read(appStoresProvider)
        .hostKeys
        .remove(target.host, target.port, target.keyType);
    await _reload();
  }

  Future<void> _clearAll() async {
    final hosts = _hosts ?? const <KnownHost>[];
    final ok = await _confirm(
      '清除全部已知主机密钥？',
      '${hosts.length} 条记录都会被清掉，之后每一台主机都会重新弹指纹确认。',
    );
    if (!ok || !mounted) return;
    final store = ref.read(appStoresProvider).hostKeys;
    for (final h in hosts) {
      await store.remove(h.host, h.port, h.keyType);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('已知主机密钥', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (hosts != null && hosts.isNotEmpty)
              TextButton(
                key: const ValueKey('known-hosts-clear-all'),
                onPressed: _clearAll,
                child: const Text('全部清除'),
              ),
          ],
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        else if (hosts == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('读取中…'),
          )
        else if (hosts.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '还没有任何已知主机密钥。首次连接一台 SSH 设备并确认指纹之后，'
              '记录会出现在这里。',
              style: TextStyle(fontSize: 12),
            ),
          )
        else
          for (var i = 0; i < hosts.length; i++)
            ListTile(
              key: ValueKey('known-host-$i'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${hosts[i].host}:${hosts[i].port}  ${hosts[i].keyType}'),
              subtitle: Text(
                hosts[i].fingerprint,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              trailing: IconButton(
                key: ValueKey('known-host-remove-$i'),
                tooltip: '清除',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => _remove(hosts[i]),
              ),
            ),
      ],
    );
  }
}
