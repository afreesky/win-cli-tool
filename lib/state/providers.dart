import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/session_factory.dart';
import '../data/load_issue.dart';
import '../models/app_settings.dart';
import '../models/device_profile.dart';
import 'app_stores.dart';
import 'host_key_prompt.dart';
import 'output_buffer.dart';
import 'session_controller.dart';

/// 启动时**一次性**读出来的东西。
///
/// 由 `main()` 在 `runApp` 之前取好，经 `ProviderScope(overrides:)` 注入；
/// 测试里用临时目录做同样的事。
///
/// **做成同步的 `Provider` 而不是 `FutureProvider` 是刻意的。** 设备与设置是
/// 界面的起点，异步会让 `AsyncValue` 传染给每一个下游 provider，而界面就得为
/// "还没读出来"写一遍分支 —— 那个分支在任何一次真实启动里都到不了，却要一直
/// 维护。这一层异步只有启动那一处，把它摁在那里。
class AppStartup {
  const AppStartup({
    required this.settings,
    required this.devices,
    this.settingsIssues = const [],
    this.deviceIssues = const [],
  });

  final AppSettings settings;
  final List<DeviceProfile> devices;

  /// 加载期发现的问题，**必须展示给用户**（`LoadIssue` 的文档：每一条都对应
  /// 一件用户需要知道的事）。
  final List<LoadIssue> settingsIssues;
  final List<LoadIssue> deviceIssues;
}

/// 启动结果。**必须被覆盖** —— 没有默认值可给，因为"应用数据目录在哪"只有
/// `main()` 知道（`path_provider` 要走平台通道）。
final startupProvider = Provider<AppStartup>(
  (ref) => throw StateError(
    'startupProvider 必须由 main() 覆盖（见 lib/main.dart）',
  ),
);

/// 持久化层的唯一实例集合。
final appStoresProvider = Provider<AppStores>(
  (ref) => throw StateError(
    'appStoresProvider 必须由 main() 覆盖（见 lib/main.dart）',
  ),
);

/// 造会话的工厂。**在 `main()` 里覆盖成真的那个**（它需要已知主机密钥库与
/// 主机密钥确认回调）；测试里覆盖成夹具。
///
/// 默认实现直接用装配好的密钥库 —— 这样"忘了覆盖"也不会静默变成不校验
/// （那会让 NFR-S-03 形同虚设）。
final sessionFactoryProvider = Provider<SessionFactory>((ref) {
  final stores = ref.watch(appStoresProvider);
  final settings = ref.watch(settingsProvider);
  return SessionFactory(
    hostKeyStore: stores.hostKeys,
    connectTimeout: Duration(milliseconds: settings.connectTimeoutMs),
    // NFR-S-03 / FR-C-11：**默认开启**，用户可在设置里关掉。
    verifyHostKey: settings.verifySshHostKey,
    // FR-C-11 / NFR-S-03：**首次连接某主机时问用户。** 少了这一行，
    // `SessionFactory.onUnknownHostKey` 就是 null，而 `SshSession` 里那句
    // `await onUnknownHostKey?.call(candidate) ?? false` 于是恒为 false ——
    // 没有主机密钥能被登记，任何一台新设备都连不上。校验开着（默认）却
    // 谁也连不上，是这一版里最严重的一条。
    onUnknownHostKey: (host) =>
        ref.read(hostKeyPromptProvider.notifier).ask(host),
  );
});

/// 加载/保存期发现的问题，攒给界面展示。
class IssuesNotifier extends Notifier<List<LoadIssue>> {
  @override
  List<LoadIssue> build() {
    final startup = ref.read(startupProvider);
    return [...startup.deviceIssues, ...startup.settingsIssues];
  }

  void add(LoadIssue issue) => state = [...state, issue];

  void addAll(Iterable<LoadIssue> issues) => state = [...state, ...issues];

  /// 用户点过"知道了"。
  void dismissAll() => state = const [];
}

final issuesProvider = NotifierProvider<IssuesNotifier, List<LoadIssue>>(
  IssuesNotifier.new,
);

/// 全局设置。启动时读好的那一份是初值。
class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(startupProvider).settings;

  /// 存盘成功**之后**才改内存状态 —— 界面不会显示一个没落盘的设置。
  /// 存盘失败时异常原样抛给调用方，由界面提示（与 `DuplicateDeviceNameError`
  /// 同一种呈现方式）。
  Future<void> update(AppSettings next) async {
    await ref.read(appStoresProvider).settings.save(next);
    state = next;
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// 设备列表。数组顺序**就是**显示顺序（§13.2）。
class DevicesNotifier extends Notifier<List<DeviceProfile>> {
  @override
  List<DeviceProfile> build() => ref.read(startupProvider).devices;

  /// 新增一台设备，id 由本层生成（FR-D-01）。
  ///
  /// **id 不经用户输入**：它是 `DraftStore` 的文件名，而不区分大小写的卷上
  /// `A` 与 `a` 会落到同一个文件（两台设备共用一份草稿），Windows 的保留名
  /// （`CON`/`NUL`/`COM1`）更是"带扩展名依然保留"。小写 UUID 把这些一次排除。
  ///
  /// **逐字段重建，不要写 `draft.copyWith(id: newDeviceId())`** ——
  /// `DeviceProfile.copyWith` **不接受 `id`**（它刻意保留原 id：id 是身份，
  /// 其余字段才是可改的）。这里要的恰恰是换一个身份，所以只能重建。
  Future<DeviceProfile> add(DeviceProfile draft) async {
    final created = DeviceProfile(
      id: newDeviceId(),
      name: draft.name,
      protocol: draft.protocol,
      host: draft.host,
      port: draft.port,
      username: draft.username,
      password: draft.password,
      privateKeyPath: draft.privateKeyPath,
      enableCommand: draft.enableCommand,
      enablePassword: draft.enablePassword,
      jumpHostIds: draft.jumpHostIds,
      lineEnding: draft.lineEnding,
      promptRegex: draft.promptRegex,
      postLoginCommands: draft.postLoginCommands,
      autoConnect: draft.autoConnect,
      snippets: draft.snippets,
    );
    await _save([...state, created]);
    return created;
  }

  /// 按 id 替换（FR-D-05）。**不改顺序。**
  Future<void> update(DeviceProfile profile) async {
    await _save([
      for (final d in state) if (d.id == profile.id) profile else d,
    ]);
  }

  /// 删除（FR-D-06）：断开它的会话，一并删掉草稿。**日志保留。**
  Future<void> remove(String id) async {
    await _save(state.where((d) => d.id != id).toList(growable: false));
    // 顺序：先把它从列表里摘掉（内存与磁盘），再拆会话。反过来的话，
    // 拆会话期间界面还能看到一台"已经没了"的设备。
    ref.invalidate(sessionProvider(id));
    ref.invalidate(draftProvider(id));
    ref.invalidate(outputBufferProvider(id));
    await ref.read(appStoresProvider).drafts.delete(id);
  }

  /// 拖拽排序（FR-D-07）。
  ///
  /// **`devices.json` 没有 order 字段，数组顺序就是显示顺序** —— 所以排序唯一
  /// 的实现方式就是**重写整个数组**，`:memory:` 与磁盘都重写一遍。store 自己
  /// 逐条编码、不排序。
  Future<void> reorder(List<String> orderedIds) async {
    final byId = {for (final d in state) d.id: d};
    final next = <DeviceProfile>[];
    for (final id in orderedIds) {
      final device = byId.remove(id);
      if (device != null) next.add(device);
    }
    // 传进来的 id 少写了几个（界面 bug）时，剩下的**追加在后面**而不是丢掉 ——
    // 丢设备比顺序错更糟。
    next.addAll(byId.values);
    await _save(next);
  }

  /// 先存盘、成功了才改内存：界面不会显示一个没落盘的设备列表。
  ///
  /// `DeviceStore.save` 会**先全校验再动文件**，重名时抛
  /// [DuplicateDeviceNameError]（带可展示的 `message`）—— 异常原样抛给界面，
  /// 别在这里 catch 成 `'$e'`。
  Future<void> _save(List<DeviceProfile> next) async {
    await ref.read(appStoresProvider).devices.save(next);
    state = next;
  }
}

final devicesProvider =
    NotifierProvider<DevicesNotifier, List<DeviceProfile>>(DevicesNotifier.new);

/// 某台设备的编辑区草稿（FR-E-03/04）。不存在时是空串。
///
/// `build()` 会抛 [DraftUnreadableException]（不是 UTF-8，或读盘失败）——
/// **别把它降级成空串**，那会让用户以为"草稿没了"而其实文件还在。界面 catch
/// 它并提示（异常里有 `deviceId`）。
final draftProvider =
    AsyncNotifierProvider.family<DraftNotifier, String, String>(
      DraftNotifier.new,
    );

class DraftNotifier extends AsyncNotifier<String> {
  DraftNotifier(this.deviceId);

  final String deviceId;

  @override
  Future<String> build() =>
      ref.read(appStoresProvider).drafts.read(deviceId);

  /// 存草稿。**原子写**（`DraftStore` 走 `writeFileAtomically`）。
  Future<void> save(String text) async {
    await ref.read(appStoresProvider).drafts.write(deviceId, text);
    state = AsyncData(text);
  }
}

/// 某台设备的输出缓冲。**活得比一次会话长**（FR-O-09：切走再切回来还看得到
/// 完整过程），所以它在这里，不在 `SessionController` 里。
///
/// **和 `sessionProvider` 一样 `read` 而不是 `watch` 设置，理由是同一个，而且
/// 这里更严重。** `SessionNotifier.build()` 用 `ref.read` 把这个缓冲抓成
/// `SessionController` 的 `final` 字段；若本 provider `watch` 设置，那么**任何
/// 一次设置写入**（改主题、改编辑器比例、改缓冲行数）都会把它重建成一个**新的
/// 空缓冲** —— 界面从此读到那个空缓冲（输出区当场清空），而会话继续往**没人再看
/// 的那个旧缓冲**里写。这不只是显示问题：`SessionController` 抓的是旧实例，
/// 两者就此永久分家，FR-O-09 的"切走再切回来还看得到完整过程"在任何一次设置
/// 改动之后都不再成立。
///
/// 代价与 `sessionProvider` 相同、也同样是有意接受的：`outputBufferLines`
/// 改动在**下次会话**生效（缓冲活得和容器一样久，本 provider 不是 autoDispose）。
final outputBufferProvider =
    Provider.family<OutputBuffer, String>((ref, deviceId) {
  final settings = ref.read(settingsProvider);
  return OutputBuffer(maxLines: settings.outputBufferLines);
});

/// 某台设备的会话。
///
/// **不 `watch` 设置。** `SessionController` 在构造时就把 `logEnabled` /
/// `verifyHostKey` 这些读定了；若这里 `watch`，用户改任何一个设置都会重建
/// controller，而那会把**正在跑的会话拆掉** —— 改个主题就把线断掉。所以读一次，
/// 设置的改动在下次连接时生效（知情的取舍，换日志文件写到一半会留下两个文件）。
final sessionProvider =
    NotifierProvider.family<SessionNotifier, SessionStatus, String>(
      SessionNotifier.new,
    );

class SessionNotifier extends Notifier<SessionStatus> {
  SessionNotifier(this.deviceId);

  final String deviceId;

  /// 设备已被删除时为 null（见 `build()`）。此时本 provider 只剩一个"未连接"的
  /// 空状态，下面四个方法都退化成空操作 —— 已经没有界面会调它们，但也不能抛。
  SessionController? _controller;

  @override
  SessionStatus build() {
    final settings = ref.read(settingsProvider);
    final devices = ref.read(devicesProvider);
    final index = devices.indexWhere((d) => d.id == deviceId);
    if (index < 0) {
      // **设备已经不在了（FR-D-04 删除），这里不能抛。**
      //
      // `DevicesNotifier.remove()` 会 `invalidate` 本 provider，而设备列表里那一行
      // 此刻还在 `watch` 它（widget 要到下一帧才拆），于是 Riverpod 当场重建 ——
      // 原来那句 `firstWhere` 找不到设备，抛 `Bad state: No element`，
      // **删一台设备就把界面打红**（实测）。设备都没了，会话状态当然是"未连接"。
      _controller = null;
      return const SessionStatus();
    }
    final profile = devices[index];

    final controller = SessionController(
      profile: profile,
      factory: ref.read(sessionFactoryProvider),
      buffer: ref.read(outputBufferProvider(deviceId)),
      // FR-L-02：设置里给了就用设置里的，否则用应用数据目录下的 logs/
      // （`logsDirPath` 是 `Provider<String>`，由 `main()` 覆盖）。
      logsDir: Directory(settings.logDir ?? ref.read(logsDirPath)),
      logEnabled: settings.logEnabled,
      onLogError: (error) => ref
          .read(issuesProvider.notifier)
          .add(LoadIssue(LoadIssueKind.corruptFile, '日志写入失败：$error')),
    );
    _controller = controller;
    // controller 的状态变化（含从 `ConnectionManager` 来的那些）推给 Riverpod。
    controller.onStatus = (status) => state = status;
    ref.onDispose(controller.dispose);
    return controller.status;
  }

  Future<void> connect() async {
    await _controller?.connect();
  }

  Future<void> disconnect() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.disconnect();
    state = controller.status;
  }

  /// 把命令排进该设备的队列（FR-E-01）。队列在后台继续跑，切设备不影响它。
  void enqueue(List<String> commands) => _controller?.enqueue(commands);

  /// 中止队列（FR-E-13 / Esc）。
  void abort() => _controller?.abort();
}

/// 日志根目录的默认位置。由 `main()` 覆盖成应用数据目录下的 `logs/`。
final logsDirPath = Provider<String>(
  (ref) => throw StateError('logsDirPath 必须由 main() 覆盖（见 lib/main.dart）'),
);

/// 生成一个**小写**的设备 id。
///
/// 形状是 UUID v4，但**不引 uuid 包**：这里只要 122 位密码学随机数拼成小写
/// 十六进制，八行就够，而多一个直接依赖就要多写一段"为什么需要它"。
///
/// 小写是**要求**不是偏好：`DraftStore` 拿它当文件名，在不区分大小写的卷上
/// `A` 与 `a` 会落到同一个文件。UUID 的形状还顺带排除了 Windows 的保留设备名
/// （`CON`/`NUL`/`COM1` 带上扩展名依然保留）—— 那种名字必须有确定的长度才撞不上。
String newDeviceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // 版本 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // 变体 10xx
  final hex = bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

/// 生成一个命令片段的 id。
///
/// **与 [newDeviceId] 共用同一个生成器是刻意的**：片段 id 不是文件名（它只在
/// 同一台设备的 `snippets` 数组里唯一），所以大小写不敏感的卷、Windows 保留
/// 设备名这些理由对它都不成立；但再写一份随机数代码只会多一处要维护的东西。
/// 留一个具名函数是为了让调用点读起来是"片段 id"，而不是"设备 id 用在了片段上"。
String newSnippetId() => newDeviceId();

/// FR-C-14：启动时对 `autoConnect == true` 的设备各发起一次连接。
///
/// 由 `app.dart` 在首帧之后调用一次。**只调一次** —— 它不是"设备列表一变就连"，
/// 那会在用户每加一台设备时都试图连接（见 `app.dart` 的说明）。
///
/// **参数类型是 `WidgetRef` 而不是 `Ref`，这不是随手写的。** 调用点在
/// `ConsumerState` 里，那里的 `ref` 是 `WidgetRef`；而 `Ref` 是 **sealed**
/// （riverpod 的 `core/ref.dart`），`WidgetRef` 只 implements `BaseWidgetRef`
/// —— 两者**没有**子类型关系，写成 `Ref` 编译不过（"The argument type
/// 'WidgetRef' can't be assigned to the parameter type 'Ref'"）。本函数唯一的
/// 用途就是给 widget 层调，所以取 widget 那一侧的 ref 才是诚实的类型。
void connectAutoConnectDevicesAtStartup(WidgetRef ref) {
  connectAutoConnectDevices(
    devices: ref.read(devicesProvider),
    connect: (deviceId) =>
        unawaited(ref.read(sessionProvider(deviceId).notifier).connect()),
  );
}

/// 当前选中的设备（界面的选择状态）。
///
/// **它在状态层而不是某个 widget 的 State 里**：设备列表、编辑区、输出区三处
/// 都要读它，窗口级的快捷键也要读。
///
/// `build()` 用 `read` 取初始值，所以**删掉当前选中的设备之后它不会自动挪走**
/// —— 处理那件事的是设备列表面板的删除路径（先 select 再 remove）。主窗口另外
/// 还会挡一道：它只把"确实还在设备列表里"的 id 交给面板（见 `main_window.dart`
/// 的 `_active`），所以残留的过期选中不会让面板去建一个不存在的会话。
class SelectedDeviceNotifier extends Notifier<String?> {
  @override
  String? build() {
    final devices = ref.read(devicesProvider);
    return devices.isEmpty ? null : devices.first.id;
  }

  void select(String? id) => state = id;
}

final selectedDeviceProvider =
    NotifierProvider<SelectedDeviceNotifier, String?>(SelectedDeviceNotifier.new);
