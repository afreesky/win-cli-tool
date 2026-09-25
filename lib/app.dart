import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/app_settings.dart';
import 'state/providers.dart';
import 'ui/main_window.dart';

/// 应用外壳：主题、`MaterialApp`、以及启动后**一次**的副作用。
///
/// 界面在 5b 接上（计划 5a 的占位页到此为止）：`home` 现在是真的
/// `MainWindow`。
class WinCliToolApp extends ConsumerStatefulWidget {
  const WinCliToolApp({super.key});

  @override
  ConsumerState<WinCliToolApp> createState() => _WinCliToolAppState();
}

class _WinCliToolAppState extends ConsumerState<WinCliToolApp> {
  @override
  void initState() {
    super.initState();
    // FR-C-14：启动时对 `autoConnect == true` 的设备各发起一次连接。
    //
    // 放在**首帧之后**（`addPostFrameCallback`）而不是 `initState` 里直接调：
    // 那一次扫描会 `ref.read(sessionProvider(...))`，而建 provider 的过程里
    // 会分配资源；在首帧之前做这些，用户看到的第一帧会被推迟（NFR-F-04）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      connectAutoConnectDevicesAtStartup(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(settingsProvider.select((s) => s.theme));

    return MaterialApp(
      title: '网络设备命令行工具',
      themeMode: switch (theme) {
        AppTheme.system => ThemeMode.system,
        AppTheme.light => ThemeMode.light,
        AppTheme.dark => ThemeMode.dark,
      },
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
      ),
      home: const MainWindow(),
    );
  }
}
