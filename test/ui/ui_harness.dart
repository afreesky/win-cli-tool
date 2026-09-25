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
