import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// **`DeviceConnectionState` 只能从这里来**：Dart 的 import **不传递**，
// `providers.dart` 虽然 import 了它，却不会转手导出给本文件。
import '../../connection/connection_manager.dart';
import '../../models/device_profile.dart';
import '../../state/providers.dart';
import '../widgets/status_dot.dart';

/// 设备列表（FR-D）：选中、连接/断开、拖拽排序、删除。
///
/// **它自己不持有"当前选中哪台"，选中状态在 `selectedDeviceProvider`。**
/// 编辑区与输出区都要读它，而窗口级的快捷键也要读 —— 那不是某个 widget 的
/// 内部状态。
class DeviceListPanel extends ConsumerWidget {
  const DeviceListPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final selected = ref.watch(selectedDeviceProvider);

    if (devices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('还没有设备', textAlign: TextAlign.center),
        ),
      );
    }

    return ReorderableListView.builder(
      itemCount: devices.length,
      // **`onReorderItem` 的 `newIndex` 已经是"移除之后该插到哪个下标"** ——
      // 框架替你调好了（SDK 文档原话："remove the manual adjustment of newIndex"）。
      // 旧的 `onReorder` 才要求自己 `if (newIndex > oldIndex) newIndex -= 1;`，
      // 而它在这版 SDK（3.44.4）里**已废弃**（"after v3.41.0-0.0.pre"），
      // `deprecated_member_use` 又只是条 info —— 正好会打掉"`dart analyze` 干净"
      // 这条验收项，所以必须换。**换了之后别把那个 `-= 1` 一起搬过来**：
      // 再减一次的表现是"往下拖一格没反应、拖两格只动一格"。
      onReorderItem: (oldIndex, newIndex) {
        final ids = devices.map((d) => d.id).toList();
        final moved = ids.removeAt(oldIndex);
        ids.insert(newIndex, moved);
        ref.read(devicesProvider.notifier).reorder(ids);
      },
      itemBuilder: (context, index) {
        final device = devices[index];
        return _DeviceTile(
          key: ValueKey(device.id),
          device: device,
          selected: device.id == selected,
          index: index,
        );
      },
    );
  }
}

class _DeviceTile extends ConsumerWidget {
  const _DeviceTile({
    super.key,
    required this.device,
    required this.selected,
    required this.index,
  });

  final DeviceProfile device;
  final bool selected;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(sessionProvider(device.id));
    final live = status.state == DeviceConnectionState.connected;

    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showMenu(context, ref, details.globalPosition),
      child: ListTile(
        selected: selected,
        onTap: () => ref.read(selectedDeviceProvider.notifier).select(device.id),
        leading: DeviceStatusDot(state: status.state),
        title: Text(device.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${device.host}:${device.port}',
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // tooltip 带设备名：两台设备的按钮必须能彼此区分。
            IconButton(
              tooltip: live ? '断开 ${device.name}' : '连接 ${device.name}',
              icon: Icon(live ? Icons.link_off : Icons.link, size: 18),
              onPressed: () {
                final notifier = ref.read(sessionProvider(device.id).notifier);
                if (live) {
                  notifier.disconnect();
                } else {
                  notifier.connect();
                }
              },
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.drag_handle, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
    if (choice != 'delete' || !context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        // **标题不能也叫"确认删除"。** 用例既断言 `find.textContaining('确认删除')`
        // 只有一个、又用 `find.text('确认删除')` 去点按钮：两处字符串一样的话，
        // 两者都会匹配到 2 个 widget（标题那个 Text + 按钮里的那个 Text），
        // `findsOneWidget` 与 `tap` 会双双失败。这条是实测出来的，别"顺手统一"。
        title: const Text('删除设备'),
        content: Text('删除「${device.name}」？它的命令库与草稿会一并删除，此操作不可撤销。'),
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
    if (confirmed != true) return;

    // **先把选中挪走再删。** 顺序反了的话，`sessionProvider(已删除的 id)` 会在
    // 被拆掉之前先被建一次 —— 而 `SessionNotifier.build()` 要从设备列表里
    // `firstWhere`，那个 id 已经不在了。
    if (ref.read(selectedDeviceProvider) == device.id) {
      final rest = ref
          .read(devicesProvider)
          .where((d) => d.id != device.id)
          .toList();
      ref
          .read(selectedDeviceProvider.notifier)
          .select(rest.isEmpty ? null : rest.first.id);
    }
    await ref.read(devicesProvider.notifier).remove(device.id);
  }
}
