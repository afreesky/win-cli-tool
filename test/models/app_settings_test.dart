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
      expect(restored.outputBufferLines, 1000);
    });

    test('字段缺失时回落到默认值（向前兼容旧配置文件）', () {
      final restored = AppSettings.fromJson(const <String, Object?>{});

      expect(restored.promptDebounceMs, 120);
      expect(restored.theme, AppTheme.system);
      expect(restored.verifySshHostKey, isTrue);
      expect(restored.outputBufferLines, 5000);
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
  });
}
