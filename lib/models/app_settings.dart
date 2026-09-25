/// 主题偏好。
enum AppTheme {
  system,
  light,
  dark;

  static AppTheme fromName(String name) => AppTheme.values.firstWhere(
        (t) => t.name == name,
        orElse: () => AppTheme.system,
      );
}

/// 「调用方没传这个参数」的哨兵，用来区分它与「调用方显式传了 null」。
///
/// [AppSettings.logDir] 的 null 表示「用默认日志目录」，是有语义的值，
/// 不能被 `?? this.x` 吞掉 —— 否则用户清空日志目录后旧目录仍然生效（FR-G-01）。
const Object _unset = Object();

/// 全局设置。字段与 spec §8.6 的 settings.json 一一对应。
class AppSettings {
  const AppSettings({
    this.defaultPromptRegex = r'[>#\]]\s*$',
    this.promptDebounceMs = 120,
    this.commandTimeoutMs = 10000,
    this.connectTimeoutMs = 15000,
    this.morePromptPatterns = const [
      '---- More ----',
      '--More--',
      '<--- More --->',
    ],
    this.logEnabled = true,
    this.logDir,
    this.verifySshHostKey = true,
    this.theme = AppTheme.system,
    this.editorSplitRatio = 0.4,
    this.outputBufferLines = 5000,
    this.deviceListWidth = 240,
  });

  /// 提示符正则的全局默认值。
  final String defaultPromptRegex;

  /// 静默去抖时长（毫秒）。
  final int promptDebounceMs;

  /// 单条命令的执行超时（毫秒）。
  final int commandTimeoutMs;

  /// 建连超时（毫秒）。
  final int connectTimeoutMs;

  /// 翻页提示的匹配模式。
  final List<String> morePromptPatterns;

  final bool logEnabled;

  /// 日志根目录；null 表示用应用数据目录下的 logs/。
  final String? logDir;

  final bool verifySshHostKey;
  final AppTheme theme;

  /// 编辑区高度占比（0~1）。
  final double editorSplitRatio;

  /// 输出缓冲保留的最大行数。
  final int outputBufferLines;

  /// 设备列表宽度（像素）。
  final double deviceListWidth;

  AppSettings copyWith({
    String? defaultPromptRegex,
    int? promptDebounceMs,
    int? commandTimeoutMs,
    int? connectTimeoutMs,
    List<String>? morePromptPatterns,
    bool? logEnabled,
    Object? logDir = _unset,
    bool? verifySshHostKey,
    AppTheme? theme,
    double? editorSplitRatio,
    int? outputBufferLines,
    double? deviceListWidth,
  }) =>
      AppSettings(
        defaultPromptRegex: defaultPromptRegex ?? this.defaultPromptRegex,
        promptDebounceMs: promptDebounceMs ?? this.promptDebounceMs,
        commandTimeoutMs: commandTimeoutMs ?? this.commandTimeoutMs,
        connectTimeoutMs: connectTimeoutMs ?? this.connectTimeoutMs,
        morePromptPatterns: morePromptPatterns ?? this.morePromptPatterns,
        logEnabled: logEnabled ?? this.logEnabled,
        logDir: identical(logDir, _unset) ? this.logDir : logDir as String?,
        verifySshHostKey: verifySshHostKey ?? this.verifySshHostKey,
        theme: theme ?? this.theme,
        editorSplitRatio: editorSplitRatio ?? this.editorSplitRatio,
        outputBufferLines: outputBufferLines ?? this.outputBufferLines,
        deviceListWidth: deviceListWidth ?? this.deviceListWidth,
      );

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
        defaultPromptRegex:
            json['defaultPromptRegex'] as String? ?? r'[>#\]]\s*$',
        promptDebounceMs: json['promptDebounceMs'] as int? ?? 120,
        commandTimeoutMs: json['commandTimeoutMs'] as int? ?? 10000,
        connectTimeoutMs: json['connectTimeoutMs'] as int? ?? 15000,
        morePromptPatterns:
            (json['morePromptPatterns'] as List<Object?>? ?? const [
          '---- More ----',
          '--More--',
          '<--- More --->',
        ]).cast<String>(),
        logEnabled: json['logEnabled'] as bool? ?? true,
        logDir: json['logDir'] as String?,
        verifySshHostKey: json['verifySshHostKey'] as bool? ?? true,
        theme: AppTheme.fromName(json['theme'] as String? ?? 'system'),
        editorSplitRatio: (json['editorSplitRatio'] as num?)?.toDouble() ?? 0.4,
        outputBufferLines: json['outputBufferLines'] as int? ?? 5000,
        deviceListWidth: (json['deviceListWidth'] as num?)?.toDouble() ?? 240,
      );

  Map<String, Object?> toJson() => {
        'defaultPromptRegex': defaultPromptRegex,
        'promptDebounceMs': promptDebounceMs,
        'commandTimeoutMs': commandTimeoutMs,
        'connectTimeoutMs': connectTimeoutMs,
        'morePromptPatterns': morePromptPatterns,
        'logEnabled': logEnabled,
        'logDir': logDir,
        'verifySshHostKey': verifySshHostKey,
        'theme': theme.name,
        'editorSplitRatio': editorSplitRatio,
        'outputBufferLines': outputBufferLines,
        'deviceListWidth': deviceListWidth,
      };
}
