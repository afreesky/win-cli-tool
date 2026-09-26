import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/dialogs/settings_dialog.dart';

import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_settings_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  AppSettings stored(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.text('打开')),
  ).read(settingsProvider);

  Future<void> open(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(),
  }) async {
    // **这张对话框必须调 `useTallSurface`，而且十三条用例一条都躲不开。**
    // 内容是十来个控件摞起来的（三个带 helperText 的输入框 + 正则 + 三行的
    // 翻页框 + 两个 SwitchListTile + 日志目录 + 主题下拉 + 滑杆），实测高度
    // 远超过默认 800×600 窗口给对话框正文的那点地方 —— 而正文是包在
    // `SingleChildScrollView` 里的，**装不下不会报错，只会把靠下的控件挪到
    // 视口外面**：`tap` 空点一下、`enterText` 落不到那个框上，用例红在一句
    // 与它要验的东西毫无关系的断言上（Task 4 在设备编辑对话框上量到过同一
    // 件事：开关在 y=866，视口只有 384）。所以放在这个口上，一处管全部。
    await useTallSurface(tester);
    await pumpDialogHost(
      tester,
      root: root,
      buttonLabel: '打开',
      settings: settings,
      open: (context) => SettingsDialog.show(context),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester, String key, String text) =>
      tester.enterText(find.byKey(ValueKey(key)), text);

  /// 点「保存」并**等到对话框真的关掉**。
  ///
  /// **不能只 `settleDisk`。** `_submit` 是**先 `await update(next)`、再
  /// `pop()`**，所以"对话框关了"这件事本身就证明了设置已经写完了整条路径。
  /// `SettingsStore.save` 走 `writeJsonObject` → `writeFileAtomically`
  /// （建目录 → 写 `.tmp` → **两次 `chmod` 真进程** → rename），全是推不动
  /// 假时钟的真 I/O，`settleDisk` 那 12×5ms 够不够看机器当下忙不忙。
  ///
  /// 挡下的那几条用例（超时非法、正则编译不了……）**不走这个口** —— 它们
  /// 对话框不该关，自己 `tap` + `pumpAndSettle`。所以这里等"关掉"是安全的。
  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('保存'));
    await pumpUntilTrue(tester, () => find.text('保存').evaluate().isEmpty);
  }

  testWidgets('对话框里的初值就是当前设置（FR-G-01）', (tester) async {
    await open(
      tester,
      settings: const AppSettings(
        commandTimeoutMs: 20000,
        promptDebounceMs: 200,
        connectTimeoutMs: 30000,
        editorSplitRatio: 0.6,
        theme: AppTheme.dark,
        logEnabled: false,
        logDir: '/tmp/logs',
      ),
    );

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('settings-command-timeout')))
          .controller!
          .text,
      '20000',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('settings-prompt-debounce')))
          .controller!
          .text,
      '200',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('settings-connect-timeout')))
          .controller!
          .text,
      '30000',
      reason: 'FR-C-13：建连超时可在设置中调整',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('settings-log-dir')))
          .controller!
          .text,
      '/tmp/logs',
    );
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('settings-split-ratio')))
          .value,
      0.6,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('settings-log-enabled')))
          .value,
      isFalse,
    );
    // **不能用 `find.text('深色')` 断主题初值 —— 那条断言恒真。**
    // `DropdownButton` 把**所有**选项都塞进一个 `IndexedStack`，只画选中
    // 那一个（`dropdown.dart:1624`，`children: widget.isDense ? items : …`）。
    // 三个选项不管选谁都在元素树上，`find.text('深色')` 永远是
    // `findsOneWidget` —— 把 `_theme` 写死成 `AppTheme.light` 它照样绿。
    //
    // 断 `initialValue`：它就是构造时传进去的 `_theme`（`dropdown.dart:1871`
    // 转发给 `FormField.initialValue`），能真的红。
    expect(
      tester
          .widget<DropdownButtonFormField<AppTheme>>(
            find.byKey(const ValueKey('settings-theme')),
          )
          .initialValue,
      AppTheme.dark,
    );
  });

  testWidgets('改三项数值后保存，设置与盘上文件都变了（FR-G-01/02）', (tester) async {
    await open(tester);

    await fill(tester, 'settings-command-timeout', '30000');
    await fill(tester, 'settings-prompt-debounce', '250');
    await fill(tester, 'settings-connect-timeout', '5000');
    await save(tester);

    final s = stored(tester);
    expect(s.commandTimeoutMs, 30000);
    expect(s.promptDebounceMs, 250);
    expect(s.connectTimeoutMs, 5000);
    expect(File('${root.path}/settings.json').existsSync(), isTrue);
  });

  testWidgets('取消：一项都不写（FR-G-02 的反面）', (tester) async {
    await open(tester);

    await fill(tester, 'settings-command-timeout', '99999');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await settleDisk(tester);

    expect(stored(tester).commandTimeoutMs, 10000, reason: '默认值是 10000');
    expect(File('${root.path}/settings.json').existsSync(), isFalse);
  });

  testWidgets('超时不是正整数时挡下', (tester) async {
    await open(tester);

    for (final bad in ['0', '-1', 'abc', '']) {
      await fill(tester, 'settings-command-timeout', bad);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        // **这个空格是承重的，别"顺手"删掉。** 对话框那边的模板是
        // `'$label 必须是正整数'` —— `$label` 与「必须是」之间有一个空格，
        // 渲染出来是「命令执行超时 必须是正整数」。写成
        // `find.textContaining('命令执行超时必须是')`（无空格）**匹配不上**，
        // 这条用例会在四个坏值上全部报 findsNothing。
        //
        // 对照 Task 4 的设备编辑对话框：那边的模板是
        // `'端口必须是 1 到 65535 之间的整数'`（空格在「必须是」**之后**），
        // 所以它的断言 `'端口必须是'` 恰好不跨空格。两处的空格位置不同，
        // 断言的切法就得跟着不同。
        find.textContaining('命令执行超时 必须是'),
        findsOneWidget,
        reason: '「$bad」应当被挡下',
      );
    }
    expect(stored(tester).commandTimeoutMs, 10000);
  });

  testWidgets('去抖时长可以是 0（= 不去抖）', (tester) async {
    await open(tester);

    await fill(tester, 'settings-prompt-debounce', '0');
    await save(tester);

    expect(stored(tester).promptDebounceMs, 0);
  });

  testWidgets('默认提示符正则编译不了时挡下', (tester) async {
    await open(tester);

    await fill(tester, 'settings-default-prompt-regex', '[unclosed');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('默认提示符正则无法编译'), findsOneWidget);
    expect(stored(tester).defaultPromptRegex, r'[>#\]]\s*$');
  });

  testWidgets('翻页模式按行切、丢掉空行', (tester) async {
    await open(tester);

    await fill(tester, 'settings-more-patterns', '--More--\n\n  \n<--- More --->');
    await save(tester);

    expect(stored(tester).morePromptPatterns, ['--More--', '<--- More --->']);
  });

  testWidgets('翻页模式全清空会被挡下 —— 那会让翻页功能静默失效', (tester) async {
    await open(tester);

    await fill(tester, 'settings-more-patterns', '\n  \n');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('至少要有一条'), findsOneWidget);
    expect(stored(tester).morePromptPatterns, hasLength(3));
  });

  testWidgets('清空日志目录 = 用默认目录（`logDir` 的 null 是有语义的）', (tester) async {
    await open(tester, settings: const AppSettings(logDir: '/tmp/old'));

    await fill(tester, 'settings-log-dir', '');
    await save(tester);

    expect(
      stored(tester).logDir,
      isNull,
      reason: '`copyWith(logDir: null)` 必须能真的清掉，不能被 `?? this.x` 吞掉',
    );
  });

  testWidgets('主题下拉能改（FR-G-01）', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('settings-theme')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('浅色').last);
    await tester.pumpAndSettle();
    await save(tester);

    expect(stored(tester).theme, AppTheme.light);
  });

  testWidgets('主机密钥校验开关能关（FR-C-11 的"设置中可全局关闭"）', (tester) async {
    await open(tester);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('settings-verify-host-key')),
          )
          .value,
      isTrue,
      reason: 'NFR-S-03：默认开启',
    );

    await tester.tap(find.byKey(const ValueKey('settings-verify-host-key')));
    await tester.pumpAndSettle();
    await save(tester);

    expect(stored(tester).verifySshHostKey, isFalse);
  });

  testWidgets('分割比例滑杆写回 editorSplitRatio', (tester) async {
    await open(tester);

    // 直接调 `onChanged`：`Slider` 的拖动在假时钟下要算像素与轨道长度的
    // 换算，得到的比例是"大概 0.6"而不是 0.6 —— 断言会变成一条脆的用例。
    tester
        .widget<Slider>(find.byKey(const ValueKey('settings-split-ratio')))
        .onChanged!(0.6);
    await tester.pumpAndSettle();
    await save(tester);

    expect(stored(tester).editorSplitRatio, 0.6);
  });

  testWidgets('不在 FR-G-01 里的两项不出现在对话框里（有意的范围裁剪）', (tester) async {
    await open(tester);

    expect(find.textContaining('缓冲'), findsNothing);
    expect(find.textContaining('设备列表宽度'), findsNothing);
  });
}
