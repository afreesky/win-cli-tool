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

    // 首帧之后的那次扫描是 `unawaited(...)`，provider 的建立又在几个 await
    // 之后 —— 有界地等它落定，而不是赌一次 `pumpAndSettle` 正好够。
    for (var i = 0; i < 40 && factory.sessions.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    // **这一轮是承重的。** 上面的循环一看到有会话就停，所以"只有一台"此时
    // 还可能只是"第二台还没轮到"。再给一段固定时间，让**本该被过滤掉**的那台
    // 有机会连上：它要真连了，下面那条 `hasLength(1)` 立刻红。没有这一轮，
    // 那条断言测的是调度顺序，不是过滤器。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(factory.sessions, hasLength(1),
        reason: '只有 autoConnect 的那台该被连');
    expect(factory.sessions.single.profile.id, 'auto');
  });
}
