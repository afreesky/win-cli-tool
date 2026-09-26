import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/dialogs/sync_dialog.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_sync_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 两台设备。**类型必须显式写出来。** `fakeProfile` 的返回类型是推断的，
  /// 而"推断出来的类型"不算"用了那个 import" —— 全文件没有一处写出
  /// `DeviceProfile` 这个名字的话，上面 `models/device_profile.dart` 那行
  /// 就成了 `unused_import`（分析器的警告，不是提示），`dart analyze` 当场
  /// 不再打印 `No issues found!`，闸门就卡在一行没人看的 import 上。
  final List<DeviceProfile> two = [
    fakeProfile(id: 'd1', name: '核心交换机', host: '10.0.0.1'),
    fakeProfile(id: 'd2', name: '边界防火墙', host: '10.0.0.2'),
  ];

  /// 直接读盘上的草稿。**不读 provider** —— 这个用例要验的正是"盘上真的写了"。
  String draftOnDisk(String deviceId) {
    final file = File('${root.path}/drafts/$deviceId.txt');
    return file.existsSync() ? file.readAsStringSync() : '';
  }

  /// 用另一个 `AppStores` 实例预置草稿。
  ///
  /// 能这么写是因为 `DraftStore` 与 `FileHostKeyStore` 一样**不持实例缓存**
  /// （`FileHostKeyStore` 的文档里那段"缓存整个去掉"）。两处都靠这一点。
  ///
  /// **必须包在 `tester.runAsync` 里，否则用例必挂。** 写盘是真 I/O，而
  /// `testWidgets` 的用例体跑在 `FakeAsync` 里（`flutter_test` 的
  /// `binding.dart`，`AutomatedTestWidgetsFlutterBinding` 用 `FakeAsync.run`
  /// 包住整个用例体）：真 I/O 的完成回调落进**假**的微任务队列，而那个队列
  /// 只有 `pump` / `runAsync` 才会推。用例体自己 `await` 它是推不动的 ——
  /// 体挂在那里等，框架在等体，谁都不动，直到 `testWidgets` 自带的
  /// **10 分钟**超时。`dart analyze` 看不出这件事，它只在运行时发作。
  ///
  /// 实测（Task 8 执行期）：不包 `runAsync` 时，四条调用它的用例**各挂
  /// 10 分钟**；包上之后同六条编辑区用例 3 秒跑完。这与 `settleDisk` /
  /// `pumpUntilTrue` 里那些 `tester.runAsync` 是**同一条规矩**，写在
  /// `ui_harness.dart` 的文档里。
  Future<void> seedDraft(
    WidgetTester tester,
    String deviceId,
    String text,
  ) async {
    await tester.runAsync(
      () => AppStores(paths: AppPaths(root)).drafts.write(deviceId, text),
    );
  }

  /// 从**树里**的 provider 容器读东西（本仓既有的写法，见
  /// `device_params_change_test.dart`）。锚点是编辑区自己 —— 这个文件没有
  /// "打开"那种按钮可锚。
  ///
  /// 这一行也顺带让 `flutter_riverpod.dart` 那行 import 有人用了：本文件
  /// 别处一个 riverpod 名字都没有，少了它同样是 `unused_import`。
  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(EditorPanel)));

  group('对话框本身', () {
    testWidgets('只有一台设备时说清楚，不给同步（FR-E-17 的边界）', (tester) async {
      await pumpDialogHost(
        tester,
        root: root,
        buttonLabel: '打开',
        devices: [fakeProfile(id: 'd1', name: '核心交换机')],
        open: (context) => SyncDialog.show(
          context,
          sourceDeviceId: 'd1',
          text: 'x',
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.textContaining('没有别的设备'), findsOneWidget);
      expect(find.text('覆盖'), findsNothing);
    });

    testWidgets('目标里不出现源设备自己（FR-E-17）', (tester) async {
      await pumpDialogHost(
        tester,
        root: root,
        buttonLabel: '打开',
        devices: two,
        open: (context) => SyncDialog.show(
          context,
          sourceDeviceId: 'd1',
          text: 'x',
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sync-target')));
      await tester.pumpAndSettle();

      expect(find.text('边界防火墙'), findsWidgets, reason: '下拉里有它');
      expect(
        find.text('核心交换机'),
        findsNothing,
        reason: '自己不在目标候选里 —— 同步给自己没有意义',
      );
    });
  });

  group('接到编辑区上', () {
    Future<TextEditingController> pumpEditor(WidgetTester tester) async {
      await pumpUi(
        tester,
        root: root,
        devices: two,
        child: const SizedBox(height: 400, child: EditorPanel(deviceId: 'd1')),
      );
      // 草稿是**真 I/O** 读进来的（`DraftStore.read` 的 `exists` + `readAsBytes`），
      // `pumpUi` 收尾那个 `pumpAndSettle` 推的是假时钟，推不动它。
      //
      // **必须等它落地再返回。** `_loadDraft` 拿到值之后会 `_text.text = text`
      // （`editor_panel.dart:119-123`）。用例紧接着就 `editor.value = …`，那个
      // **迟到的**载入会把编辑区盖回草稿内容 —— 红起来的样子（"编辑区是空的"、
      // 点开同步按钮没有对话框）跟用例要验的东西毫无关系。`settleDisk` 的
      // 12×5ms 够不够全看机器当下忙不忙，所以这里按条件等，出现即走。
      //
      // 顺带也是 `_seeded` 的前提：`_onTextChanged` 在 `_seeded` 之前直接
      // return（`editor_panel.dart:137`），载入没落地时设 `editor.value` 连
      // 落盘防抖都不会排上。
      await pumpUntilTrue(
        tester,
        () => containerOf(tester).read(draftProvider('d1')).hasValue,
      );
      return tester.widget<TextField>(find.byType(TextField)).controller!;
    }

    /// 打开对话框，选目标，按 [label] 那个按钮。
    ///
    /// **这里没有 `enterText` 可用** —— `sync-target` 是 `DropdownButton`，
    /// 不是输入框，`tester.enterText` 会因为找不到 `EditableText` 而抛。
    /// 选目标只能"点开、再点那一项"：`find.text('边界防火墙').last` 取的是
    /// **展开菜单里**那一项（`Overlay` 的条目排在对话框路由之后，所以在
    /// 遍历序里靠后；靠前那个是收起状态下按钮自己显示的名字）。
    Future<void> syncAs(WidgetTester tester, String label) async {
      await tester.tap(find.byTooltip('同步到另一台'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sync-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('边界防火墙').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      // **不能只 `settleDisk`。** 这一按之后 `_run` 要先读目标草稿、再
      // `save()` 落盘，而 `DraftStore.write` 走 `writeFileAtomically`：
      // 建目录 → 写 `.tmp`（flush）→ **两次 `chmod` 真进程** → rename。
      // 本组每条断言看的都是**盘上的结果**，所以要等写真的完成。
      // `save()` 返回之后对话框才 `pop()`，因此"按钮没了"就等于"盘上写完了"
      // —— 按条件等，不用赌那 60ms 真实时间。
      //
      // 顺带一提，本文件里 `find.text('覆盖')` / `find.text('追加')` 都不会被
      // 之后弹出的 SnackBar 命中：那句是"已覆盖到「边界防火墙」的草稿"，
      // 而 `find.text` 是全等匹配。
      await pumpUntilTrue(tester, () => find.text(label).evaluate().isEmpty);
    }

    testWidgets('覆盖：目标草稿变成编辑区的内容（FR-E-17）', (tester) async {
      await seedDraft(tester, 'd2', '旧的目标草稿');
      final editor = await pumpEditor(tester);
      editor.value = const TextEditingValue(
        text: 'hostname R1',
        selection: TextSelection.collapsed(offset: 11),
      );
      await tester.pump();

      await syncAs(tester, '覆盖');

      expect(draftOnDisk('d2'), 'hostname R1');
      expect(find.textContaining('已覆盖到「边界防火墙」'), findsOneWidget);
    });

    testWidgets('追加：目标原有的内容还在（FR-E-17）', (tester) async {
      await seedDraft(tester, 'd2', '原有命令');
      final editor = await pumpEditor(tester);
      editor.value = const TextEditingValue(
        text: '新命令',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await syncAs(tester, '追加');

      expect(draftOnDisk('d2'), '原有命令\n新命令');
    });

    testWidgets('追加到一个空草稿：不产生开头的空行', (tester) async {
      final editor = await pumpEditor(tester);
      editor.value = const TextEditingValue(
        text: '新命令',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await syncAs(tester, '追加');

      expect(draftOnDisk('d2'), '新命令');
    });

    testWidgets('源设备的草稿一个字都没动', (tester) async {
      await seedDraft(tester, 'd1', '源的内容');
      final editor = await pumpEditor(tester);
      expect(editor.text, '源的内容', reason: '前置条件：源草稿已经灌进编辑区');

      await syncAs(tester, '覆盖');

      // 编辑区的内容本来就要落回源草稿（FR-E-03），所以这里断言的是
      // **目标的**草稿与源的内容一致，而源的那份没有被同步动作写坏。
      expect(draftOnDisk('d1'), '源的内容');
      expect(draftOnDisk('d2'), '源的内容');
    });

    testWidgets('编辑区是空的：不发同步，给一句提示', (tester) async {
      final editor = await pumpEditor(tester);
      expect(editor.text, isEmpty, reason: '前置条件');

      await tester.tap(find.byTooltip('同步到另一台'));
      await tester.pumpAndSettle();

      expect(find.textContaining('编辑区是空的'), findsOneWidget);
      expect(find.text('覆盖'), findsNothing, reason: '对话框不该开');
    });

    testWidgets('取消：目标草稿一个字都不动', (tester) async {
      await seedDraft(tester, 'd2', '原有命令');
      final editor = await pumpEditor(tester);
      editor.value = const TextEditingValue(
        text: '新命令',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('同步到另一台'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await settleDisk(tester);

      expect(draftOnDisk('d2'), '原有命令');
    });
  });
}
