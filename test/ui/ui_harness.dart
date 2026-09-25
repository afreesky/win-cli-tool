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
