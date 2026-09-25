import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'state/app_paths.dart';
import 'state/app_stores.dart';
import 'state/providers.dart';

Future<void> main() async {
  // `path_provider` 走平台通道，必须先初始化绑定。
  WidgetsFlutterBinding.ensureInitialized();

  // NFR-P-04：Windows 在 `%APPDATA%` 下、Linux 在 `$XDG_DATA_HOME`
  // （默认 `~/.local/share`）下的应用子目录。
  final paths = AppPaths(await getApplicationSupportDirectory());
  final stores = AppStores(paths: paths);

  // **启动时把设备与设置一次性读出来**，此后所有 provider 都是同步的
  // （见 `AppStartup` 的文档）。
  //
  // 读失败不在这里兜：两个 store 的 `load()` 自己就把"文件坏了"变成
  // `LoadIssue` + 空配置（NFR-R-03），所以这里拿到的永远是个能用的结果 ——
  // 而那一堆 issue 会经 `issuesProvider` 展示给用户。
  //
  // 注意 `FileHostKeyStore` **不在**这里读：它与那两个 store 相反，坏了就
  // 响亮地失败（丢一条已知主机密钥 = 用户会在没被告知的情况下被重新问一次
  // 指纹）。它由第一次连接时的 `find()` 触发，失败会经 `ConnectionFailure`
  // 变成用户看得见的一句话。
  final deviceResult = await stores.devices.load();
  final settingsResult = await stores.settings.load();

  runApp(
    ProviderScope(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        logsDirPath.overrideWithValue(paths.logsDir.path),
        startupProvider.overrideWithValue(
          AppStartup(
            settings: settingsResult.settings,
            devices: deviceResult.devices,
            settingsIssues: settingsResult.issues,
            deviceIssues: deviceResult.issues,
          ),
        ),
      ],
      child: const WinCliToolApp(),
    ),
  );
}
