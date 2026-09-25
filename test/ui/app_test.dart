import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/app.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/providers.dart';

import '../fixtures/fake_session.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_app_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  testWidgets('外壳能起来，且用上了设置里的主题', (tester) async {
    final stores = AppStores(paths: AppPaths(root));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          startupProvider.overrideWithValue(
            const AppStartup(
              settings: AppSettings(theme: AppTheme.dark),
              devices: [],
            ),
          ),
          sessionFactoryProvider.overrideWithValue(FakeSessionFactory()),
        ],
        child: const WinCliToolApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MaterialApp), findsOneWidget);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark, reason: '主题来自设置');
  });

  testWidgets('启动时只给 autoConnect 的设备发起连接（FR-C-14）', (tester) async {
    // **两台设备：一台 `autoConnect: true`，一台 false。**
    //
    // 原来的写法是"零台设备 + 断言 sessions 为空"，那条**永远不会红**：
    // 扫描整个不跑、或者 `connectAutoConnectDevices` 里那句
    // `if (!device.autoConnect) continue;` 被删掉，零台设备都连不出东西来，
    // 断言照样绿。要钉的是"按 autoConnect **过滤**"，就必须同时有该连的和
    // 不该连的 —— 只有一台时 `hasLength(1)` 与"过滤器不存在"无法区分。
    final factory = FakeSessionFactory();
    final stores = AppStores(paths: AppPaths(root));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          startupProvider.overrideWithValue(
            AppStartup(
              settings: const AppSettings(),
              devices: [
                fakeProfile(id: 'auto', name: 'A', autoConnect: true),
                fakeProfile(id: 'manual', name: 'B'),
              ],
            ),
          ),
          sessionFactoryProvider.overrideWithValue(factory),
          // 这一条不能省：`SessionNotifier.build()` 要
          // `Directory(settings.logDir ?? ref.read(logsDirPath))`，而
          // `AppSettings.logDir` 默认是 null、`logsDirPath` 没覆盖就抛
          // StateError。理由与 `providers_test.dart` 的 `boot()` 逐字相同。
          logsDirPath.overrideWithValue('${root.path}/logs'),
        ],
        child: const WinCliToolApp(),
      ),
    );
    await tester.pumpAndSettle();

    // **下面两轮 pump 实测都是空转 —— 留着是保险，不是判别力来源。**
    //
    // 实测（探针打印计数，跑完即删）：`pumpAndSettle()` 之后扫描就已经落定，
    // 第一个循环**一次都没进**（它的守卫 `factory.sessions.isEmpty` 首次求值时
    // 就已经是 false），第二个 8×25ms 的循环跑满也不改变任何东西
    // （`sessions=1 ids=[auto]`）。原因是结构性的：`connectAutoConnectDevices`
    // 是一个普通同步 `for` 循环，`ref.read(sessionProvider(id).notifier)` 同步
    // 建出 notifier，而 `ConnectionManager._attemptConnect` 在**任何真异步 IO
    // 之前**就同步走到 `factory.create(profile)` —— 所以"本该被过滤掉的那台"
    // 若真会被连，也是在**同一波微任务**里被连，就在 `pumpAndSettle` 里面。
    //
    // 那它们为什么还在？因为一旦连接路径在 `create` 之前多出一个真的 `await`
    // （5b 的指纹确认对话框就是一个），这两轮就从空转变成承重。**但别据此以为
    // 下面那条断言靠它们**：断言真正靠的是"该连的和不该连的各一台"。实测把
    // `session_controller.dart` 的 `if (!device.autoConnect) continue;` 删掉，
    // 它红在 `hasLength(1)`，而不是红在这两个循环上。
    for (var i = 0; i < 40 && factory.sessions.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(factory.sessions, hasLength(1),
        reason: '只有 autoConnect 的那台该被连');
    expect(factory.sessions.single.profile.id, 'auto');
  });
}
