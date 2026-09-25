import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/app_settings.dart';

void main() {
  group('AppSettings', () {
    test('默认值符合 spec §8.6', () {
      const s = AppSettings();

      expect(s.defaultPromptRegex, r'[>#\]]\s*$');
      expect(s.promptDebounceMs, 120);
      expect(s.commandTimeoutMs, 10000);
      expect(s.connectTimeoutMs, 15000);
      expect(s.morePromptPatterns, [
        '---- More ----',
        '--More--',
        '<--- More --->',
      ]);
      expect(s.logEnabled, isTrue);
      expect(s.logDir, isNull);
      expect(s.verifySshHostKey, isTrue);
      expect(s.theme, AppTheme.system);
      expect(s.editorSplitRatio, 0.4);
      expect(s.deviceListWidth, 240);
      expect(s.outputBufferLines, 5000);
    });

    test('JSON 往返后所有字段保持一致', () {
      const original = AppSettings(
        defaultPromptRegex: r'>>>\s*$',
        promptDebounceMs: 200,
        commandTimeoutMs: 30000,
        connectTimeoutMs: 5000,
        morePromptPatterns: ['<SPACE>'],
        logEnabled: false,
        logDir: '/tmp/logs',
        verifySshHostKey: false,
        theme: AppTheme.dark,
        editorSplitRatio: 0.6,
        deviceListWidth: 320,
        outputBufferLines: 1000,
      );

      final restored = AppSettings.fromJson(original.toJson());

      expect(restored.defaultPromptRegex, r'>>>\s*$');
      expect(restored.promptDebounceMs, 200);
      expect(restored.commandTimeoutMs, 30000);
      expect(restored.connectTimeoutMs, 5000);
      expect(restored.morePromptPatterns, ['<SPACE>']);
      expect(restored.logEnabled, isFalse);
      expect(restored.logDir, '/tmp/logs');
      expect(restored.verifySshHostKey, isFalse);
      expect(restored.theme, AppTheme.dark);
      expect(restored.editorSplitRatio, 0.6);
      expect(restored.deviceListWidth, 320);
      expect(restored.outputBufferLines, 1000);
    });

    test('字段缺失时全部回落到默认值（向前兼容旧配置文件）', () {
      // 逐个字段与「构造函数的默认值」比对，而不是写死字面量：这样
      // fromJson 里的回落值与构造函数默认值一旦只改了一边，测试就会失败。
      const defaults = AppSettings();

      final restored = AppSettings.fromJson(const <String, Object?>{});

      expect(restored.defaultPromptRegex, defaults.defaultPromptRegex);
      expect(restored.promptDebounceMs, defaults.promptDebounceMs);
      expect(restored.commandTimeoutMs, defaults.commandTimeoutMs);
      expect(restored.connectTimeoutMs, defaults.connectTimeoutMs);
      expect(restored.morePromptPatterns, defaults.morePromptPatterns);
      expect(restored.logEnabled, defaults.logEnabled);
      expect(restored.logDir, defaults.logDir);
      expect(restored.verifySshHostKey, defaults.verifySshHostKey);
      expect(restored.theme, defaults.theme);
      expect(restored.editorSplitRatio, defaults.editorSplitRatio);
      expect(restored.deviceListWidth, defaults.deviceListWidth);
      expect(restored.outputBufferLines, defaults.outputBufferLines);
    });

    test('整数形式的 editorSplitRatio 也能解析', () {
      final restored =
          AppSettings.fromJson(const <String, Object?>{'editorSplitRatio': 1});
      expect(restored.editorSplitRatio, 1.0);
    });

    test('未知主题名回落到 system 而非抛错', () {
      final restored =
          AppSettings.fromJson(const <String, Object?>{'theme': 'solarized'});
      expect(restored.theme, AppTheme.system);
    });

    test('copyWith 只改指定字段', () {
      const s = AppSettings();
      final t = s.copyWith(theme: AppTheme.light, commandTimeoutMs: 1000);

      expect(t.theme, AppTheme.light);
      expect(t.commandTimeoutMs, 1000);
      expect(t.promptDebounceMs, 120);
      expect(t.verifySshHostKey, isTrue);
    });

    test('copyWith 能把 logDir 显式清回 null（回落默认日志目录）', () {
      const s = AppSettings(logDir: '/tmp/logs');

      // 不传 → 保留
      expect(s.copyWith(theme: AppTheme.dark).logDir, '/tmp/logs');

      // 显式传 null → 清空，回到「用应用数据目录下的 logs/」
      expect(s.copyWith(logDir: null).logDir, isNull);

      // null → 设新值：用户第一次指定日志目录
      expect(
        const AppSettings().copyWith(logDir: '/var/log').logDir,
        '/var/log',
      );
    });
  });
}
