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

/// `devices.json` 的读写（FR-D-10、NFR-R-03、NFR-R-04）。
class DeviceStore {
  DeviceStore({required this.file, required this.credentials});

  final File file;
  final CredentialStore credentials;

  /// 上一次读到的 `jumpHosts` 原文，存盘时**原样写回**。
  ///
  /// 跳板机已放弃（spec §10.2），V1 既不解释也不修改这个字段；留着的唯一目的是
  /// **不丢用户数据** —— 手写的 `jumpHosts` 不该被本程序的一次保存抹掉。
  List<Object?> _rawJumpHosts = const [];

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

    // 与下面 `devices` 的判法一致：**先查形状，不硬转**。`jumpHosts` 在 V1 里
    // 只剩"原样写回"一个用途（跳板机已放弃支持），所以形状不对时退回空数组就够了。
    // 但**绝不能**写成 `as List<Object?>?` —— 那是一个没有任何 try 兜着的强转，
    // 一个手改坏的 `"jumpHosts": "x"` 会让 load() 抛 _TypeError 出去：调用方拿不到
    // DeviceLoadResult、文件也不会被留档，于是**每次启动都崩**，正是 NFR-R-03 要防的。
    final rawJumpHosts = raw['jumpHosts'];
    _rawJumpHosts = rawJumpHosts is List<Object?> ? rawJumpHosts : const [];

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
}
