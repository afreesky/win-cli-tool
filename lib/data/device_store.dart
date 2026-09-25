import 'dart:io';

import '../models/device_profile.dart';
import 'credential_store.dart';
import 'json_file.dart';
import 'load_issue.dart';

// 让只 import device_store.dart 的调用方也能拿到问题类型 —— 它们是
// load() 返回值的一部分，要求调用方多 import 一个文件是没道理的。
export 'load_issue.dart';

/// 当前 `devices.json` 的格式版本（spec §8.6）。
///
/// 2 的由来是新增了 `jumpHosts` 字段。跳板机已于 2026-09-25 整体放弃
/// （spec §10.2），但**版本号不降** —— 磁盘上已经有 v2 文件了，
/// 降回 1 会让它们全被当成"来自更新的版本"。
const int kDevicesSchemaVersion = 2;

/// [DeviceStore.load] 的结果。
///
/// 返回一个结果对象而不是只返回列表，是因为**问题本身是结果的一部分**：
/// 只返回 `List<DeviceProfile>` 的话，"文件坏了"和"本来就没有设备"
/// 在调用方看来一模一样，而这两者要给用户看的东西完全不同。
class DeviceLoadResult {
  const DeviceLoadResult({required this.devices, required this.issues});

  final List<DeviceProfile> devices;
  final List<LoadIssue> issues;
}

/// 设备名称重复（FR-D-04：名称在列表内必须唯一）。
///
/// **在存盘时抛出，而不是提供一个 `bool isNameTaken` 让调用方自己判断。**
/// 唯一性是**文件级**不变量：单看一个 profile 判断不了，必须看整个列表；
/// 让调用方自己判，就总有那么一条路径忘了判，而后果是写出一个读不回来
/// （或读回来两台同名）的文件。
class DuplicateDeviceNameError implements Exception {
  const DuplicateDeviceNameError(this.name);

  final String name;

  /// 可直接展示给用户的中文说明。与 [LoadIssue.message] 以及
  /// `ConnectionFailure.message` 一致 —— 界面对这三者的渲染方式应该是同一种，
  /// 别让计划 5 去 `'$e'`（那会把异常的 `toString()` 直接摆给用户）。
  String get message => '设备名称重复：$name';

  @override
  String toString() => message;
}

/// `devices.json` 的读写（FR-D-10、NFR-R-03、NFR-R-04）。
class DeviceStore {
  DeviceStore({required this.file, required this.credentials});

  final File file;
  final CredentialStore credentials;

  /// 读出盘上**当前**的 `jumpHosts` 原文，供存盘时原样写回。
  ///
  /// 跳板机已放弃（spec §10.2），V1 既不解释也不修改这个字段；留着的唯一目的是
  /// **不丢用户数据** —— 手写的 `jumpHosts` 不该被本程序的一次保存抹掉。
  ///
  /// **为什么每次都读盘，而不是拿"本实例读到的那一份"：** 后者是个静默丢数据的
  /// 陷阱。`load()` 与 `save()` 一旦落在**不同实例**上（装配层读、界面另建一个写、
  /// 或将来某个后台任务自己 new 一个），写回的是初始值 `const []`，文件里手写的
  /// 堡垒机配置**被抹成空数组**，而这条路径上没有任何东西会报错 —— 用户要等到
  /// 哪天去查跳板机配置才发现。读盘是唯一让"存盘结果与本实例无关"的做法。
  ///
  /// 代价是每次存盘多读一次文件。存盘是用户动作（加/改/删设备），不是热路径。
  Future<List<Object?>> _rawJumpHostsFromDisk() async {
    // **读不回来时退回空数组，不抛。** 这里是**存盘**路径：用户此刻正在改配置，
    // 多半就是想修好一个坏文件，为此抛出去等于把人锁在门外。真正的损坏上报在
    // `load()` 那边（`LoadIssueKind.corruptFile`），不在这里重复。
    try {
      final raw = await readJsonObject(file);
      final jumpHosts = raw?['jumpHosts'];
      // 与 `load()` 里同一条判法：**先查形状，不硬转**。`as List<Object?>?` 是
      // 一次没有 try 兜着的强转，手改坏的 `"jumpHosts": "x"` 会让存盘直接抛。
      return jumpHosts is List<Object?> ? jumpHosts : const [];
    } catch (_) {
      return const [];
    }
  }

  /// 读盘。
  ///
  /// 三层容错，从外到内：整个文件读不出设备 → 空配置（**解析失败时先留档**，
  /// 见 [LoadIssueKind.corruptFile] 对两种情况的区分）；某一条坏 → 跳过该条；
  /// 字段级问题（v1 缺字段、跳板机 id）→ 补默认值 + 上报。
  Future<DeviceLoadResult> load() async {
    final issues = <LoadIssue>[];

    Map<String, Object?>? raw;
    try {
      raw = await readJsonObject(file);
    } on FormatException catch (e) {
      await quarantine(file, now: DateTime.now());
      return DeviceLoadResult(
        devices: const [],
        issues: [
          LoadIssue(
            LoadIssueKind.corruptFile,
            '设备配置文件无法解析（$e）。已把原文件留档，本次以空配置启动。',
          ),
        ],
      );
    }

    if (raw == null) {
      return const DeviceLoadResult(devices: [], issues: []);
    }

    final version = raw['schemaVersion'];
    if (version == null || version == 1) {
      issues.add(
        const LoadIssue(
          LoadIssueKind.migrated,
          '设备配置是老版本格式，已按新格式读入（补齐跳板机相关字段）。',
        ),
      );
      // `is! int` 那一半是必须的：`"schemaVersion": "3"`（手改出来的，或将来某个
      // 写入方当字符串写）否则会**静默**按当前语义读入 —— 而 load_issue.dart 自己
      // 就说"沉默地读错比报错更糟"。
    } else if (version is! int || version > kDevicesSchemaVersion) {
      issues.add(
        LoadIssue(
          LoadIssueKind.newerSchema,
          '设备配置来自更新版本的程序（schemaVersion=$version），'
          '按当前版本读入，可能有字段没读懂。',
        ),
      );
    }

    final rawDevices = raw['devices'];
    if (rawDevices is! List<Object?>) {
      return DeviceLoadResult(
        devices: const [],
        issues: [
          ...issues,
          const LoadIssue(
            LoadIssueKind.corruptFile,
            '设备配置里没有 devices 数组，本次以空配置启动。',
          ),
        ],
      );
    }

    final devices = <DeviceProfile>[];
    for (var i = 0; i < rawDevices.length; i++) {
      final entry = rawDevices[i];
      try {
        if (entry is! Map) {
          throw FormatException('第 $i 条不是 JSON 对象');
        }
        // `.from` 是**立即**拷贝并校验键类型；`.cast` 是惰性视图，
        // 会把错误推迟到后面某次读取，报错位置离原因更远（spec §13.6）。
        final record = Map<String, Object?>.from(entry);
        final password = credentials.read(record);
        final profile =
            DeviceProfile.fromJson(credentials.strip(record)).copyWith(
          password: password,
        );
        // **把惰性视图收一遍，而且必须在 add 之前。** 模型里 `postLoginCommands`
        // 与 `jumpHostIds` 用的是 `.cast<String>()`（spec §13.6）—— 那是惰性校验
        // 视图，坏元素要到有人**第一次遍历它**时才抛，而那时早已离开这个 try：
        // `postLoginCommands` 是在连接时被 `ConnectionManager` 入队才遍历的，
        // 用户看到的是"连不上"而不是"第 N 条设备记录坏了，已跳过"。
        //
        // **收在 add 之后是错的**（实测过）：那样这一条已经进了 devices，catch 只
        // 补一条 corruptEntry，坏记录**照样留在列表里** —— 症状从"连接时崩"变成
        // "加载时报告坏了、却还是用它"，比原来更难查。抛在 add 之前，它才真的被跳过。
        // （与 settings_store.dart 收 `morePromptPatterns` 是同一个理由。）
        profile.postLoginCommands.toList(growable: false);
        profile.jumpHostIds.toList(growable: false);

        // 跳板机提示也放在 add **之前**，理由同上：这里读的同样是模型的惰性
        // `.cast<String>()`。今天 `isNotEmpty` 只看长度、不遍历元素，所以安全；
        // 但哪天有人把这条消息改成列举跳板机 id，遍历就会抛在 add 之后，
        // 又变回"报告了坏、却还留着"。
        if (profile.jumpHostIds.isNotEmpty) {
          issues.add(
            LoadIssue(
              LoadIssueKind.jumpHostIgnored,
              '设备「${profile.name}」配置了跳板机，但当前版本不支持跳板机，'
              '将直接连接。',
            ),
          );
        }

        devices.add(profile);
      } catch (e) {
        // catch 的宽度是「构造一条记录时抛出的**任何**错误」，不是 on TypeError：
        // 模型自己会做值校验并抛 ArgumentError（§13.3）。
        issues.add(
          LoadIssue(
            LoadIssueKind.corruptEntry,
            '第 $i 条设备记录无法读取，已跳过：$e',
          ),
        );
      }
    }

    return DeviceLoadResult(devices: devices, issues: issues);
  }

  /// 存盘。**先全校验，再动文件**（原因见 [DuplicateDeviceNameError]）。
  ///
  /// 顺序即显示顺序（§13.2）：本方法逐条编码，**不排序**。
  ///
  /// **只校验名称唯一，不校验 id。** id 由计划 5 生成，唯一性归它管 —— 这里是
  /// **有意的留白，不是漏了**；真出现两个同 id，密钥库实现会把两者的凭据串起来。
  ///
  /// 另见 [_rawJumpHostsFromDisk]：`jumpHosts` **每次存盘都从盘上现读**，
  /// 所以存盘结果与本实例读没读过盘无关。
  Future<void> save(List<DeviceProfile> devices) async {
    final seen = <String>{};
    for (final device in devices) {
      if (!seen.add(device.name)) {
        throw DuplicateDeviceNameError(device.name);
      }
    }

    final encoded = <Object?>[];
    for (final device in devices) {
      // 凭据**只**经由接口进出（NFR-S-01）：先剥掉模型吐出来的凭据字段，
      // 再让接口决定它落在哪里 —— 明文实现会写回同一个字段，
      // 密钥库实现则什么都不写，于是文件里没有凭据。
      final record = credentials.strip(device.toJson());
      credentials.write(record, device.password);
      encoded.add(record);
    }

    await writeJsonObject(file, {
      'schemaVersion': kDevicesSchemaVersion,
      // 原样搬运，不解释也不修改 —— 跳板机已放弃（spec §10.2），
      // 这里唯一的目的就是别把用户手写的数据抹掉。
      'jumpHosts': await _rawJumpHostsFromDisk(),
      'devices': encoded,
    });
  }
}
