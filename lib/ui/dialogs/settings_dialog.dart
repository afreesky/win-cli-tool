import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_settings.dart';
import '../../state/providers.dart';
import 'known_hosts_section.dart';

/// 主题的三个人话名字。
String themeLabel(AppTheme theme) => switch (theme) {
  AppTheme.system => '跟随系统',
  AppTheme.light => '浅色',
  AppTheme.dark => '深色',
};

/// 设置对话框（FR-G-01/02、FR-C-13）。
///
/// **一次写入**：所有字段先存在本地状态里，点「保存」才 `update` 一次。
/// 逐个字段即时写盘也能做，但那样"取消"就没有意义了，而用户在设置里改错的
/// 时候最需要的恰恰是一个能反悔的出口。
///
/// **模态让快照安全**：本类在 `initState` 抓一份 `AppSettings`，界面上的
/// 改动都基于它。对话框开着的时候用户没法去拖分隔条（模态屏障挡住了），
/// 所以不存在"保存时覆盖掉别处刚改的值"。
class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const SettingsDialog(),
  );

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  late final TextEditingController _commandTimeout;
  late final TextEditingController _promptDebounce;
  late final TextEditingController _connectTimeout;
  late final TextEditingController _defaultPromptRegex;
  late final TextEditingController _morePatterns;
  late final TextEditingController _logDir;

  late bool _logEnabled;
  late bool _verifyHostKey;
  late AppTheme _theme;
  late double _splitRatio;

  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // `read` 一次取快照。**不是 `watch`** —— 那样每次 `update`（包括本对话框
    // 自己保存引起的那次）都会把界面上的编辑重置成刚落盘的值。
    final s = ref.read(settingsProvider);
    _commandTimeout = TextEditingController(text: '${s.commandTimeoutMs}');
    _promptDebounce = TextEditingController(text: '${s.promptDebounceMs}');
    _connectTimeout = TextEditingController(text: '${s.connectTimeoutMs}');
    _defaultPromptRegex = TextEditingController(text: s.defaultPromptRegex);
    _morePatterns = TextEditingController(text: s.morePromptPatterns.join('\n'));
    _logDir = TextEditingController(text: s.logDir ?? '');
    _logEnabled = s.logEnabled;
    _verifyHostKey = s.verifySshHostKey;
    _theme = s.theme;
    _splitRatio = s.editorSplitRatio;
  }

  @override
  void dispose() {
    for (final c in [
      _commandTimeout,
      _promptDebounce,
      _connectTimeout,
      _defaultPromptRegex,
      _morePatterns,
      _logDir,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 解析一个"必须是正整数"的字段。
  ///
  /// [allowZero] 只给去抖时长开 —— 0 是"不去抖"，是合法且有用的值；而超时
  /// 为 0 会让每条命令当场超时，那不是设置，是故障。
  int? _positiveInt(
    TextEditingController c,
    String label, {
    bool allowZero = false,
  }) {
    final value = int.tryParse(c.text.trim());
    final min = allowZero ? 0 : 1;
    if (value == null || value < min) {
      _error = allowZero ? '$label 必须是 0 或正整数' : '$label 必须是正整数';
      return null;
    }
    return value;
  }

  Future<void> _submit() async {
    setState(() => _error = null);

    final commandTimeout = _positiveInt(_commandTimeout, '命令执行超时');
    if (commandTimeout == null) return setState(() {});
    final promptDebounce = _positiveInt(
      _promptDebounce,
      '提示符去抖时长',
      allowZero: true,
    );
    if (promptDebounce == null) return setState(() {});
    final connectTimeout = _positiveInt(_connectTimeout, '建连超时');
    if (connectTimeout == null) return setState(() {});

    final regex = _defaultPromptRegex.text.trim();
    if (regex.isEmpty) {
      setState(() => _error = '默认提示符正则可以改，但不能是空的');
      return;
    }
    try {
      RegExp(regex);
    } on FormatException catch (e) {
      setState(() => _error = '默认提示符正则无法编译：${e.message}');
      return;
    }

    final patterns = _morePatterns.text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (patterns.isEmpty) {
      // **空了会让翻页功能静默失效**：设备吐 `--More--` 时没人认得出它，
      // 那条命令会一直等到 `commandTimeout` 才结束。用户看到的是"命令变慢了"，
      // 而原因在设置里。
      setState(() => _error = '翻页匹配模式至少要有一条');
      return;
    }

    final logDirText = _logDir.text.trim();
    final next = ref.read(settingsProvider).copyWith(
      commandTimeoutMs: commandTimeout,
      promptDebounceMs: promptDebounce,
      connectTimeoutMs: connectTimeout,
      defaultPromptRegex: regex,
      morePromptPatterns: patterns,
      logEnabled: _logEnabled,
      // **显式传 null 才能清掉**（`copyWith` 的 `_unset` 哨兵）。
      logDir: logDirText.isEmpty ? null : logDirText,
      verifySshHostKey: _verifyHostKey,
      theme: _theme,
      editorSplitRatio: _splitRatio,
    );

    setState(() => _busy = true);
    try {
      await ref.read(settingsProvider.notifier).update(next);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '设置未能保存：$error';
      });
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('settings-command-timeout'),
                controller: _commandTimeout,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '命令执行超时（毫秒）',
                  helperText: '单条命令超过这个时间没有回显就算超时（FR-E-12）',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('settings-prompt-debounce'),
                controller: _promptDebounce,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '提示符静默去抖（毫秒）',
                  helperText: '0 表示不去抖：收到提示符就立刻认定上一条命令结束',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('settings-connect-timeout'),
                controller: _connectTimeout,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '建连超时（毫秒）',
                  helperText: 'FR-C-13：超过这个时间还没连上就判失败',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('settings-default-prompt-regex'),
                controller: _defaultPromptRegex,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: '全局默认提示符正则',
                  helperText: '设备自己填了提示符正则时以设备的为准（FR-G-03）',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('settings-more-patterns'),
                controller: _morePatterns,
                maxLines: 3,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: '翻页匹配模式（一行一条）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const ValueKey('settings-log-enabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('保存会话日志'),
                value: _logEnabled,
                onChanged: (next) => setState(() => _logEnabled = next),
              ),
              TextField(
                key: const ValueKey('settings-log-dir'),
                controller: _logDir,
                decoration: const InputDecoration(
                  labelText: '日志目录（留空 = 应用数据目录下的 logs/）',
                ),
              ),
              const Divider(height: 24),
              SwitchListTile(
                key: const ValueKey('settings-verify-host-key'),
                contentPadding: EdgeInsets.zero,
                title: const Text('校验 SSH 主机密钥'),
                subtitle: const Text(
                  '关掉之后不再询问指纹，任何主机密钥都会被接受 —— '
                  '只在完全可控的实验环境里关它。',
                  style: TextStyle(fontSize: 12),
                ),
                value: _verifyHostKey,
                onChanged: (next) => setState(() => _verifyHostKey = next),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<AppTheme>(
                key: const ValueKey('settings-theme'),
                initialValue: _theme,
                decoration: const InputDecoration(labelText: '主题'),
                items: [
                  for (final t in AppTheme.values)
                    DropdownMenuItem(value: t, child: Text(themeLabel(t))),
                ],
                onChanged: (next) {
                  if (next == null) return;
                  setState(() => _theme = next);
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('编辑区占比'),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('settings-split-ratio'),
                      // **上下界与拖动分隔条时的 clamp 一致**（`main_window.dart`
                      // 的 `.clamp(0.15, 0.85)`）—— 两处不同的话，用滑杆设成
                      // 0.9 之后一拖分隔条就会跳回 0.85。
                      min: 0.15,
                      max: 0.85,
                      value: _splitRatio,
                      label: '${(_splitRatio * 100).round()}%',
                      onChanged: (next) => setState(() => _splitRatio = next),
                    ),
                  ),
                  Text('${(_splitRatio * 100).round()}%'),
                ],
              ),
              const Divider(height: 24),
              // **在 `_error` 之前**：这一段的读写是即时的，与下面那个
              // 「保存」按钮无关（见它的文档）。
              const KnownHostsSection(),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
