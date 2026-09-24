import 'dart:io';

import '../models/app_settings.dart';
import 'json_file.dart';
import 'load_issue.dart';

/// 当前 `settings.json` 的格式版本（spec §8.6）。
const int kSettingsSchemaVersion = 1;

/// [SettingsStore.load] 的结果。[issues] 与 `DeviceStore` 用同一套类型。
class SettingsLoadResult {
  const SettingsLoadResult({required this.settings, required this.issues});

  final AppSettings settings;
  final List<LoadIssue> issues;
}

/// `settings.json` 的读写（FR-G-02、NFR-R-03、NFR-R-04）。
class SettingsStore {
  SettingsStore({required this.file});

  final File file;

  /// 读盘。**读不出来的坏都给全默认值 + 上报**，绝不半读：
  /// 设置项之间没有依赖，用一半旧值一半默认值比全默认更让人困惑
  /// （用户会以为"我明明改过"）。
  ///
  /// **有一个既定的例外，别把上面那句读成没有例外**：`AppTheme.fromName` 对未知
  /// 主题名的兜底是**设计好的降级**，不算损坏 —— 那时别的字段照常从文件读出来，
  /// 只有 `theme` 落到"跟随系统"，而且**不上报**（测试「未知主题名降级为跟随系统，
  /// 不算损坏」钉的就是这条，它断言 `issues` 为空）。上面那个"坏"指的是**文件或
  /// 字段读不出来**（不是 JSON、类型不对），枚举名字不认识不在其内。
  Future<SettingsLoadResult> load() async {
    Map<String, Object?>? raw;
    try {
      raw = await readJsonObject(file);
    } on FormatException catch (e) {
      await quarantine(file, now: DateTime.now());
      return SettingsLoadResult(
        settings: const AppSettings(),
        issues: [
          LoadIssue(
            LoadIssueKind.corruptFile,
            '设置文件无法解析（$e）。已把原文件留档，本次使用默认设置。',
          ),
        ],
      );
    }

    if (raw == null) {
      return const SettingsLoadResult(settings: AppSettings(), issues: []);
    }

    final issues = <LoadIssue>[];
    final version = raw['schemaVersion'];
    if (version == null) {
      issues.add(
        const LoadIssue(LoadIssueKind.migrated, '设置文件没有版本号，已按当前格式读入。'),
      );
    } else if (version is! int || version > kSettingsSchemaVersion) {
      // `is! int` 那一半是必须的：`"schemaVersion": "2"`（手改出来的，或将来某个
      // 写入方当字符串写）否则会**静默**按当前语义读入 —— 而 load_issue.dart
      // 自己就说"沉默地读错比报错更糟"。判法与 DeviceStore 一致（那里同样是
      // `version is! int ||`）。
      issues.add(
        LoadIssue(
          LoadIssueKind.newerSchema,
          '设置来自更新版本的程序（schemaVersion=$version），'
          '按当前版本读入，可能有设置项没读懂。',
        ),
      );
    }

    try {
      final settings = AppSettings.fromJson(raw);
      // **强制求值一次。** `fromJson` 里 `morePromptPatterns` 用的是
      // `.cast<String>()`：那是惰性校验视图（spec §13.6），坏元素要到界面
      // 第一次遍历它时才抛 —— 而那时早已离开这个 try，用户看到的是崩溃
      // 而不是"设置文件坏了，已用默认值"。收一遍就把失败提到了加载期。
      settings.morePromptPatterns.toList(growable: false);
      return SettingsLoadResult(settings: settings, issues: issues);
    } catch (e) {
      await quarantine(file, now: DateTime.now());
      return SettingsLoadResult(
        settings: const AppSettings(),
        issues: [
          ...issues,
          LoadIssue(
            LoadIssueKind.corruptFile,
            '设置文件里的字段无法读取（$e）。已把原文件留档，本次使用默认设置。',
          ),
        ],
      );
    }
  }

  Future<void> save(AppSettings settings) async {
    await writeJsonObject(file, {
      'schemaVersion': kSettingsSchemaVersion,
      ...settings.toJson(),
    });
  }
}
