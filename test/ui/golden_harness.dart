import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/providers.dart';

import '../fixtures/fake_session.dart';

/// golden 是否运行。**默认不跑** —— 见文件末尾的说明。
bool get goldensEnabled => Platform.environment['WCT_GOLDEN'] == '1';

const _cjkFamily = 'Noto Sans CJK SC';

/// 把中文字体与等宽字体装进测试进程。
///
/// **字体族名必须与 [goldenTheme] 里写的 `fontFamily` 逐字相同** —— 实测过：
/// 不指定 `fontFamily` 的文字会渲染成豆腐块（一排方框），而不是回退到某个能
/// 显示中文的字体。
///
/// 除了主题那一个族，还要补**两处产品代码里写死的族名**，否则 golden 里它们的
/// 字全是方框。两条都是实测出来的：
///
/// 1. 编辑区与输出区的正文写着 `fontFamily: 'monospace'` +
///    `fontFamilyFallback: ['DejaVu Sans Mono']`，而测试进程里没有 fontconfig：
///    'monospace' 谁也不认识，引擎就退回测试自带的那个"每个字都是一个实心方框"
///    的字体。症状与"中文是豆腐块"不同 —— 这个是**连 ASCII 都是黑块**，输出区
///    整片读不出来。
/// 2. `IconData` 的族名是 `MaterialIcons`，SDK 里那个 otf 不注册的话，所有
///    IconButton 都画成空心方框（工具栏、列表每行的两个按钮、清屏按钮）。
Future<void> loadTestFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    final loader = FontLoader(family)
      ..addFont(Future.value(file.readAsBytesSync().buffer.asByteData()));
    await loader.load();
  }

  // NotoSansCJK-Regular.ttc 是一个**字体集合**，`FontLoader` 收得下（实测）。
  await load(_cjkFamily, _cjkFontPath);
  await load('monospace', _dejavuMonoPath);

  // **回退族名要指向一个真有汉字的字体。**
  //
  // 实测结论（探针：四行同样的 `display version 中文 42`）：**引擎每个族只认一个
  // 字体面，缺字形时只往下一个族找，不会在同一个族里翻第二个字体**。所以给
  // 'monospace' 同时挂 DejaVu 与 Noto 是没用的 —— 汉字照样是方框；而把
  // `DejaVu Sans Mono` 这个名字指向一个"有汉字的等宽字体"，汉字就出来了，
  // ASCII 仍由 'monospace' 那份 DejaVu 出（等宽，表格对齐不变）。
  //
  // 拿文泉驿微米黑顶这个名字：它本身就是**等宽**的中文字体，而且它是产品代码里
  // 唯一声明过的回退族名。真实机器上这一步是 fontconfig 干的（'monospace' 解到
  // DejaVu、汉字由系统的中文回退补上），测试进程里没有 fontconfig，只能这样
  // 手工复现。**产品代码一个字都不用改** —— golden 不该为了自己好看去动它。
  await load('DejaVu Sans Mono', _wqyMonoPath);

  final iconFont = _materialIconsPath();
  if (iconFont != null) await load('MaterialIcons', iconFont);
}

const _cjkFontPath = '/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc';
const _dejavuMonoPath = '/usr/share/fonts/dejavu/DejaVuSansMono.ttf';
const _wqyMonoPath = '/usr/share/fonts/wqy-microhei/wqy-microhei.ttc';

/// SDK 里的 `MaterialIcons-Regular.otf`。
///
/// 它不在系统字体目录里，而在 `$FLUTTER_ROOT/bin/cache/artifacts/material_fonts/`。
/// 先看环境变量，再从**当前进程的可执行文件**倒推 —— `flutter test` 就是拿
/// `$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart` 跑测试的，往上四层就是 SDK 根。
/// 两条都落空就返回 null（图标变方框，但不失败）：换台机器、SDK 布局不同
/// 都不该让 golden 红。
String? _materialIconsPath() {
  const tail = 'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  final roots = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final r? when r.isNotEmpty) r,
    _flutterRootFromExecutable() ?? '',
  ];
  for (final root in roots) {
    if (root.isEmpty) continue;
    final path = '$root/$tail';
    if (File(path).existsSync()) return path;
  }
  return null;
}

String? _flutterRootFromExecutable() {
  var dir = File(Platform.resolvedExecutable).parent; // bin/cache/dart-sdk/bin
  for (var i = 0; i < 4; i++) {
    dir = dir.parent;
  }
  return dir.path;
}

/// 本机缺少 golden 需要的字体时，**跳过而不是失败**。
///
/// 换一台机器（或换个发行版的字体包）就没有这些文件，而那不是本项目的回归。
/// 报成红的只会训练人忽略红的。
bool get fontsAvailable =>
    File(_cjkFontPath).existsSync() && File(_wqyMonoPath).existsSync();

ThemeData goldenTheme(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.blue,
    brightness: brightness,
  ),
  // **不能省。** 省掉的话所有中文都是豆腐块。
  fontFamily: _cjkFamily,
);

/// 固定画布尺寸，让 golden 与窗口大小解耦。
///
/// 默认画布是 800×600 @ DPR 3.0（实测），那对主窗口太挤；而 DPR 3.0 会让
/// PNG 变成 2400×1800，看的时候还得缩。这里统一成 1440×900 @ 1.0。
void useGoldenSurface(WidgetTester tester, {Size size = const Size(1440, 900)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 与 `ui_harness.pumpUi` 同源，但**不套 `Scaffold`**（面板 golden 要的是面板
/// 本身），并且关掉 debug 横幅 —— 实测它默认会画在右上角，进 golden 就是一条
/// 每次都要解释的红斜带。
Future<void> pumpForGolden(
  WidgetTester tester, {
  required Directory root,
  required Widget child,
  required Brightness brightness,
  List<DeviceProfile> devices = const [],
  AppSettings settings = const AppSettings(),
  FakeSessionFactory? factory,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores(paths: AppPaths(root))),
        startupProvider.overrideWithValue(
          AppStartup(settings: settings, devices: devices),
        ),
        sessionFactoryProvider.overrideWithValue(factory ?? FakeSessionFactory()),
        logsDirPath.overrideWithValue('${root.path}/logs'),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(brightness),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}
