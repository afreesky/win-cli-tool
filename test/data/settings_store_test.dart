import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/load_issue.dart';
import 'package:win_cli_tool/data/settings_store.dart';
import 'package:win_cli_tool/models/app_settings.dart';

void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_settings_');
    file = File('${root.path}/settings.json');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  SettingsStore store() => SettingsStore(file: file);

  test('文件不存在时给全默认值，无 issue', () async {
    final result = await store().load();
    expect(result.settings.commandTimeoutMs, 10000);
    expect(result.settings.promptDebounceMs, 120);
    expect(result.settings.connectTimeoutMs, 15000);
    expect(result.settings.verifySshHostKey, isTrue);
    expect(result.settings.logEnabled, isTrue);
    expect(result.settings.logDir, isNull);
    expect(result.settings.theme, AppTheme.system);
    expect(result.settings.outputBufferLines, 5000);
    expect(result.issues, isEmpty);
  });

  test('存盘后读回来逐字段一致', () async {
    const original = AppSettings(
      commandTimeoutMs: 3000,
      promptDebounceMs: 50,
      defaultPromptRegex: r'[$#]\s*$',
      morePromptPatterns: ['--More--'],
      logEnabled: false,
      logDir: '/tmp/wct-logs',
      verifySshHostKey: false,
      theme: AppTheme.dark,
      editorSplitRatio: 0.6,
      outputBufferLines: 100,
    );
    await store().save(original);

    final back = (await store().load()).settings;
    expect(back.commandTimeoutMs, 3000);
    expect(back.promptDebounceMs, 50);
    expect(back.defaultPromptRegex, r'[$#]\s*$');
    expect(back.morePromptPatterns, ['--More--']);
    expect(back.logEnabled, isFalse);
    expect(back.logDir, '/tmp/wct-logs');
    expect(back.verifySshHostKey, isFalse);
    expect(back.theme, AppTheme.dark);
    expect(back.editorSplitRatio, 0.6);
    expect(back.outputBufferLines, 100);
  });

  test('schemaVersion 写成 1', () async {
    await store().save(const AppSettings());
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['schemaVersion'], 1);
  });

  test('整个文件不是 JSON：留档 + 默认值 + 上报', () async {
    await file.writeAsString('{坏了');
    final result = await store().load();
    expect(result.settings.commandTimeoutMs, 10000);
    expect(result.issues.single.kind, LoadIssueKind.corruptFile);
    expect(file.existsSync(), isFalse);
    expect(
      root.listSync().where((e) => e.path.contains('.bad-')),
      hasLength(1),
    );
  });

  test('缺少 schemaVersion：读得出来，但上报 migrated', () async {
    await file.writeAsString(jsonEncode({'commandTimeoutMs': 7000}));
    final result = await store().load();
    expect(result.settings.commandTimeoutMs, 7000);
    expect(result.issues.single.kind, LoadIssueKind.migrated);
  });

  test('比当前更新的 schemaVersion：仍然读，但上报 newerSchema', () async {
    await file.writeAsString(
      jsonEncode({'schemaVersion': 99, 'commandTimeoutMs': 7000}),
    );
    final result = await store().load();
    expect(result.settings.commandTimeoutMs, 7000);
    expect(result.issues.single.kind, LoadIssueKind.newerSchema);
  });

  test('schemaVersion 不是整数：不静默读入，要上报 newerSchema', () async {
    // `"2"` / `2.0` / `true` 都不是本程序写出来的形状（手改，或将来某个写入方
    // 当字符串写）。**不能当没看见** —— `load_issue.dart` 自己就说"沉默地读错
    // 比报错更糟"。判法与 DeviceStore 一致（那里也是 `version is! int ||`）。
    for (final bad in <Object>['2', 2.0, true]) {
      await file.writeAsString(
        jsonEncode({'schemaVersion': bad, 'commandTimeoutMs': 7000}),
      );
      final result = await store().load();
      expect(
        result.issues.map((i) => i.kind),
        contains(LoadIssueKind.newerSchema),
        reason: 'schemaVersion=$bad 时必须上报，而不是静默按当前版本读入',
      );
    }
  });

  test('翻页模式里有非字符串：留档 + 默认值（惰性视图必须被强制求值）', () async {
    await file.writeAsString(jsonEncode({
      'schemaVersion': 1,
      'morePromptPatterns': ['--More--', 42],
    }));
    final result = await store().load();
    expect(result.settings.morePromptPatterns, ['---- More ----', '--More--', '<--- More --->'],
        reason: '不炸、用默认值 —— 而不是留一个会在界面遍历时炸的惰性视图');
    expect(result.issues.single.kind, LoadIssueKind.corruptFile);
    expect(file.existsSync(), isFalse, reason: '坏文件已留档');
  });

  test('未知主题名降级为跟随系统，不算损坏', () async {
    await file.writeAsString(
      jsonEncode({'schemaVersion': 1, 'theme': '未来主题'}),
    );
    final result = await store().load();
    expect(result.settings.theme, AppTheme.system);
    expect(result.issues, isEmpty, reason: 'AppTheme.fromName 的兜底是既定的，不是损坏');
  });

  test('存盘后文件权限是 0600（NFR-S-04）', () async {
    await store().save(const AppSettings());
    expect((await file.stat()).mode & 0x1FF, 0x180);
  });
}
