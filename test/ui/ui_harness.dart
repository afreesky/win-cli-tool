import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// **`Override` 不在 `flutter_riverpod.dart` 里。** riverpod 3.x 把它移到了次要
// 入口：主入口的 show 列表没有它，`misc.dart` 才有（实测 flutter_riverpod
// 3.4.3）。少这一行，本文件红在 `non_type_as_type_argument`，而它连带把
// 所有 `import 'ui_harness.dart';` 的测试文件一起拖红。
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/providers.dart';

import '../fixtures/fake_session.dart';

/// 把 [child] 装进一棵**能真跑**的 provider 树里。
///
/// 覆盖的四项与 `test/ui/app_test.dart` 逐字相同，理由也一样：
/// `SessionNotifier.build()` 要 `appStoresProvider` / `startupProvider` /
/// `sessionFactoryProvider`，而 `Directory(settings.logDir ?? ref.read(logsDirPath))`
/// 里的 `logsDirPath` 没覆盖就抛 `StateError`。
Future<void> pumpUi(
  WidgetTester tester, {
  required Directory root,
  required Widget child,
  List<DeviceProfile> devices = const [],
  AppSettings settings = const AppSettings(),
  FakeSessionFactory? factory,
  List<Override> extra = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores(paths: AppPaths(root))),
        startupProvider.overrideWithValue(
          AppStartup(settings: settings, devices: devices),
        ),
        sessionFactoryProvider.overrideWithValue(factory ?? FakeSessionFactory()),
        logsDirPath.overrideWithValue('${root.path}/logs'),
        ...extra,
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}

/// 让**真盘 I/O** 走完：转一圈真实事件循环，再 flush 一次假时钟的微任务队列，交替若干轮。
///
/// **为什么不能只用其中一个**（实测）：`pump()` 只 flush 微任务、不转真实事件循环；
/// `runAsync(delay)` 只转一次真实事件循环。而 `dart:io` 的每一步都要一次真实的轮转才
/// 推进，`DeviceStore.save()` 至少是 `create(recursive: true)` + `writeAsString()` 两步
/// —— 只做其中之一就停在半路，表现为"点了确认删除，设备还在"。
///
/// 凡是用例要观察**写盘之后**的状态（删除、拖拽排序、改设置），都用它代替
/// `pumpAndSettle()`。
Future<void> settleDisk(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pumpAndSettle();
}

/// 装一个"点一下就开对话框"的宿主。
///
/// `showDialog` 不能在 `build` 里调 —— 它要一次用户动作。所以每个对话框用例
/// 都得先有这么一个按钮；放在这里省得十来条用例各写一遍 `Builder`。
///
/// [open] 里那一下就由按钮的 `onPressed` 挂着（返回的 Future 没人 await，
/// 这正是 `showDialog` 的用法），用例只需 `tap` + `pumpAndSettle`。
Future<void> pumpDialogHost(
  WidgetTester tester, {
  required Directory root,
  required String buttonLabel,
  required Future<void> Function(BuildContext context) open,
  List<DeviceProfile> devices = const [],
  AppSettings settings = const AppSettings(),
  FakeSessionFactory? factory,
  List<Override> extra = const [],
}) => pumpUi(
  tester,
  root: root,
  devices: devices,
  settings: settings,
  factory: factory,
  extra: extra,
  child: Builder(
    builder: (context) => Center(
      child: ElevatedButton(
        onPressed: () => open(context),
        child: Text(buttonLabel),
      ),
    ),
  ),
);

/// 把测试窗口调高到装得下整个对话框。
///
/// **默认的 800×600 装不下**（这是实测设备编辑对话框的数字）：对话框内容
/// 798 逻辑像素高、视口只有 384，折在窗口外的控件 `tap` 只会空点一下 ——
/// 实测开关在 y=866、行尾符下拉在 y=634，都在 600 之外。
///
/// **`ensureVisible` 救不了这个**：它也只把内容滚到 `pixels=322`（上限
/// `maxScrollExtent` 是 414），开关仍在 y=516–572，还是落在视口下沿 480 之外
/// —— 因为那已经是内容最后一项，没有更多东西可滚了。
///
/// 所以凡是**需要点到**对话框里靠下那几个控件的用例，开头先调这一下。
/// 只是断言（不点）的用例不必调。
Future<void> useTallSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// 等到 [finder] 能找到东西（最多 [rounds] 轮），再 `pumpAndSettle`。
///
/// **为什么不能只是多推几帧**：`pump`/`pumpAndSettle` 推的是**假时钟**，而落盘、
/// `Process.run('chmod', …)` 这些是**真 I/O**，假时钟推不动。`settleDisk` 的轮数
/// 又是写死的（12 × 5ms ≈ 60ms 真实时间），够不够全看机器当下忙不忙 —— 实测
/// **同一份代码多一句 `debugPrint` 就从红变绿**。所以这里按条件等，出现即走：
/// 机器快就快过，机器慢就多等几轮，都不会红。
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int rounds = 400,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (finder.evaluate().isNotEmpty) break;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pumpAndSettle();
}

/// 等到 SnackBar 真的弹出来（最多 [rounds] 轮），动画走完再返回。
///
/// **不能只靠 `settleDisk` / `pumpAndSettle`。** 举断开那条路：
/// `_disconnect` → `await …disconnect()` → `_endLog()` → `_flush(force: true)`，
/// 里面除了 `stat` / `create` / `writeAsString(flush: true)`，还有
/// `restrictToOwner` 的 `Process.run('chmod', …)` —— **起一个真进程**。
/// 假时钟推不动这些真 I/O，而 `settleDisk` 的轮数是写死的
/// （12 × 5ms ≈ 60ms 真实时间），够不够全看机器当下忙不忙：实测同一份代码，
/// 多一句 `debugPrint` 就从红变绿。所以这里按条件等，出现即走。
///
/// **状态断言不能代替它**：`ConnectionManager` 的新状态是经 `onStatus` 回调
/// 推进 provider 的，不等 `_disconnect` 里那个 await —— 实测状态已经是
/// `disconnected` 时 SnackBar 还一个都没有。两条都要断。
Future<void> pumpUntilSnackBar(WidgetTester tester, {int rounds = 400}) =>
    pumpUntil(tester, find.byType(SnackBar), rounds: rounds);
