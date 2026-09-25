import 'dart:io';

/// 应用数据目录下的各处路径。
///
/// **只做路径拼接，不碰文件系统。** 目录存不存在由各个 store 自己负责
/// （`DraftStore` 第一次写会建目录，`writeJsonObject` 会 `create(recursive: true)`）
/// —— 在这里 `create()` 会让"构造一个路径对象"变成一次 IO，测试与将来的
/// 只读场景都不需要它。
class AppPaths {
  const AppPaths(this.root);

  /// 应用数据目录。`main()` 用 `path_provider` 的
  /// `getApplicationSupportDirectory()` 取（NFR-P-04：Windows 在 `%APPDATA%` 下，
  /// Linux 在 `$XDG_DATA_HOME`（默认 `~/.local/share`）下的应用子目录）；
  /// 测试里直接给一个临时目录。
  final Directory root;

  File get devicesFile => File('${root.path}/devices.json');
  File get settingsFile => File('${root.path}/settings.json');
  File get knownHostsFile => File('${root.path}/known_hosts.json');
  Directory get draftsDir => Directory('${root.path}/drafts');

  /// 日志根目录。FR-L-02 允许设置里覆盖（`AppSettings.logDir`），
  /// 那一条由调用方处理 —— 这里给的是"没覆盖时"的默认值。
  Directory get logsDir => Directory('${root.path}/logs');
}
