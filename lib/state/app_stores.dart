import '../data/credential_store.dart';
import '../data/device_store.dart';
import '../data/draft_store.dart';
import '../data/host_key_store.dart';
import '../data/settings_store.dart';
import 'app_paths.dart';

/// 持久化层的**唯一**实例集合。
///
/// 每个 store 都建在这里，且**只建一次** —— `late final` 让这件事成为构造上的
/// 事实，而不是"记得别建第二个"的纪律。两个 store 的文档都警告过它：
/// `DeviceStore` 的 `jumpHosts` 写回、`FileHostKeyStore` 的读-改-写，都曾经
/// 因为"同一个文件被两个实例各持一份状态"而**静默丢用户数据**（那两处已经
/// 各自改成不依赖实例状态，但装配层仍然只该有一份）。
class AppStores {
  AppStores({
    required this.paths,
    this.credentials = const PlaintextCredentialStore(),
  });

  final AppPaths paths;

  /// **NFR-S-01 的接缝。** V1 装的是明文实现（已接受的决策），换成系统密钥库时
  /// 只换这一个实参 —— `DeviceStore` 与 `DeviceProfile` 一行都不用改。
  final CredentialStore credentials;

  late final DeviceStore devices = DeviceStore(
    file: paths.devicesFile,
    credentials: credentials,
  );

  late final SettingsStore settings = SettingsStore(file: paths.settingsFile);

  /// `FileHostKeyStore` 而不是 `HostKeyStore`：FR-G-01 的「查看与逐条清除」
  /// 需要 `all()`，而它**刻意只加在具体类上**（见那个类的文档）。这里从具体
  /// 类型直接调用，不涉及向下转型。
  late final FileHostKeyStore hostKeys = FileHostKeyStore(
    file: paths.knownHostsFile,
  );

  late final DraftStore drafts = DraftStore(dir: paths.draftsDir);
}
