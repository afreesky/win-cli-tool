# 计划 5b-1：界面主循环（骨架 + 设备列表 + 编辑区 + 输出区）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把计划 5a 装好的四层接到真实界面上，做出一个**能真用起来的主循环**——看到设备列表 → 编辑命令 → 发送 → 看到输出，并让 §9.2 的六条界面行为测试中的五条有归属（第六条属 5b-2）。

**Architecture:** `lib/ui/` 按 spec §8.5 已排定的布局建立：`main_window.dart`（主窗口与分栏）、`panels/`（设备列表 / 命令编辑 / 输出）、`widgets/`（通用组件）。**界面只订阅 `ConnectionManager` 派生的 provider，永不直接订阅 `Session`**——这条所有权规则由 5a 的 `SessionController` 兑现，界面这一侧只消费 `sessionProvider` 暴露的 `SessionStatus` 与 `enqueue` / `abort`。

**Tech Stack:** Flutter 3.44.4 / Dart 3.12.2，`flutter_riverpod` 3.4.3，`flutter_test` + golden。

**前置：计划 5a 已完成**（10 个任务，440 条用例全绿，`dart analyze lib/ test/` 干净）。

---

## 本计划的范围边界

**做**：主窗口骨架、工具栏、设备列表（状态点 / tooltip / 右键菜单 / 拖拽排序 / 增删改入口）、命令编辑区（行号栏 / 文本编辑 / 发送 / 停止 / 队列进度 / 草稿接线）、输出区（ANSI 渲染 / 自动滚动 / 清屏 / 设备名标题）、四个快捷键、设备切换。

**不做（属 5b-2）**：命令库抽屉（FR-S）、设置对话框、设备编辑对话框、主机密钥指纹确认对话框（FR-C-11）、导入文件（FR-E-15/16）、同步到另一台（FR-E-17）。设备列表的「添加 / 编辑 / 删除」按钮在 5b-1 里**接上动作但对话框是占位**——见 Task 9 的说明。

**日志**：按用户 2026-09-25 的决定，**保持现状、不再投入**。本计划不碰 `LogWriter`，也不为它的欠账补测试。唯一相关的动作是 FR-O-05 的清屏必须**证明**不动日志（§9.2 第 6 条）。

---

## 本计划开始前必须知道的四条实测结论

这些是写计划时**已经量过**的，不是推理。执行者不必重测，但必须按它们写代码。

1. **golden 里中文能真渲染，但只能用显式 `fontFamily`。** 探针（跑完即删）实测：`FontLoader` 加载 `/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc`（**`.ttc` 字体集合可用**）与 `/usr/share/fonts/dejavu/DejaVuSansMono.ttf` 都返回成功，PNG 里中文与等宽英文都是真字形；而**不指定 `fontFamily` 的那一行渲染成 8 个豆腐块**。所以 Task 10 的 golden 夹具必须给整棵树套一个带 `fontFamily` 的 `Theme`。
2. **`flutter test` 的默认画布是 800×600 逻辑像素、DPR 3.0**（探针产出的 PNG 是 2400×1800）。主窗口的 golden 要显式设成真实窗口尺寸，否则布局是挤的。
3. **`MaterialApp` 默认带 debug 横幅**（探针里右上角那条红色斜带）。golden 夹具必须 `debugShowCheckedModeBanner: false`。
4. **NFR-F-02 要求输出渲染节流到约 60ms 一次**（"不得逐字节触发界面重绘"）。所以 **`OutputBuffer` 直接 `notifyListeners()` 是不合规的**——通知本身便宜，但每次通知都会重建那棵 `SelectableText.rich` 树。节流由 Task 2 的 `RefreshThrottle` 承担。

---

## 文件结构

按 spec §8.5 已排定的布局（**不要另立目录**）：

```
lib/ui/
  main_window.dart              主窗口：工具栏 + 左设备列表 + 右上编辑 / 右下输出
  panels/
    device_list_panel.dart      设备列表（状态点 / 右键菜单 / 拖拽排序）
    editor_panel.dart           命令编辑区（行号栏 / 发送 / 停止 / 队列进度）
    output_panel.dart           输出区（ANSI 渲染 / 自动滚动 / 清屏）
  widgets/
    ansi_text.dart              AnsiColor → Flutter Color，AnsiSpan → TextSpan
    refresh_throttle.dart       把高频变更压成 ~60ms 一次的刷新（NFR-F-02）
    send_range.dart             §5.1 发送范围判定（纯 Dart）
    splitter.dart               可拖拽分隔条
    status_dot.dart             设备状态点（颜色 + tooltip 文案）
  draft_autosave.dart           草稿防抖落盘 + 退出兜底（FR-E-03/04）
```

**改动既有文件**：`lib/state/output_buffer.dart`（加变更通知）、`lib/app.dart`（`home` 换成 `MainWindow`）、`pubspec.yaml`（若 golden 需要）。

**测试**：

```
test/ui/
  ansi_text_test.dart           纯 Dart 单测
  refresh_throttle_test.dart    fakeAsync 单测
  send_range_test.dart          纯 Dart 单测（§5.1 的边界）
  draft_autosave_test.dart      fakeAsync 单测
  output_panel_test.dart        widget 测试（§9.2 第 5、6 条）
  editor_panel_test.dart        widget 测试（§9.2 第 1 条）
  device_list_panel_test.dart   widget 测试（§9.2 第 4 条）
  main_window_test.dart         widget 测试（§9.2 第 2、3 条）
  golden/                       产出的 PNG（Task 10）
  golden_harness.dart           golden 夹具（字体 / 窗口尺寸 / 主题）
  main_window_golden_test.dart  带 `@Tags(['golden'])`
```

---

## Task 1: `OutputBuffer` 变更通知

**为什么这是第一个任务**：输出区要能在新数据到达时重绘，而 `OutputBuffer`（计划 5a 的产物）是个不通知任何人的普通对象——`outputBufferProvider` 返回它之后，Riverpod 不会因为 `buffer.add(...)` 而重建任何东西。这是 5a 有意留下的接缝，界面接手时必须先补上。

**为什么加在 `OutputBuffer` 而不是面板里**：面板拿不到"有新数据"这个事实，除非缓冲自己说。让面板去轮询 `lines.length` 是拿正确性换省事。

**Files:**
- Modify: `lib/state/output_buffer.dart`
- Test: `test/state/output_buffer_test.dart`（追加，不新建）

**注意 `lib/state/` 允许依赖 Flutter**：完成标准 5 的 `grep` 清单是 `lib/data lib/connection lib/command lib/render lib/models`，**不含 `lib/state`**，而 `lib/state/providers.dart` 本来就 import 了 `flutter_riverpod`。所以这里用 `ChangeNotifier` 不违反 NFR-M-01（那条管的是命令队列/提示符/翻页/ANSI/日志）。

- [ ] **Step 1: 写失败测试**

追加到 `test/state/output_buffer_test.dart` 末尾（`main()` 内）：

```dart
  test('变动会通知监听者（界面据此重绘）', () {
    final buffer = OutputBuffer(maxLines: 100);
    var notified = 0;
    buffer.addListener(() => notified++);

    buffer.add('hello');
    expect(notified, 1, reason: '一次喂进应当通知一次');

    buffer.addMarker('--- 连接断开 ---');
    expect(notified, 2);

    buffer.clear();
    expect(notified, 3);
  });

  test('没有真正改变内容时不通知', () {
    final buffer = OutputBuffer(maxLines: 100);
    var notified = 0;
    buffer.addListener(() => notified++);

    // 空串：`add` 开头就返回了，`_lines` 没动。
    buffer.add('');
    expect(notified, 0, reason: '空块不该触发重绘');

    // 半条控制序列：全被留住，`complete` 是空串，`_lines` 没动。
    buffer.add('\x1b[');
    expect(notified, 0, reason: '只有半条序列时没有内容定型');

    // 补齐后半截：这一轮有内容定型（`complete` 非空），所以通知 —— **尽管
    // 解析结果里一个可见字符都没有**（纯 SGR 序列）。通知的条件是"有定型"，
    // 不是"有可见文本"。
    buffer.add('31m');
    expect(notified, 1);
  });
```

- [ ] **Step 2: 跑测试确认红**

Run: `flutter test test/state/output_buffer_test.dart`
Expected: **编译失败**（`The method 'addListener' isn't defined for the type 'OutputBuffer'`）。

**这一条是"符号还不存在"那类可接受的失败**——它证明测试确实指向了尚未实现的东西。不要为了让它编译过去而删掉断言。

- [ ] **Step 3: 实现**

在 `lib/state/output_buffer.dart` 顶部加 import：

```dart
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../render/ansi_parser.dart';
```

把类声明改成继承 `ChangeNotifier`，并在类文档**末尾**追加一段（保留原有全部文字，只追加）：

```dart
/// 生命周期：活得比一次会话长。FR-O-09 要求切换设备后切回来还能看到完整的输出，
/// 而 `ConnectionManager` 会在重连时换掉整个会话 —— 所以它由状态层持有，
/// 会话只往里灌数据。
///
/// **它同时是个 [ChangeNotifier]**：界面靠它知道"该重绘了"。这是 5a 有意留下的
/// 接缝 —— provider 返回的是本对象，`buffer.add(...)` 不会让任何 provider 失效，
/// 界面若没有这条通知就只能轮询。
///
/// **通知是"变了"，不是"可以重绘了"。** NFR-F-02 要求输出渲染节流到约 60ms
/// 一次，而这里**每一轮有内容定型就通知**（设备可以 200 行/秒地吐，见
/// NFR-F-03）——「有内容定型」指 [add] 这一轮里 `complete` 非空，**与有没有
/// 可见文本无关**：一条完整的 SGR 序列（如 `'\x1b[32m'`）会定型却吐不出字符，
/// 它照样通知。反过来说，空串与"整块都被留存"这两轮不通知（`_lines` 没动，
/// 重绘没有意义）——
/// 节流是订阅方的事，见 `lib/ui/widgets/refresh_throttle.dart`。把节流做进本类
/// 会让它拥有一个定时器，而 `clear()` / `addMarker()` 这种**用户操作**必须即时
/// 生效，两者混在一起会把"谁负责及时"搞乱。
///
/// **本类不 `dispose()`。** 它由 `outputBufferProvider` 持有，那个 provider 不是
/// `autoDispose`（缓冲要活得和容器一样久），所以 `ref.onDispose` 只在容器整体
/// 销毁时才跑 —— 而那时 `SessionController` 可能仍持有它。不加 `dispose` 的代价
/// 是进程退出时留下几十字节的监听者列表，收益是不去赌两条销毁路径的先后。
class OutputBuffer extends ChangeNotifier {
```

四个公开变更点各加一行 `notifyListeners();`：

```dart
  void add(String chunk) {
    if (chunk.isEmpty) return;
    final input = _pending + chunk;
    // 留住的尾巴**不喂给日志**，于是两边的边界逐字相同（见类的说明）。
    final hold = ansiHoldBackLength(input);
    final complete = input.substring(0, input.length - hold);
    _pending = input.substring(input.length - hold);
    if (complete.isEmpty) return;
    _consume(complete);
    notifyListeners();
  }

  void flush() {
    final rest = _pending;
    if (rest.isEmpty) return;
    _pending = '';
    _consume(rest);
    notifyListeners();
  }
```

`addMarker` 与 `clear` 在各自方法体**末尾**加 `notifyListeners();`（`addMarker` 加在 `_trim();` 之后，`clear` 加在 `..add(<AnsiSpan>[]);` 之后）。

- [ ] **Step 4: 跑测试确认绿**

Run: `flutter test test/state/output_buffer_test.dart`
Expected: 全绿（原有用例 + 新增 2 条）。

**特别确认原有用例没被破坏**——`ChangeNotifier` 是纯增量改动，但 `notifyListeners()` 在**没有监听者**时也必须是安全的空操作。若原有某条用例变红，说明真实原因要查清，**不要**去改那条用例。

- [ ] **Step 5: 提交**

```bash
git add lib/state/output_buffer.dart test/state/output_buffer_test.dart
git commit -m "$(cat <<'EOF'
feat(state): OutputBuffer 变成 ChangeNotifier，界面据此重绘

5a 有意留下的接缝：provider 返回缓冲对象，buffer.add() 不会让任何 provider
失效，界面没有这条通知就只能轮询。

通知语义是"变了"而不是"可以重绘了" —— NFR-F-02 要求渲染节流到 60ms 一次，
节流归订阅方（RefreshThrottle），因为 clear()/addMarker() 这类用户操作必须
即时生效，把定时器做进本类会把两件事混在一起。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `RefreshThrottle` —— NFR-F-02 的 60ms 节流

**为什么单独一个类**：NFR-F-02 是一条**明写的性能需求**（"输出渲染需节流批量刷新（约 60ms 一次），不得逐字节触发界面重绘"），而它和"缓冲通知"是两件事。做成独立的类之后，它可以用 `fakeAsync` 精确验证——不需要渲染任何 widget。

**Files:**
- Create: `lib/ui/widgets/refresh_throttle.dart`
- Test: `test/ui/refresh_throttle_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/widgets/refresh_throttle.dart';

/// 假的变更源：测试自己决定什么时候"变了"。
class _Source extends ChangeNotifier {
  void ping() => notifyListeners();
}

void main() {
  test('第一次变更立刻放行（用户操作不能等 60ms）', () {
    fakeAsync((async) {
      final source = _Source();
      final throttle = RefreshThrottle(source: source);
      var notified = 0;
      throttle.addListener(() => notified++);

      source.ping();
      expect(notified, 1, reason: '第一次不该被压');

      throttle.dispose();
      source.dispose();
    });
  });

  test('紧接着的连串变更被压成一次', () {
    fakeAsync((async) {
      final source = _Source();
      final throttle = RefreshThrottle(source: source);
      var notified = 0;
      throttle.addListener(() => notified++);

      source.ping(); // 立刻放行，计数 1
      for (var i = 0; i < 50; i++) {
        source.ping();
      }
      expect(notified, 1, reason: '60ms 窗口内的连串变更不该各算一次');

      async.elapse(const Duration(milliseconds: 60));
      expect(notified, 2, reason: '窗口到点时补一次，把 50 次变更合并成 1 次');

      // 没有被压住的变更时，定时器不再空转。
      async.elapse(const Duration(milliseconds: 300));
      expect(notified, 2, reason: '没有新变更就不该继续通知');

      throttle.dispose();
      source.dispose();
    });
  });

  test('200 行/秒的速率下，通知数远小于变更数（NFR-F-03 的速率）', () {
    fakeAsync((async) {
      final source = _Source();
      final throttle = RefreshThrottle(source: source);
      var notified = 0;
      throttle.addListener(() => notified++);

      // 1 秒内 200 次变更 —— 每次变更对应一次 buffer.add。
      for (var i = 0; i < 200; i++) {
        source.ping();
        async.elapse(const Duration(milliseconds: 5));
      }

      expect(notified, lessThanOrEqualTo(20),
          reason: '1 秒 / 60ms ≈ 16 次，留一点余量');

      throttle.dispose();
      source.dispose();
    });
  });

  test('监听者在通知里同步回写 source 时，当场不再通知第二次', () {
    fakeAsync((async) {
      final source = _Source();
      final throttle = RefreshThrottle(source: source);
      var notified = 0;
      // 监听者在通知里**同步**回写 source。当前没有消费者这么做，但这是
      // `ChangeNotifier` 明确允许的用法，而本类的整个职责就是时序正确。
      var reentered = false;
      throttle.addListener(() {
        notified++;
        if (reentered) return;
        reentered = true;
        source.ping();
      });

      source.ping();

      // **判别力在这里，而且它是合同不是实现细节。** 本类承诺"至多每 interval
      // 一次"，而这次回写落在**同一个窗口内**，所以它只能被攒成 `_pending`，
      // 不能当场再通知一次。
      //
      // 若 `notifyListeners()` 排在武装定时器**之前**，回写那一跳会看到
      // `_timer` 还是 null，于是走进"首次变更立刻放行"分支 —— 当场嵌套通知
      // 第二次，并武装出一个随即被外层覆盖、此后再也 cancel 不到的定时器。
      // 这里断言 1 就是钉住那个形状。
      expect(notified, 1, reason: '同一窗口内的回写必须被合并，不能当场再通知');

      // 而那次回写不能被丢掉：窗口到点时要补上。
      async.elapse(const Duration(milliseconds: 60));
      expect(notified, 2, reason: '回写攒下的变更要在窗口到点时补一次');

      async.elapse(const Duration(seconds: 1));
      expect(notified, 2, reason: '没有新变更就不该继续通知');

      throttle.dispose();
      source.dispose();
    });
  });

  test('dispose 之后定时器不再触发', () {
    fakeAsync((async) {
      final source = _Source();
      final throttle = RefreshThrottle(source: source);
      var notified = 0;
      throttle.addListener(() => notified++);

      source.ping();
      source.ping();
      throttle.dispose();

      async.elapse(const Duration(seconds: 1));
      expect(notified, 1, reason: 'dispose 之后不该再有通知');
      source.dispose();
    });
  });
}
```

**`fake_async` 的依赖**：它是 `flutter_test` 的传递依赖，直接 import 在本仓已验证可用（`test/command/command_dispatcher_test.dart` 就在用 `fakeAsync`）。若分析器报 `depend_on_referenced_packages`，把 `fake_async` 也加进 `pubspec.yaml` 的 `dev_dependencies`。

- [ ] **Step 2: 跑测试确认红**

Run: `flutter test test/ui/refresh_throttle_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: 'package:win_cli_tool/ui/widgets/refresh_throttle.dart'`）。这是"文件还不存在"那类可接受的失败。

- [ ] **Step 3: 实现**

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';

/// 把 [source] 的高频变更压成**至多每 [interval] 一次**的通知（NFR-F-02）。
///
/// 为什么需要它：设备可以 200 行/秒地吐数据（NFR-F-03），而每一块到达都会让
/// `OutputBuffer` 通知一次。若界面直接监听缓冲，那一秒内就会重建 200 次
/// `SelectableText.rich` 树——NFR-F-02 明写"不得逐字节触发界面重绘"。
///
/// **形状是"首次立刻放行，之后按窗口合并"**，不是"一律延迟 [interval]"：
/// 用户点清屏、切设备这类操作走的是同一条通知路径，让人等 60ms 才看到反应是
/// 没必要的。所以第一次变更立刻通知，随后在窗口内的连串变更合并成窗口结束时
/// 的一次。
///
/// **窗口结束时若没有再攒下变更，定时器就停掉**——不空转。所以静止下来的
/// 界面不持有任何定时器。
class RefreshThrottle extends ChangeNotifier {
  RefreshThrottle({
    required this.source,
    this.interval = const Duration(milliseconds: 60),
  }) {
    source.addListener(_onSourceChanged);
  }

  /// 上游变更源（界面里是 `OutputBuffer`）。
  final Listenable source;

  /// 合并窗口。默认 60ms，来自 NFR-F-02 的"约 60ms 一次"。
  final Duration interval;

  Timer? _timer;

  /// 窗口内是否又攒下了变更 —— 决定窗口到点时要不要补一次通知。
  bool _pending = false;

  void _onSourceChanged() {
    if (_timer != null) {
      // 已经在窗口里：只记下"还有变更"，到点一并通知。
      _pending = true;
      return;
    }
    // **先武装定时器，再通知 —— 顺序是承重的。** 反过来的话，监听者若在通知里
    // **同步**回写 source，那一跳会看到 `_timer` 还是 null，于是走进上面那个
    // "首次立刻放行"分支：当场嵌套通知第二次（违反"至多每 interval 一次"），
    // 并武装出一个随即被下一行覆盖、此后再也 cancel 不到的定时器。
    //
    // 实测：把它写成"先通知后武装"，`refresh_throttle_test.dart` 的
    // "监听者在通知里同步回写 source 时，当场不再通知第二次"红在 `Actual: <2>`。
    // **那个失联定时器是同一形状的第二个后果，但我没能构造出让它咬人的用例**
    // （它到点时要恰好 `_pending == true` 才会对已 dispose 的对象发通知），
    // 所以这里只把实测到的那一条当作依据。
    _timer = Timer(interval, _onWindowClosed);
    notifyListeners();
  }

  void _onWindowClosed() {
    _timer = null;
    if (!_pending) return;
    _pending = false;
    // 同上：先武装再通知。
    _timer = Timer(interval, _onWindowClosed);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    source.removeListener(_onSourceChanged);
    super.dispose();
  }
}
```

- [ ] **Step 4: 跑测试确认绿**

Run: `flutter test test/ui/refresh_throttle_test.dart`
Expected: 4 条全绿。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/widgets/refresh_throttle.dart test/ui/refresh_throttle_test.dart pubspec.yaml pubspec.lock
git commit -m "$(cat <<'EOF'
feat(ui): RefreshThrottle —— 输出渲染的 60ms 节流（NFR-F-02）

设备可 200 行/秒地吐数据，每块到达都让 OutputBuffer 通知一次；界面直接监听
就会一秒重建 200 次 SelectableText.rich 树。本类把它压成至多每 60ms 一次。

形状是"首次立刻放行、之后按窗口合并"：清屏/切设备走同一条通知路径，不该
让用户等 60ms。窗口结束时没攒下变更就停掉定时器，静止界面不持有定时器。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

（若没有改 `pubspec.yaml`，把那两个路径从 `git add` 里去掉——**按显式路径 stage**，不要用 `-A`。）

---

## Task 3: `ansi_text.dart` —— ANSI 到 Flutter 的映射

**为什么它是纯函数**：`AnsiStyle` / `AnsiColor` 是 `lib/render/` 的产物（纯 Dart，NFR-M-01），把它们映射成 Flutter 的 `Color` 与 `TextSpan` 是**纯计算**，不需要渲染任何东西就能验。颜色映射最容易写错（xterm 256 色的立方与灰阶），所以它值得有自己的用例。

**`_basicRgb` 是私有的**：`lib/render/ansi_parser.dart` 里的 16 色表是 `const List<(int,int,int)> _basicRgb`（前导下划线 = 库私有）。**不要去改它的可见性**——那会动到已冻结的 `render/` 层。本文件自己带一份表，并写明这份重复的理由。

**Files:**
- Create: `lib/ui/widgets/ansi_text.dart`
- Test: `test/ui/ansi_text_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/render/ansi_parser.dart';
import 'package:win_cli_tool/ui/widgets/ansi_text.dart';

void main() {
  group('颜色映射', () {
    test('16 色：前 8 个是标准色，8~15 是亮色', () {
      expect(ansiColorOf(const AnsiBasic(0)), const Color(0xFF000000));
      expect(ansiColorOf(const AnsiBasic(1)), const Color(0xFFCD0000));
      expect(ansiColorOf(const AnsiBasic(7)), const Color(0xFFE5E5E5));
      expect(ansiColorOf(const AnsiBasic(8)), const Color(0xFF7F7F7F));
      expect(ansiColorOf(const AnsiBasic(15)), const Color(0xFFFFFFFF));
    });

    test('256 色：0~15 与 16 色表一致', () {
      expect(ansiColorOf(const Ansi256(0)), ansiColorOf(const AnsiBasic(0)));
      expect(ansiColorOf(const Ansi256(9)), ansiColorOf(const AnsiBasic(9)));
    });

    test('256 色：16~231 是 6×6×6 立方，取值为 0/95/135/175/215/255', () {
      // 16 是立方体的原点 (0,0,0)。
      expect(ansiColorOf(const Ansi256(16)), const Color(0xFF000000));
      // 17 是 (0,0,1) —— 蓝通道取第一档 95。
      expect(ansiColorOf(const Ansi256(17)), const Color(0xFF00005F));
      // 231 是 (5,5,5) —— 三通道都取最高档 255。
      expect(ansiColorOf(const Ansi256(231)), const Color(0xFFFFFFFF));
    });

    test('256 色：232~255 是 24 级灰阶', () {
      expect(ansiColorOf(const Ansi256(232)), const Color(0xFF080808));
      expect(ansiColorOf(const Ansi256(255)), const Color(0xFFEEEEEE));
    });

    test('真彩色直接取三通道', () {
      expect(ansiColorOf(const AnsiRgb(0x12, 0x34, 0x56)), const Color(0xFF123456));
    });

    test('没有颜色时给 null（调用方据此用主题默认色，而不是硬编码黑白）', () {
      expect(ansiColorOf(null), isNull);
    });
  });

  group('样式映射', () {
    test('前/背景色直接落到 TextStyle', () {
      final span = ansiSpanOf(
        const AnsiSpan('x', AnsiStyle(foreground: AnsiBasic(1), background: AnsiBasic(4))),
      );
      expect(span.style!.color, const Color(0xFFCD0000));
      expect(span.style!.backgroundColor, const Color(0xFF0000CD));
    });

    test('bold 与 underline 落到字重与装饰', () {
      final span = ansiSpanOf(
        const AnsiSpan('x', AnsiStyle(bold: true, underline: true)),
      );
      expect(span.style!.fontWeight, FontWeight.bold);
      expect(span.style!.decoration, TextDecoration.underline);
    });

    test('reverse 交换前背景色，且在没有前背景时给出一对可看的默认值', () {
      final span = ansiSpanOf(
        const AnsiSpan('x', AnsiStyle(foreground: AnsiBasic(1), reverse: true)),
      );
      // 原本 fg=红 无背景 → 反转后 背景=红、前景=「默认背景色」
      expect(span.style!.backgroundColor, const Color(0xFFCD0000));
      expect(span.style!.color, isNotNull, reason: '反转后前景必须有值，否则等于没反转');

      final bare = ansiSpanOf(const AnsiSpan('x', AnsiStyle(reverse: true)));
      expect(bare.style!.backgroundColor, isNotNull);
      expect(bare.style!.color, isNotNull);
    });
  });

  group('整棵树', () {
    test('行之间用 \\n 连接，片段样式各归各的', () {
      final lines = <List<AnsiSpan>>[
        [const AnsiSpan('a', AnsiStyle(foreground: AnsiBasic(1)))],
        [const AnsiSpan('b', AnsiStyle.none)],
      ];
      final root = ansiLinesToTextSpan(lines);

      final flat = <TextSpan>[];
      root.visitChildren((s) {
        flat.add(s as TextSpan);
        return true;
      });
      // 3 个子节点：'a'、'\n'、'b'
      expect(flat, hasLength(3));
      expect(flat[0].text, 'a');
      expect(flat[1].text, '\n');
      expect(flat[2].text, 'b');
      expect(flat[0].style!.color, const Color(0xFFCD0000));
      expect(flat[2].style?.color, isNull, reason: '无色的片段不该被硬塞一个颜色');
    });

    test('空缓冲给得出一个空的根节点，不抛', () {
      final root = ansiLinesToTextSpan([<AnsiSpan>[]]);
      expect(root.children, isEmpty);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `flutter test test/ui/ansi_text_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: .../ansi_text.dart`）。

- [ ] **Step 3: 实现**

```dart
import 'package:flutter/material.dart';

import '../../render/ansi_parser.dart';

/// 16 色（xterm 标准调色板）。
///
/// **这份表与 `lib/render/ansi_parser.dart` 里那份 `_basicRgb` 是重复的，这是
/// 有意接受的。** 那一份是库私有的（前导下划线），且 `render/` 层的职责是"解析
/// 控制序列"，把 Flutter 的 `Color` 塞进去会让一个纯 Dart 模块（NFR-M-01）
/// 依赖 Flutter。重复的是 16 行常量，换来的是两层各自的边界不被打穿。
/// **若哪天要改颜色，两处都要改** —— 所以本文件与 `ansi_parser.dart` 各有一条
/// 用例钉着第 1、4、7、8、15 号色。
const List<(int, int, int)> _basicRgb = [
  (0x00, 0x00, 0x00), // 0 黑
  (0xCD, 0x00, 0x00), // 1 红
  (0x00, 0xCD, 0x00), // 2 绿
  (0xCD, 0xCD, 0x00), // 3 黄
  (0x00, 0x00, 0xCD), // 4 蓝
  (0xCD, 0x00, 0xCD), // 5 品红
  (0x00, 0xCD, 0xCD), // 6 青
  (0xE5, 0xE5, 0xE5), // 7 白
  (0x7F, 0x7F, 0x7F), // 8 亮黑
  (0xFF, 0x00, 0x00), // 9 亮红
  (0x00, 0xFF, 0x00), // 10 亮绿
  (0xFF, 0xFF, 0x00), // 11 亮黄
  (0x5C, 0x5C, 0xFF), // 12 亮蓝
  (0xFF, 0x00, 0xFF), // 13 亮品红
  (0x00, 0xFF, 0xFF), // 14 亮青
  (0xFF, 0xFF, 0xFF), // 15 亮白
];

/// xterm 256 色里 6×6×6 立方体的六个取值档。
const List<int> _cubeSteps = [0, 95, 135, 175, 215, 255];

/// [AnsiColor] → Flutter 的 [Color]；`null` 给 `null`。
///
/// **`null` 不是"黑色"，是"没有指定"**——调用方据此用主题的前景色/背景色，
/// 这样深色主题下不带颜色的输出才是可读的。硬编码成黑白会让深色主题下的
/// 普通输出变成黑底黑字。
Color? ansiColorOf(AnsiColor? color) => switch (color) {
  null => null,
  AnsiBasic(:final index) => _fromBasic(index),
  // 256 色：0~15 复用 16 色表，16~231 是 6×6×6 立方，232~255 是 24 级灰阶。
  Ansi256(:final index) => switch (index) {
    < 16 => _fromBasic(index),
    < 232 => _fromCube(index - 16),
    _ => _fromGray(index - 232),
  },
  AnsiRgb(:final r, :final g, :final b) => Color.fromARGB(255, r, g, b),
};

Color _fromBasic(int index) {
  final (r, g, b) = _basicRgb[index];
  return Color.fromARGB(255, r, g, b);
}

Color _fromCube(int offset) => Color.fromARGB(
  255,
  _cubeSteps[(offset ~/ 36) % 6],
  _cubeSteps[(offset ~/ 6) % 6],
  _cubeSteps[offset % 6],
);

/// 灰阶 232~255 是 `8 + 10 * n`（n 从 0 到 23）。
Color _fromGray(int n) {
  final v = 8 + 10 * n;
  return Color.fromARGB(255, v, v, v);
}

/// 反转视频时用的默认前景。取暗灰而不是纯黑：纯黑在很多主题里就是背景色，
/// 那会让反转后的文字与背景糊在一起。
const Color _kReverseFallbackForeground = Color(0xFF1E1E1E);

/// 反转视频时用的默认背景。取接近白而不是纯白，理由同上。
const Color _kReverseFallbackBackground = Color(0xFFE5E5E5);

/// 把一个 [AnsiSpan] 映射成 Flutter 的 [TextSpan]。
///
/// **无颜色的字段一律留 `null`**，让 `DefaultTextStyle` / 主题决定 —— 见
/// [ansiColorOf] 的说明。
TextSpan ansiSpanOf(AnsiSpan span) {
  final style = span.style;
  var foreground = ansiColorOf(style.foreground);
  var background = ansiColorOf(style.background);

  if (style.reverse) {
    // 反转是"交换"，而交换需要两边都有值才成立。缺哪边就补哪边的默认值，
    // 否则 `fg=红, bg=null` 反转后成了 `fg=null, bg=红` —— 前景落回主题色，
    // 看起来像是没反转。
    final fg = foreground ?? _kReverseFallbackForeground;
    final bg = background ?? _kReverseFallbackBackground;
    foreground = bg;
    background = fg;
  }

  return TextSpan(
    text: span.text,
    style: TextStyle(
      color: foreground,
      backgroundColor: background,
      fontWeight: style.bold ? FontWeight.bold : null,
      decoration: style.underline ? TextDecoration.underline : null,
    ),
  );
}

/// 把整个缓冲的行映射成一棵 [TextSpan] 树。
///
/// **行之间用 `\n` 连接**，行内的片段各自成节点 —— 这样一整块可以交给
/// 一个 `SelectableText.rich`，而**跨行拖选与复制**（FR-O-06）才能正常工作。
/// 每行一个独立的 `SelectableText` 会让选择被切成一段一段。
TextSpan ansiLinesToTextSpan(List<List<AnsiSpan>> lines) {
  final children = <TextSpan>[];
  for (var i = 0; i < lines.length; i++) {
    if (i > 0) children.add(const TextSpan(text: '\n'));
    for (final span in lines[i]) {
      children.add(ansiSpanOf(span));
    }
  }
  if (children.isEmpty) return const TextSpan();
  return TextSpan(children: children);
}
```

- [ ] **Step 4: 跑测试确认绿**

Run: `flutter test test/ui/ansi_text_test.dart`
Expected: 全绿。

**注意"空缓冲"那条**：`ansiLinesToTextSpan([<AnsiSpan>[]])` 的输入长度是 1（`OutputBuffer` 的 `_lines` 永远至少有一项），循环进去 0 个片段、也不加 `\n`，所以 `children` 是空的——断言 `root.children` 为空成立。若实现里把"空 children"改成"给个空串"，那条会红，**不要改断言去迁就**。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/widgets/ansi_text.dart test/ui/ansi_text_test.dart
git commit -m "$(cat <<'EOF'
feat(ui): ANSI 到 Flutter 的颜色与 TextSpan 映射

16 色 / 256 色的立方与灰阶 / 真彩色各有用例钉着。无颜色的字段一律留 null，
让主题决定 —— 硬编码黑白会让深色主题下的普通输出变成黑底黑字。

16 色表与 render/ansi_parser.dart 里那份是重复的，这是有意接受的：那份是
库私有，而把 Color 塞进 render/ 会让纯 Dart 模块（NFR-M-01）依赖 Flutter。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `send_range.dart` —— §5.1 的发送范围判定

**为什么先做它**：§9.2 第一条界面行为测试（发送范围）验的就是它，而它是**纯函数**——把边界（跨行选中、拖拽方向、全空行）在单测里钉死，比在 widget 测试里点鼠标可靠得多。编辑区面板（Task 7）只负责把 `TextEditingController.text` 与 `selection` 递进来。

**与 `CommandDispatcher.enqueue` 的关系（承重）**：

`enqueue` 自己会 `trim()` 并丢掉空串（`lib/command/command_dispatcher.dart:135-138`）。本函数必须**用同一套规则**过滤，否则"结果为空 → 给轻提示"这条会判错：本函数若判"有内容要发"而 dispatcher 清洗后全丢，用户既没看到命令发出、也没看到提示。

**顺带记一条既有缺陷**：FR-E-08 的逃生口"确需发送空行时，在行内输入一个空格"**当前不成立**——`enqueue` 的 `trim()` 会把 `' '` 变成 `''` 再丢掉，`test/command/command_dispatcher_test.dart:32` 那条用例（`enqueue(['', '   ', '\t', ''])` → 什么都不发）正好把它钉住了。本计划**不修**（改的是已合并的命令层语义），记在计划末尾的未决项里。

**Files:**
- Create: `lib/ui/widgets/send_range.dart`
- Test: `test/ui/send_range_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/widgets/send_range.dart';

void main() {
  group('无选中：发光标所在行', () {
    test('光标在第二行中间 → 只发第二行', () {
      const text = 'sys\ninterface GE0/0/1\nquit';
      // 'sys\n' 是 0..3，'interface GE0/0/1' 是 4..20
      const caret = TextSelection.collapsed(offset: 10);
      expect(commandsToSend(text, caret), ['interface GE0/0/1']);
    });

    test('光标停在行尾（正好在 \\n 之前）仍算该行', () {
      const text = 'sys\nquit';
      const caret = TextSelection.collapsed(offset: 3);
      expect(commandsToSend(text, caret), ['sys']);
    });

    test('光标停在 \\n 之后（下一行行首）算下一行', () {
      const text = 'sys\nquit';
      const caret = TextSelection.collapsed(offset: 4);
      expect(commandsToSend(text, caret), ['quit']);
    });

    test('光标在文末（最后一行）', () {
      const text = 'sys\nquit';
      const caret = TextSelection.collapsed(offset: 8);
      expect(commandsToSend(text, caret), ['quit']);
    });
  });

  group('有选中：发覆盖到的所有行，整行参与', () {
    test('只选中一行的中间几个字 → 整行', () {
      const text = 'sys\ninterface GE0/0/1\nquit';
      const sel = TextSelection(baseOffset: 6, extentOffset: 12);
      expect(commandsToSend(text, sel), ['interface GE0/0/1']);
    });

    test('跨两行、两端都只覆盖一部分 → 两行整行参与', () {
      const text = 'sys\ninterface GE0/0/1\nquit';
      const sel = TextSelection(baseOffset: 1, extentOffset: 15);
      expect(commandsToSend(text, sel), ['sys', 'interface GE0/0/1']);
    });

    test('拖拽方向反过来（从下往上选）结果相同', () {
      const text = 'sys\ninterface GE0/0/1\nquit';
      const forward = TextSelection(baseOffset: 1, extentOffset: 15);
      const backward = TextSelection(baseOffset: 15, extentOffset: 1);
      expect(commandsToSend(text, backward), commandsToSend(text, forward));
    });

    test('选中范围正好停在下一行行首 → 不把下一行算进来', () {
      const text = 'sys\nquit';
      // 0..4 覆盖 'sys\n' —— 第 4 个字符是下一行行首，没被覆盖到。
      const sel = TextSelection(baseOffset: 0, extentOffset: 4);
      expect(commandsToSend(text, sel), ['sys']);
    });

    test('顺序始终自上而下', () {
      const text = 'a\nb\nc';
      const sel = TextSelection(baseOffset: 0, extentOffset: 5);
      expect(commandsToSend(text, sel), ['a', 'b', 'c']);
    });
  });

  group('空白过滤', () {
    test('完全空白的行被丢掉（与 enqueue 的 trim 规则一致）', () {
      const text = 'sys\n\n   \nquit';
      const sel = TextSelection(baseOffset: 0, extentOffset: 14);
      expect(commandsToSend(text, sel), ['sys', 'quit']);
    });

    test('行的首尾空白被去掉', () {
      const text = '  sys  ';
      const caret = TextSelection.collapsed(offset: 4);
      expect(commandsToSend(text, caret), ['sys']);
    });

    test('全是空行 → 空列表（调用方据此给轻提示）', () {
      const text = '\n   \n\n';
      const caret = TextSelection.collapsed(offset: 2);
      expect(commandsToSend(text, caret), isEmpty);
    });

    test('空文本 → 空列表', () {
      expect(commandsToSend('', const TextSelection.collapsed(offset: 0)), isEmpty);
    });
  });

  group('linesToSend：行号（编辑区据此高亮已发送的行，FR-E-10）', () {
    test('行号自上而下，且与 commandsToSend 一一对应', () {
      const text = 'sys\n\ninterface GE0/0/1\nquit';
      const sel = TextSelection(baseOffset: 0, extentOffset: 25);
      expect(linesToSend(text, sel), [0, 2, 3]);
      expect(commandsToSend(text, sel), ['sys', 'interface GE0/0/1', 'quit'],
          reason: '两个函数必须同源，否则高亮的行与实际发出去的行会错位');
    });

    test('空白行不占行号（它没被发出去，不该被高亮）', () {
      const text = 'a\n   \nb';
      const sel = TextSelection(baseOffset: 0, extentOffset: 7);
      expect(linesToSend(text, sel), [0, 2]);
    });

    test('无选中时只给自己那一行', () {
      const text = 'a\nb\nc';
      expect(linesToSend(text, const TextSelection.collapsed(offset: 2)), [1]);
    });
  });

  group('\\r\\n 的行尾', () {
    test('CRLF 的行不会把 \\r 带进命令里', () {
      const text = 'sys\r\nquit';
      const sel = TextSelection(baseOffset: 0, extentOffset: 8);
      expect(commandsToSend(text, sel), ['sys', 'quit']);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `flutter test test/ui/send_range_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: .../send_range.dart`）。

- [ ] **Step 3: 实现**

```dart
import 'package:flutter/services.dart';

/// 按 spec §5.1 算出这一次「发送」该下发哪些行。
///
/// 规则逐条（§5.1 原文）：
/// - 有非空选中 → 取选中范围**覆盖到的所有行**，某一行只要被覆盖到任意一个
///   字符就**整行**参与；
/// - 没有选中 → 取光标所在的那一行（光标视为落在该行内）；
/// - 顺序始终按编辑区**自上而下**，与拖拽方向无关；
/// - 过滤掉完全空白的行；结果为空则由调用方给轻提示。
///
/// **过滤规则必须与 `CommandDispatcher.enqueue` 逐字一致**（它自己也会
/// `trim()` 并丢弃空串）。两边不一致的后果不是"多发一条"，而是**判错**：
/// 本函数说"有内容要发"、dispatcher 清洗后全丢，用户既没看到命令发出、
/// 也没看到"没有可发送的命令"的提示。所以这里用同一个 `trim().isEmpty`。
///
/// **关于 FR-E-08 的逃生口**：原文说"确需发送空行时，在行内输入一个空格"，
/// 但 `enqueue` 的 `trim()` 会把 `' '` 变成 `''` 再丢掉，所以那个逃生口当前
/// **不成立**。本函数与 dispatcher 保持一致（也丢），不假装它成立 —— 修它要
/// 动已合并的命令层语义，见计划末尾的未决项。
///
/// 实现上它只是 [linesToSend] 的一层投影。**两个函数必须同源** —— 编辑区拿
/// [linesToSend] 去高亮"已发送的行"（FR-E-10），拿本函数去真正下发；各算各的
/// 会让高亮的行与实际发出去的行错位。
List<String> commandsToSend(String text, TextSelection selection) {
  final lines = text.split('\n');
  return linesToSend(text, selection)
      .map((index) => lines[index].trim())
      .toList(growable: false);
}

/// 这一次「发送」实际会下发**哪些行**（自上而下的行号）。
///
/// 空白行**不占行号**：它不会被发出去，编辑区也就不该把它标成"已发送"。
///
/// 规则与边界见 [commandsToSend] 的文档，两条用例组各自钉着同一批边界。
List<int> linesToSend(String text, TextSelection selection) {
  if (text.isEmpty) return const [];

  final lines = text.split('\n');

  // 每一行的起始字符偏移。长度是 lines.length + 1，最后一项是文本总长，
  // 用来把"行号"换算回字符区间。
  final starts = <int>[];
  var offset = 0;
  for (final line in lines) {
    starts.add(offset);
    offset += line.length + 1; // +1 是被 split 吃掉的 '\n'
  }
  starts.add(offset);

  /// 某个字符偏移落在第几行。用二分而不是逐行扫：编辑区可能有几千行。
  int lineOf(int position) {
    var low = 0;
    var high = lines.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (starts[mid] <= position) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  final int firstLine;
  final int lastLine;
  if (selection.isCollapsed) {
    // `TextSelection.start` / `.end` 已经把方向归一化了（start <= end），
    // 所以"拖拽方向无关"是**构造上**成立的，不需要额外的判断。
    firstLine = lineOf(selection.start);
    lastLine = firstLine;
  } else {
    firstLine = lineOf(selection.start);
    // 覆盖区间是 [start, end) —— 最后一个被覆盖的字符在 end - 1。
    // 用 end 而不是 end - 1 是个真实的错：选中范围正好停在下一行行首时，
    // 会把下一行整行拖进来。
    lastLine = lineOf(selection.end - 1);
  }

  return [
    for (var i = firstLine; i <= lastLine; i++)
      if (lines[i].trim().isNotEmpty) i,
  ];
}
```

**为什么 `trim()` 顺带处理了 CRLF**：`trim()` 去的是首尾**空白**，而 `\r` 正是空白字符之一，所以 `'quit\r'` 会被修成 `'quit'`。这就是 CRLF 那条用例不需要额外分支的原因。

**为什么 `line.trim()` 能顺带处理 CRLF**：`trim()` 去的是首尾**空白**，而 `\r` 正是空白字符之一，所以 `'quit\r'` 会被修成 `'quit'`。这就是 CRLF 那条用例不需要额外分支的原因。

- [ ] **Step 4: 跑测试确认绿**

Run: `flutter test test/ui/send_range_test.dart`
Expected: 全绿（14 条）。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/widgets/send_range.dart test/ui/send_range_test.dart
git commit -m "$(cat <<'EOF'
feat(ui): §5.1 发送范围判定

有选中取覆盖到的整行（含跨行），无选中取光标行，顺序自上而下与拖拽方向无关，
空白行过滤后结果为空则由调用方给轻提示。

过滤用 trim().isEmpty，与 CommandDispatcher.enqueue 逐字一致 —— 两边不一致的
后果不是多发一条而是判错：本函数说"有得发"、dispatcher 清洗后全丢，用户既没
看到命令发出也没看到提示。

顺带记录：FR-E-08 的逃生口（"输入一个空格"发送空行）当前不成立，enqueue 的
trim 会把它丢掉。本计划不修，见计划末尾未决项。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `draft_autosave.dart` —— 草稿防抖落盘与退出兜底

**为什么它是独立可测的**：FR-E-03/04 的两半（切走再切回来还在 / 退出再进来还在）落在 `DraftStore` + `draftProvider` 上，5a 已经做完；**缺的是"谁来调 `save()`"**。计划 5a 收尾时核实过：`DraftNotifier.save()` 在整个 `lib/` 里**零调用者**，`main.dart` / `app.dart` 里也没有任何退出钩子。

**保存时机（用户 2026-09-25 知情下的决定）**：**编辑停顿后防抖落盘 + 退出时兜底**，而不是 FR-E-04 字面上的"只在退出时落盘"。理由：退出才写的实现在崩溃/断电时丢掉全部编辑内容，而草稿是纯文本小文件，多写几次的代价可以忽略（`DraftStore` 走原子写）。

**Files:**
- Create: `lib/ui/draft_autosave.dart`
- Test: `test/ui/draft_autosave_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/draft_autosave.dart';

void main() {
  test('编辑停顿之后才落盘，连串编辑只落一次', () {
    fakeAsync((async) {
      final saved = <String>[];
      final autosave = DraftAutosave(
        save: (text) async => saved.add(text),
        debounce: const Duration(milliseconds: 500),
      );

      autosave.schedule('a');
      async.elapse(const Duration(milliseconds: 100));
      autosave.schedule('ab');
      async.elapse(const Duration(milliseconds: 100));
      autosave.schedule('abc');
      expect(saved, isEmpty, reason: '停顿还没到，不该落盘');

      async.elapse(const Duration(milliseconds: 500));
      expect(saved, ['abc'], reason: '只落最后那一次');

      autosave.dispose();
    });
  });

  test('flush 立刻落盘并取消待定的防抖（退出兜底，FR-E-04）', () {
    fakeAsync((async) {
      final saved = <String>[];
      final autosave = DraftAutosave(
        save: (text) async => saved.add(text),
        debounce: const Duration(milliseconds: 500),
      );

      autosave.schedule('写了一半');
      autosave.flush();
      expect(saved, ['写了一半'], reason: '退出时必须立刻落盘，不能等防抖');

      // 防抖定时器要真的被取消掉，否则退出后还会再来一次（重复写同一内容）。
      async.elapse(const Duration(seconds: 2));
      expect(saved, ['写了一半']);

      autosave.dispose();
    });
  });

  test('内容没变就不落盘（切设备/重建不该产生无谓的写）', () {
    fakeAsync((async) {
      final saved = <String>[];
      final autosave = DraftAutosave(
        save: (text) async => saved.add(text),
        debounce: const Duration(milliseconds: 100),
      );

      autosave.schedule('same');
      async.elapse(const Duration(milliseconds: 200));
      expect(saved, ['same']);

      autosave.schedule('same');
      async.elapse(const Duration(milliseconds: 200));
      expect(saved, ['same'], reason: '与上次落盘的内容相同就不再写');

      autosave.dispose();
    });
  });

  test('落盘失败不抛出（FR-E-04 不该拖垮界面）', () {
    fakeAsync((async) {
      final errors = <Object>[];
      final autosave = DraftAutosave(
        save: (text) async => throw StateError('磁盘满了'),
        debounce: const Duration(milliseconds: 50),
        onError: errors.add,
      );

      autosave.schedule('x');
      async.elapse(const Duration(milliseconds: 100));

      expect(errors, hasLength(1), reason: '失败要报给调用方去提示');
      // 关键：异常没有冒到 zone 外 —— fakeAsync 里未捕获的异步异常会让用例红。

      autosave.dispose();
    });
  });

  test('dispose 之后不再落盘', () {
    fakeAsync((async) {
      final saved = <String>[];
      final autosave = DraftAutosave(
        save: (text) async => saved.add(text),
        debounce: const Duration(milliseconds: 50),
      );

      autosave.schedule('x');
      autosave.dispose();
      async.elapse(const Duration(seconds: 1));
      expect(saved, isEmpty, reason: 'dispose 要取消待定的写');
    });
  });
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `flutter test test/ui/draft_autosave_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: .../draft_autosave.dart`）。

- [ ] **Step 3: 实现**

```dart
import 'dart:async';

/// 编辑区草稿的落盘节流（FR-E-03 / FR-E-04）。
///
/// **保存时机是"停顿后防抖 + 退出兜底"，不是 FR-E-04 字面上的"只在退出时
/// 落盘"。** 退出才写的实现在崩溃/断电时丢掉全部编辑内容；而草稿是纯文本小
/// 文件，`DraftStore` 走原子写，多写几次的代价可以忽略。这是知情下的取舍。
///
/// **它不认识 Riverpod，也不认识 `DraftStore`** —— 落盘动作由构造时传入的
/// [save] 承担。这样它可以脱开界面用 `fakeAsync` 精确验证（防抖时序最容易写错，
/// 而它恰好是纯逻辑）。
class DraftAutosave {
  DraftAutosave({
    required this.save,
    this.debounce = const Duration(milliseconds: 500),
    this.onError,
  });

  /// 真正落盘的动作。异常由本类捕获并交给 [onError]。
  final Future<void> Function(String text) save;

  /// 编辑停止多久之后落盘。
  final Duration debounce;

  /// 落盘失败的回调。**别在这里抛** —— 它在 `catch` 里被调用，抛出去会冒到
  /// 编辑区的输入路径上。
  final void Function(Object error)? onError;

  Timer? _timer;

  /// 待落盘的内容。null 表示"没有待写的东西"。
  String? _pending;

  /// 上一次**成功交给 [save]** 的内容。用来跳过无谓的重复写 —— 切设备会重建
  /// 编辑区、`setState` 会重跑 `initState` 之外的路径，那些都不该产生磁盘写。
  String? _lastSaved;

  bool _disposed = false;

  /// 编辑区内容变了。停顿 [debounce] 之后落盘。
  void schedule(String text) {
    if (_disposed) return;
    if (text == _lastSaved && _pending == null) return;
    _pending = text;
    _timer?.cancel();
    _timer = Timer(debounce, _write);
  }

  /// 立刻落盘并取消待定的防抖。**应用退出时调用**（FR-E-04 的"退出时落盘"）。
  void flush() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _write();
  }

  void _write() {
    _timer = null;
    final text = _pending;
    if (text == null) return;
    _pending = null;
    // 先记下再写：写失败时不该让 `schedule` 以为"内容没变"而拒绝重试，
    // 那样用户改动后的第二次编辑会被静默丢掉。
    if (text == _lastSaved) return;
    _lastSaved = text;
    // `save` 返回的 Future 必须被接住 —— 它是异步的，异常不会在这里同步抛出。
    // 用 `catchError` 而不是 `try/catch`：后者接不住没有 await 的 Future。
    save(text).catchError((Object error) {
      onError?.call(error);
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
```

- [ ] **Step 4: 跑测试确认绿**

Run: `flutter test test/ui/draft_autosave_test.dart`
Expected: 5 条全绿。

**若"落盘失败不抛出"那条红了**：说明 `catchError` 接住的异常仍冒到了 zone —— 检查是不是写成了 `save(text); try { ... } catch`。`save(text)` 是 `Future`，同步的 `try/catch` 接不住它。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/draft_autosave.dart test/ui/draft_autosave_test.dart
git commit -m "$(cat <<'EOF'
feat(ui): 草稿防抖落盘与退出兜底（FR-E-03 / FR-E-04）

5a 收尾时核实过：DraftNotifier.save() 在整个 lib/ 里零调用者，退出钩子也
没有 —— "能保存用户配置命令"这一步是断的。

保存时机取"停顿后防抖 + 退出兜底"，不是 FR-E-04 字面上的"只在退出时落盘"：
后者崩溃就丢全部编辑内容，而草稿是纯文本小文件、DraftStore 走原子写。

本类不认识 Riverpod 也不认识 DraftStore，落盘动作由构造时传入，所以防抖时序
可以脱开界面用 fakeAsync 钉死。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 输出区 —— `AutoScroll` 与输出面板

**§9.2 的第 5、6 条界面行为测试落在本任务**（输出自动滚动 / 清屏不动日志）。

**为什么把"跟不跟到底"抽成一个类**：它是有状态的判断（用户滚上去就要停跟、滚回底部就要恢复），而它的判别力**完全**取决于滚动位置。若把它做成面板的私有方法，验证就得靠 `tester.drag` 去拖一个 `SelectableText.rich` —— 而 `SelectableText` 自带选择手势，垂直拖拽会不会被它吃掉是实现细节，测出来的红绿可能是手势竞争的产物而非逻辑对错。抽出来之后可以用一个**普通 `ListView`** 精确驱动。

**Files:**
- Create: `lib/ui/widgets/auto_scroll.dart`
- Create: `lib/ui/panels/output_panel.dart`
- Test: `test/ui/auto_scroll_test.dart`
- Test: `test/ui/output_panel_test.dart`
- Create: `test/ui/ui_harness.dart`（后续几个面板测试共用）

- [ ] **Step 1: 写 `AutoScroll` 的失败测试**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/widgets/auto_scroll.dart';

void main() {
  /// 造一个 200 逻辑像素高的滚动区，每项 50 高。
  Future<(ScrollController, ValueNotifier<int>)> pumpList(
    WidgetTester tester, {
    int items = 5,
  }) async {
    final controller = ScrollController();
    final count = ValueNotifier<int>(items);
    addTearDown(controller.dispose);
    addTearDown(count.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: ValueListenableBuilder<int>(
              valueListenable: count,
              builder: (_, n, __) => ListView.builder(
                controller: controller,
                itemCount: n,
                itemBuilder: (_, i) => SizedBox(height: 50, child: Text('第 $i 行')),
              ),
            ),
          ),
        ),
      ),
    );
    return (controller, count);
  }

  testWidgets('一开始就是贴底的', (tester) async {
    final (controller, _) = await pumpList(tester);
    final auto = AutoScroll(controller: controller);
    expect(auto.stickToBottom, isTrue,
        reason: '刚打开输出区应当看到最新的一行，而不是最旧的一行');
  });

  testWidgets('内容变长时跟到底部', (tester) async {
    final (controller, count) = await pumpList(tester);
    final auto = AutoScroll(controller: controller);
    expect(controller.position.maxScrollExtent, 50, reason: '5×50 - 200');

    count.value = 30;
    await tester.pump();
    auto.onContentChanged();

    expect(controller.offset, controller.position.maxScrollExtent,
        reason: '新内容到达时应当滚到最新一行');
  });

  testWidgets('用户滚上去之后不再被拽回底部', (tester) async {
    final (controller, count) = await pumpList(tester);
    final auto = AutoScroll(controller: controller);

    count.value = 30;
    await tester.pump();
    auto.onContentChanged();
    expect(controller.offset, controller.position.maxScrollExtent);

    // 用户滚到顶 —— 这一步是直接改 offset，不经过手势。
    controller.jumpTo(0);
    auto.onUserScroll();
    expect(auto.stickToBottom, isFalse, reason: '滚离底部就该停止跟底');

    count.value = 60;
    await tester.pump();
    auto.onContentChanged();

    expect(controller.offset, 0,
        reason: '**这是这个类存在的理由**：用户在看上面的行时，新输出不该把他拽走');
  });

  testWidgets('用户滚回底部之后恢复跟底', (tester) async {
    final (controller, count) = await pumpList(tester);
    final auto = AutoScroll(controller: controller);

    count.value = 30;
    await tester.pump();
    auto.onContentChanged();
    controller.jumpTo(0);
    auto.onUserScroll();
    expect(auto.stickToBottom, isFalse);

    controller.jumpTo(controller.position.maxScrollExtent);
    auto.onUserScroll();
    expect(auto.stickToBottom, isTrue);

    count.value = 60;
    await tester.pump();
    auto.onContentChanged();
    expect(controller.offset, controller.position.maxScrollExtent);
  });

  testWidgets('jumpToBottom 无条件恢复跟底（"回到底部"按钮）', (tester) async {
    final (controller, count) = await pumpList(tester);
    final auto = AutoScroll(controller: controller);

    count.value = 30;
    await tester.pump();
    auto.onContentChanged();
    controller.jumpTo(0);
    auto.onUserScroll();
    expect(auto.stickToBottom, isFalse);

    auto.jumpToBottom();
    expect(auto.stickToBottom, isTrue);
    expect(controller.offset, controller.position.maxScrollExtent);
  });
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `flutter test test/ui/auto_scroll_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: .../auto_scroll.dart`）。

- [ ] **Step 3: 实现 `AutoScroll`**

```dart
import 'package:flutter/widgets.dart';

/// 输出区的"跟着最新一行走"（FR-O-04）。
///
/// 规则：默认贴底；用户自己滚离底部就**停止**跟底（他在读上面的行，新输出不该
/// 把他拽走）；用户滚回底部就恢复；另有 [jumpToBottom] 给"回到底部"按钮用。
///
/// **抽成独立的类而不是面板的私有方法，是为了可测。** 判别力完全取决于滚动
/// 位置，而面板里那块是 `SelectableText.rich` —— 它自带选择手势，用
/// `tester.drag` 去驱动得到的结果可能是手势竞争的产物。这里不碰任何手势：
/// 调用方（面板）从滚动通知里调 [onUserScroll]，从刷新回调里调
/// [onContentChanged]。
class AutoScroll {
  AutoScroll({required this.controller, this.slack = 4});

  final ScrollController controller;

  /// 距底部多少像素以内还算"贴底"。浮点误差会让"正好滚到底"差那么零点几，
  /// 不留余量的话用户手动滚到底也恢复不了跟底。
  final double slack;

  bool _stick = true;

  /// 当前是否跟着最新一行走。面板据此决定要不要显示"回到底部"按钮。
  bool get stickToBottom => _stick;

  /// 用户自己滚动了 —— 据**当前**位置重新判定。
  ///
  /// **只在用户驱动的滚动里调**。若在程序化的跟底滚动里也调，跟底那一跳会
  /// 先把它自己判成"贴底"（结论相同），但内容刚变长、还没跳的那一瞬间会被
  /// 判成"离底"从而永久停跟 —— 那正是这个类要避免的。
  void onUserScroll() {
    if (!controller.hasClients) return;
    _stick = controller.position.extentAfter <= slack;
  }

  /// 内容变长了 —— 若还贴着底就跟到底。
  ///
  /// **必须在内容**布局完之后**调**（面板里是 `addPostFrameCallback`）：
  /// 早一帧的话 `maxScrollExtent` 还是旧值，跳过去就停在倒数第二屏。
  void onContentChanged() {
    if (!_stick) return;
    if (!controller.hasClients) return;
    controller.jumpTo(controller.position.maxScrollExtent);
  }

  /// 主动回到底部（"回到底部"按钮 / 清屏之后）。
  void jumpToBottom() {
    _stick = true;
    if (!controller.hasClients) return;
    controller.jumpTo(controller.position.maxScrollExtent);
  }
}
```

- [ ] **Step 4: 跑测试确认绿**

Run: `flutter test test/ui/auto_scroll_test.dart`
Expected: 5 条全绿。

- [ ] **Step 5: 写输出面板的测试夹具**

`test/ui/ui_harness.dart` —— 后面几个面板测试都要装配一棵能跑的 provider 树，写一份：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/providers.dart';

import '../fixtures/fake_session.dart';

/// 把 [child] 装进一棵**能真跑**的 provider 树里。
///
/// 覆盖的四项与 `test/ui/app_test.dart` 逐字相同，理由也一样：
/// `SessionNotifier.build()` 要 `appStoresProvider` / `startupProvider` /
/// `sessionFactoryProvider`，而 `Directory(settings.logDir ?? ref.read(logsDirPath))`
/// 里的 `logsDirPath` 没覆盖就抛 `StateError`。
Future<void> pumpUi(
  WidgetTester tester, {
  required Directory root,
  required Widget child,
  List<DeviceProfile> devices = const [],
  AppSettings settings = const AppSettings(),
  FakeSessionFactory? factory,
  List<Override> extra = const [],
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
        ...extra,
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}
```

**`ScrollController.dispose` 的注意**：`pumpUi` 里的 `MaterialApp` 会让布局稳定下来；面板测试若需要固定高度，把 `child` 包进 `SizedBox(height: ...)` 再传进来。

- [ ] **Step 6: 写输出面板的失败测试**

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/panels/output_panel.dart';

import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_out_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 直接拿到那台设备的缓冲（面板订阅的是同一个实例）。
  OutputBuffer bufferOf(WidgetTester tester) {
    final element = tester.element(find.byType(OutputPanel));
    return ProviderScope.containerOf(element).read(outputBufferProvider('d1'));
  }

  testWidgets('标题栏显示当前设备名（FR-O-08）', (tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [fakeProfile(id: 'd1', name: '核心交换机')],
      child: const SizedBox(height: 300, child: OutputPanel(deviceId: 'd1')),
    );

    expect(find.text('核心交换机'), findsOneWidget);
  });

  testWidgets('新到达的输出会渲染出来，并滚到最新一行（FR-O-04）', (tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [fakeProfile(id: 'd1', name: 'A')],
      child: const SizedBox(height: 200, child: OutputPanel(deviceId: 'd1')),
    );

    final buffer = bufferOf(tester);
    // 100 行 × 约 20 逻辑像素，远超 200 高的视口。
    for (var i = 0; i < 100; i++) {
      buffer.add('第 $i 行\n');
    }
    // 两条：一条给 RefreshThrottle 的定时器，一条给跟底那一跳。
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();

    final controller = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    expect(controller.offset, controller.position.maxScrollExtent,
        reason: '新输出到达时应当看到最新的一行');
  });

  testWidgets('清屏只清显示内容，日志那一路分毫不动（FR-O-05 / §9.2 第 6 条）',
      (tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [fakeProfile(id: 'd1', name: 'A')],
      child: const SizedBox(height: 300, child: OutputPanel(deviceId: 'd1')),
    );

    final buffer = bufferOf(tester);
    // 挂上日志出口，模拟一次真会话在写日志。
    final logged = <String>[];
    buffer.onText = logged.add;
    addTearDown(() => buffer.onText = null);

    buffer.add('清屏之前\n');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    expect(find.textContaining('清屏之前'), findsOneWidget);

    await tester.tap(find.byTooltip('清屏'));
    await tester.pumpAndSettle();
    expect(find.textContaining('清屏之前'), findsNothing, reason: '显示内容该被清掉');

    buffer.add('清屏之后\n');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    expect(find.textContaining('清屏之后'), findsOneWidget);

    expect(logged.join(), contains('清屏之前'),
        reason: 'FR-O-05 只清显示：清屏不该让已经写进日志的内容消失');
    expect(logged.join(), contains('清屏之后'),
        reason: '清屏之后流还在继续，后续输出照常进日志');
  });

  testWidgets('半条控制序列不会渲染成字面文本（承接 5a 的留存边界）', (tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [fakeProfile(id: 'd1', name: 'A')],
      child: const SizedBox(height: 300, child: OutputPanel(deviceId: 'd1')),
    );

    final buffer = bufferOf(tester);
    buffer.add('前\x1b[3');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    expect(find.textContaining('[3'), findsNothing, reason: '半条序列应当被留住');

    buffer.add('2m绿\x1b[0m\n');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    expect(find.textContaining('绿'), findsOneWidget);
    expect(find.textContaining('2m'), findsNothing);
  });
}
```

**`find.textContaining` 与 `TextSpan` 树**：`SelectableText.rich` 的 `find.textContaining` 会匹配到整棵树的纯文本，所以这些断言是有效的。若某条查不到，**先确认面板确实用了 `SelectableText.rich` 而不是 `RichText`** —— `RichText` 不参与 `find.text*` 的语义树。

- [ ] **Step 7: 跑测试确认红**

Run: `flutter test test/ui/output_panel_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: .../output_panel.dart`）。

- [ ] **Step 8: 实现输出面板**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/device_profile.dart';
import '../../state/output_buffer.dart';
import '../../state/providers.dart';
import '../widgets/ansi_text.dart';
import '../widgets/auto_scroll.dart';
import '../widgets/refresh_throttle.dart';

/// 输出区（FR-O）：当前设备的输出、自动滚动、清屏。
///
/// **它订阅 `outputBufferProvider`，不订阅任何 `Session`。** 缓冲活得比一次
/// 会话长（FR-O-09：切走再切回来还看得到完整过程），所以重连换掉整个会话时
/// 这里什么都不用做。
///
/// **刷新走 [RefreshThrottle]，不直接监听缓冲。** NFR-F-02 要求节流到约 60ms
/// 一次 —— 设备可以 200 行/秒地吐，直接监听就是一秒重建 200 次这棵树。
class OutputPanel extends ConsumerStatefulWidget {
  const OutputPanel({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<OutputPanel> createState() => _OutputPanelState();
}

class _OutputPanelState extends ConsumerState<OutputPanel> {
  final ScrollController _scroll = ScrollController();
  late final AutoScroll _auto = AutoScroll(controller: _scroll);

  RefreshThrottle? _throttle;
  OutputBuffer? _buffer;

  @override
  void dispose() {
    _throttle?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 订阅当前设备的缓冲。**换设备时要把上一个节流器拆掉** —— 否则它会一直
  /// 挂在那台设备的缓冲上，而它的 `_onRefresh` 会去动一个已经换了内容的滚动区。
  void _bind(OutputBuffer buffer) {
    if (identical(buffer, _buffer)) return;
    _throttle?.dispose();
    _buffer = buffer;
    _throttle = RefreshThrottle(source: buffer)..addListener(_onRefreshed);
  }

  void _onRefreshed() {
    if (!mounted) return;
    setState(() {});
    // 新内容要**下一帧**才布局完，跟底那一跳必须排在它后面。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _auto.onContentChanged());
    });
  }

  String _deviceName(List<DeviceProfile> devices) {
    for (final device in devices) {
      if (device.id == widget.deviceId) return device.name;
    }
    return widget.deviceId;
  }

  @override
  Widget build(BuildContext context) {
    _bind(ref.watch(outputBufferProvider(widget.deviceId)));
    final devices = ref.watch(devicesProvider);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(theme, devices),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            children: [
              NotificationListener<UserScrollNotification>(
                // 用户自己滚动时重新判定跟不跟底。**用 UserScrollNotification
                // 而不是 ScrollNotification**：后者连程序化的跟底那一跳也会报，
                // 那会把"刚变长还没跳"的一瞬间判成离底，从此永久停跟。
                onNotification: (_) {
                  _auto.onUserScroll();
                  setState(() {});
                  return false;
                },
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(8),
                  child: SelectableText.rich(
                    ansiLinesToTextSpan(
                      ref.watch(outputBufferProvider(widget.deviceId)).lines,
                    ),
                    // 等宽：设备回显的表格与命令靠它对齐。
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: ['DejaVu Sans Mono'],
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
              if (!_auto.stickToBottom)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton.small(
                    tooltip: '回到底部',
                    onPressed: () => setState(_auto.jumpToBottom),
                    child: const Icon(Icons.arrow_downward),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(ThemeData theme, List<DeviceProfile> devices) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.terminal, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _deviceName(devices),
              style: theme.textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '清屏',
            icon: const Icon(Icons.clear_all, size: 18),
            onPressed: () {
              _buffer?.clear();
              setState(_auto.jumpToBottom);
            },
          ),
        ],
      ),
    );
  }
}
```

**注意 `_bind` 在 `build` 里调**：这是有意的 —— provider 的值在 build 时才拿得到，而 `_bind` 幂等（同一个缓冲直接返回）。它只在 `setState` 里做一次赋值，不触发递归重建。

**它不写日志、不碰会话**：清屏走的是 `OutputBuffer.clear()`，而那个方法按设计不调 `onText`（见它的文档）。所以 §9.2 第 6 条是**构造上**成立的，那条用例把它钉住。

- [ ] **Step 9: 跑测试确认绿**

Run: `flutter test test/ui/output_panel_test.dart`
Expected: 4 条全绿。

**若"滚到最新一行"那条红了**：先打印 `controller.offset` 与 `maxScrollExtent` 看差多少。差一个屏幕说明 `onContentChanged` 排在了布局之前（`addPostFrameCallback` 写成了直接调）；差几像素说明 `slack` 之外还有别的滚动修正介入 —— 那种情况下**不要**去调大 `slack` 掩盖，先把真实原因写进报告。

- [ ] **Step 10: 提交**

```bash
git add lib/ui/widgets/auto_scroll.dart lib/ui/panels/output_panel.dart test/ui/auto_scroll_test.dart test/ui/output_panel_test.dart test/ui/ui_harness.dart
git commit -m "$(cat <<'EOF'
feat(ui): 输出区（ANSI 渲染 / 自动滚动 / 清屏）

跟不跟底抽成 AutoScroll：它的判别力完全取决于滚动位置，做成面板私有方法就
只能用 tester.drag 去拖 SelectableText.rich，而它自带选择手势 —— 测出来的
红绿可能是手势竞争的产物而非逻辑对错。抽出来用普通 ListView 精确驱动。

刷新走 RefreshThrottle（NFR-F-02），不直接监听缓冲：设备可 200 行/秒地吐，
直接监听就是一秒重建 200 次这棵树。

清屏只清显示内容这条是构造上成立的 —— OutputBuffer.clear() 按设计不调
onText，用例把它钉住（§9.2 第 6 条）。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: 命令编辑区

**§9.2 的第 1、3 条落在本任务**（发送范围 / 后台队列）。

**Files:**
- Create: `lib/ui/widgets/sent_line_controller.dart`
- Create: `lib/ui/panels/editor_panel.dart`
- Test: `test/ui/sent_line_controller_test.dart`
- Test: `test/ui/editor_panel_test.dart`

**关于"已发送的行高亮"（FR-E-10）**：它靠覆写 `TextEditingController.buildTextSpan` 实现。**必须处理输入法组字状态** —— 组字期间（`value.composing` 有效）不能改写 span，否则中日文输入法的下划线会消失、候选窗口定位会错。这不是理论顾虑：本应用的用户要输中文设备名与中文命令。

- [ ] **Step 1: 写 `SentLineController` 的失败测试**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/widgets/sent_line_controller.dart';

void main() {
  Future<TextSpan> spanOf(
    WidgetTester tester,
    SentLineController controller,
  ) async {
    late TextSpan span;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              style: const TextStyle(fontSize: 14),
              withComposing: false,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    return span;
  }

  testWidgets('没有已发送行时就是普通控制器', (tester) async {
    final controller = SentLineController()..text = '第一行\n第二行';
    addTearDown(controller.dispose);
    final span = await spanOf(tester, controller);
    expect(span.toPlainText(), '第一行\n第二行');
  });

  testWidgets('被标记的行用暗色，其余行不指定颜色', (tester) async {
    final controller = SentLineController()..text = '已发\n未发';
    addTearDown(controller.dispose);
    controller.sentLines.add(0);

    final span = await spanOf(tester, controller);
    expect(span.toPlainText(), '已发\n未发', reason: '高亮不能改动文本内容本身');

    final children = span.children!.cast<TextSpan>();
    final sent = children.firstWhere((s) => s.text == '已发');
    final unsent = children.firstWhere((s) => s.text == '未发');
    expect(sent.style?.color, isNotNull, reason: '已发送的行要被标出来');
    expect(unsent.style?.color, isNull, reason: '未发送的行保持主题默认色');
  });

  testWidgets('组字期间不改写 span（中文输入法靠这个）', (tester) async {
    final controller = SentLineController()..text = 'zhong';
    addTearDown(controller.dispose);
    controller.sentLines.add(0);
    controller.value = controller.value.copyWith(
      composing: TextRange(start: 0, end: 5),
    );

    late TextSpan span;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              style: const TextStyle(fontSize: 14),
              withComposing: true,
            );
            return const SizedBox();
          },
        ),
      ),
    );

    // 走的是父类实现 —— 组字下划线由此保留。
    expect(span.toPlainText(), 'zhong');
    expect(span.style?.decoration, TextDecoration.underline,
        reason: '组字下划线必须还在，否则中文输入法的候选提示会没有锚点');
  });

  testWidgets('行数变了之后旧的行号标记不会串到别的行上', (tester) async {
    final controller = SentLineController()..text = 'a\nb\nc';
    addTearDown(controller.dispose);
    controller.sentLines
      ..clear()
      ..add(2);
    final span = await spanOf(tester, controller);
    final children = span.children!.cast<TextSpan>();
    expect(children.firstWhere((s) => s.text == 'c').style?.color, isNotNull);
    expect(children.firstWhere((s) => s.text == 'a').style?.color, isNull);
  });
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `flutter test test/ui/sent_line_controller_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: .../sent_line_controller.dart`）。

- [ ] **Step 3: 实现 `SentLineController`**

```dart
import 'package:flutter/material.dart';

/// 会**把已发送的行标暗**的编辑控制器（FR-E-10）。
///
/// 覆写 [buildTextSpan] 而不是在编辑区上叠一层自绘：`TextField` 只认控制器给出
/// 的 span，另起一层就得自己同步滚动位置、字体度量、光标位置 —— 那三样
/// 任何一样错了都会让高亮和文字错位。
class SentLineController extends TextEditingController {
  /// 已发送的**行号**（0 起）。发送时由 `linesToSend` 给出的那批。
  final Set<int> sentLines = <int>{};

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // **组字期间一律交回父类。** 父类会把组字区间加上下划线，而中文输入法的
    // 候选窗要靠那段下划线定位。自己拼 span 会让组字提示消失 —— 本应用的
    // 用户要输中文设备名与中文命令，这不是边角情况。
    if (withComposing && !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    if (sentLines.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final dimmed = (style ?? const TextStyle()).copyWith(
      color: Theme.of(context).disabledColor,
    );

    final children = <TextSpan>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) children.add(const TextSpan(text: '\n'));
      children.add(
        TextSpan(text: lines[i], style: sentLines.contains(i) ? dimmed : null),
      );
    }
    return TextSpan(style: style, children: children);
  }
}
```

**`TextSpan.toPlainText()`**：它把子节点的文本拼起来，所以"高亮不改内容"那条断言成立。若实现里改成了给**整段**加样式（`TextSpan(text: text, style: dimmed)`），"未发送的行保持默认色"那条会红 —— 那是对的，别改断言。

- [ ] **Step 4: 跑测试确认绿**

Run: `flutter test test/ui/sent_line_controller_test.dart`
Expected: 4 条全绿。

- [ ] **Step 5: 写编辑区的失败测试**

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';
import 'package:win_cli_tool/ui/widgets/sent_line_controller.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_ed_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> pumpEditor(
    WidgetTester tester, {
    FakeSessionFactory? factory,
  }) => pumpUi(
    tester,
    root: root,
    devices: [fakeProfile(id: 'd1', name: 'A')],
    factory: factory,
    child: const SizedBox(height: 400, child: EditorPanel(deviceId: 'd1')),
  );

  testWidgets('发送选中范围覆盖到的行（§9.2 第 1 条）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    // 先把会话连上，`enqueue` 才有 dispatcher 可进。
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'sys\ninterface GE0/0/1\nquit');
    await tester.pump();
    // 只选中第二行的中间几个字符 —— 期望整行发出，且只有那一行。
    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    controller.selection = const TextSelection(baseOffset: 6, extentOffset: 12);
    await tester.pump();

    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(
      factory.sessions.single.written.map((w) => w.trim()),
      ['interface GE0/0/1'],
      reason: '有选中就只发选中的行，且整行参与',
    );
  });

  testWidgets('没有可发送的命令时给轻提示，不静默（§5.1）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   \n\n');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    expect(find.text('没有可发送的命令'), findsOneWidget);
    expect(factory.sessions.single.written, isEmpty);
  });

  testWidgets('队列执行中显示进度，发送按钮转为停止（§9.2 第 3 条）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a\nb\nc');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    expect(find.textContaining('执行中'), findsOneWidget,
        reason: 'FR-E-14：队列执行中要有 执行中 n/m');
    expect(find.byTooltip('中止'), findsOneWidget);

    // 让队列自己跑完（FakeSession 的提示符是同步回的）。
    await tester.pumpAndSettle();
    expect(find.byTooltip('发送'), findsOneWidget, reason: '队列空了应当能再发');
  });

  testWidgets('未连接时发送按钮不可用（§9.2 第 4 条的一半）', (tester) async {
    await pumpEditor(tester);
    final button = tester.widget<IconButton>(find.byTooltip('发送'));
    expect(button.onPressed, isNull, reason: '没有会话时发出去的命令会掉进空处');
  });

  testWidgets('已发送的行被标出来（FR-E-10）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a\nb');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!
            as SentLineController;
    expect(controller.sentLines, {0, 1});
  });
}
```

**夹具的实际情况（已核实，不要再猜）**：`test/fixtures/fake_session.dart` 里
`FakeSession` 记的是 `final written = <String>[]`，内容是 `Session.write` 收到的
**原始文本（含行尾）** —— 所以断言要 `.map((w) => w.trim())`。它**没有** `sent`
也没有 `aborted`。`FakeSessionFactory.sessions` 是 `List<FakeSession>`，`create()`
时就 `add`（**所以"建了 controller"与"被连了"在它这里无法区分** —— 见 Task 9
Step 9 的警告）。

**别为了断言去改产品代码**；`written` 已经够用。真需要新字段时只在夹具上加。

- [ ] **Step 6: 跑测试确认红**

Run: `flutter test test/ui/editor_panel_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: .../editor_panel.dart`）。

- [ ] **Step 7: 实现编辑区**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../command/command_dispatcher.dart';
import '../../data/draft_store.dart';
import '../../state/providers.dart';
import '../draft_autosave.dart';
import '../widgets/send_range.dart';
import '../widgets/sent_line_controller.dart';

/// 命令编辑区（FR-E）：行号栏、多行输入、发送/中止、队列进度、草稿。
///
/// **它只经 `sessionProvider` 拿会话**（`enqueue` / `abort`），永远不碰
/// `Session` 对象本身 —— 所有权规则：界面只订阅 `ConnectionManager` 派生的
/// 状态，会话的时序约定由 `SessionController` 处理完。
class EditorPanel extends ConsumerStatefulWidget {
  const EditorPanel({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<EditorPanel> createState() => _EditorPanelState();
}

class _EditorPanelState extends ConsumerState<EditorPanel> {
  final SentLineController _text = SentLineController();
  final ScrollController _gutter = ScrollController();
  final ScrollController _editor = ScrollController();

  late final DraftAutosave _autosave = DraftAutosave(
    save: (text) => ref.read(draftProvider(widget.deviceId).notifier).save(text),
    onError: (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('草稿未能保存')),
      );
    },
  );

  /// 草稿是否已经灌进控制器。**每换一台设备要重置** —— 否则切到 B 设备后，
  /// A 的文本会一直留在编辑区里。
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
    _editor.addListener(_syncGutter);
    _loadDraft();
  }

  @override
  void didUpdateWidget(EditorPanel old) {
    super.didUpdateWidget(old);
    if (old.deviceId == widget.deviceId) return;
    // 换设备：先把上一台的草稿落盘（不能等防抖），再清空载入新的。
    _autosave.flush();
    _autosave.dispose();
    _text
      ..sentLines.clear()
      ..text = '';
    _seeded = false;
    _loadDraft();
  }

  @override
  void dispose() {
    // **退出兜底（FR-E-04）**：把还压在防抖里的最后一次编辑写下去。
    _autosave.flush();
    _autosave.dispose();
    _text.removeListener(_onTextChanged);
    _editor.removeListener(_syncGutter);
    _text.dispose();
    _gutter.dispose();
    _editor.dispose();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    try {
      final text = await ref.read(draftProvider(widget.deviceId).future);
      if (!mounted) return;
      setState(() {
        _seeded = true;
        _text.text = text;
      });
    } on DraftUnreadableException {
      // FR-E-03 的失败分支：草稿文件读不了（不是 UTF-8 / 读盘失败）。
      // **不降级成空串** —— 那会让用户以为草稿没了而其实文件还在。
      if (!mounted) return;
      setState(() => _seeded = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('草稿无法读取（文件不是 UTF-8 或读盘失败），已从空白开始')),
      );
    }
  }

  void _onTextChanged() {
    if (!_seeded) return;
    _autosave.schedule(_text.text);
    // 行数变了，行号栏要跟着重画。
    setState(() {});
  }

  void _syncGutter() {
    if (!_gutter.hasClients) return;
    if (_gutter.offset == _editor.offset) return;
    _gutter.jumpTo(_editor.offset);
  }

  void _send() {
    final commands = commandsToSend(_text.text, _text.selection);
    if (commands.isEmpty) {
      // §5.1 结尾：结果为空时给轻提示。**不能静默** —— 用户按了发送却什么都没
      // 发生，会以为程序卡了。
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可发送的命令'), duration: Duration(seconds: 2)),
      );
      return;
    }
    final notifier = ref.read(sessionProvider(widget.deviceId).notifier);
    notifier.enqueue(commands);
    if (mounted) {
      setState(() {
        _text.sentLines
          ..clear()
          ..addAll(linesToSend(_text.text, _text.selection));
      });
    }
  }

  /// FR-E-14 的进度文案。**`PagerContinued` 不产生进度变化**（翻页不是命令），
  /// 所以它落在最后那个 `return null` 上。
  String? _progress(DispatchEvent? event) {
    if (event is CommandSent) return '执行中 ${event.index}/${event.total}';
    if (event is CommandCompleted) {
      return event.timedOut
          ? '第 ${event.index}/${event.total} 条超时'
          : '已完成 ${event.index}/${event.total}';
    }
    if (event is QueueAborted) return '已中止（${event.dropped} 条未发送）';
    if (event is QueueDropped) return '断线，${event.count} 条未发送的命令已丢弃';
    if (event is QueueFinished) return '队列完成';
    return null;
  }
```

`build` 部分：

```dart
  @override
  Widget build(BuildContext context) {
    final status = ref.watch(sessionProvider(widget.deviceId));
    final connected = status.state == DeviceConnectionState.connected;
    final progress = _progress(status.lastDispatchEvent);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(context, connected: connected, progress: progress),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _gutterWidget(context),
              const VerticalDivider(width: 1),
              Expanded(
                child: TextField(
                  controller: _text,
                  scrollController: _editor,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(8),
                    hintText: '在此输入命令，每行一条',
                  ),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: ['DejaVu Sans Mono'],
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
```

行号栏与工具栏：

```dart
  /// 行号栏。**行高必须与 `TextField` 的 `style` 完全一致**（同字体、同字号、
  /// 同 `height`）—— 差一点就会越往下越错位。
  Widget _gutterWidget(BuildContext context) {
    const lineStyle = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: ['DejaVu Sans Mono'],
      fontSize: 13,
      height: 1.35,
    );
    final count = '\n'.allMatches(_text.text).length + 1;
    return Container(
      width: 44,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        controller: _gutter,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 1; i <= count; i++)
              Text(
                '$i',
                key: ValueKey('gutter-$i'),
                textAlign: TextAlign.right,
                style: lineStyle.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(
    BuildContext context, {
    required bool connected,
    required String? progress,
  }) {
    final busy = progress != null && (progress.startsWith('执行中'));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '连接',
            icon: const Icon(Icons.link, size: 18),
            onPressed: connected
                ? null
                : () => ref.read(sessionProvider(widget.deviceId).notifier).connect(),
          ),
          IconButton(
            tooltip: '断开',
            icon: const Icon(Icons.link_off, size: 18),
            onPressed: connected
                ? () => ref
                      .read(sessionProvider(widget.deviceId).notifier)
                      .disconnect()
                : null,
          ),
          const SizedBox(width: 8),
          if (busy)
            IconButton(
              tooltip: '中止',
              icon: const Icon(Icons.stop, size: 18),
              onPressed: () =>
                  ref.read(sessionProvider(widget.deviceId).notifier).abort(),
            )
          else
            IconButton(
              tooltip: '发送',
              icon: const Icon(Icons.send, size: 18),
              onPressed: connected ? _send : null,
            ),
          const Spacer(),
          if (progress != null)
            Text(progress, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
```

**为什么"未连接时发送不可用"**：`SessionController.enqueue` 在未连接时**什么都不做**（`_manager.dispatcher?.enqueue`），所以按钮可点而命令掉进空处是最糟的一种"看起来能用"。禁用 + tooltip 说明才是诚实的。

- [ ] **Step 8: 跑测试确认绿**

Run: `flutter test test/ui/editor_panel_test.dart`
Expected: 5 条全绿。

- [ ] **Step 9: 提交**

```bash
git add lib/ui/widgets/sent_line_controller.dart lib/ui/panels/editor_panel.dart test/ui/sent_line_controller_test.dart test/ui/editor_panel_test.dart
git commit -m "$(cat <<'EOF'
feat(ui): 命令编辑区（发送范围 / 队列进度 / 草稿 / 已发送行高亮）

已发送行高亮覆写 buildTextSpan 而不是叠一层自绘 —— 后者要自己同步滚动位置、
字体度量、光标位置，任何一样错了高亮就和文字错位。

组字期间一律交回父类：中文输入法的候选窗靠组字下划线定位，自己拼 span 会让
提示消失，而本应用的用户要输中文设备名。

未连接时发送按钮禁用：SessionController.enqueue 在未连接时什么都不做，可点
而命令掉进空处是最糟的一种"看起来能用"。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: 设备列表面板

**§9.2 的第 4 条落在本任务**（设备按钮状态）。

**Files:**
- Create: `lib/ui/widgets/status_dot.dart`
- Create: `lib/ui/panels/device_list_panel.dart`
- Test: `test/ui/device_list_panel_test.dart`

**本任务不含"编辑设备"入口。** 设备编辑对话框属 5b-2，所以右键菜单只有 连接 /
断开 / 删除三项；删除带一个内联的确认对话框（不需要设备编辑那一套表单，所以
留在 5b-1 是合适的）。

- [ ] **Step 1: 写失败测试**

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_manager.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/panels/device_list_panel.dart';
import 'package:win_cli_tool/ui/widgets/status_dot.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_dev_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> pumpList(
    WidgetTester tester, {
    FakeSessionFactory? factory,
  }) => pumpUi(
    tester,
    root: root,
    devices: [
      fakeProfile(id: 'd1', name: '核心交换机'),
      fakeProfile(id: 'd2', name: '边界防火墙'),
    ],
    factory: factory,
    child: const DeviceListPanel(),
  );

  testWidgets('列出全部设备，状态点是"未连接"（§9.2 第 4 条）', (tester) async {
    await pumpList(tester);
    expect(find.text('核心交换机'), findsOneWidget);
    expect(find.text('边界防火墙'), findsOneWidget);

    final dots = tester.widgetList<DeviceStatusDot>(find.byType(DeviceStatusDot));
    expect(dots, hasLength(2));
    expect(dots.every((d) => d.state == DeviceConnectionState.disconnected), isTrue);
  });

  testWidgets('点击一台设备会把它选中', (tester) async {
    await pumpList(tester);
    final element = tester.element(find.byType(DeviceListPanel));
    final container = ProviderScope.containerOf(element);
    expect(container.read(selectedDeviceProvider), 'd1', reason: '默认选第一台');

    await tester.tap(find.text('边界防火墙'));
    await tester.pumpAndSettle();
    expect(container.read(selectedDeviceProvider), 'd2');
  });

  testWidgets('连上之后状态点变绿（§9.2 第 4 条）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpList(tester, factory: factory);

    await tester.tap(find.byTooltip('连接 核心交换机'));
    await tester.pumpAndSettle();

    final dots = tester
        .widgetList<DeviceStatusDot>(find.byType(DeviceStatusDot))
        .toList();
    expect(dots.first.state, DeviceConnectionState.connected);
    expect(dots.last.state, DeviceConnectionState.disconnected,
        reason: '只连了一台，另一台不该跟着变');
  });

  testWidgets('右键菜单能删掉一台设备，且删之前要确认（FR-D-04）', (tester) async {
    await pumpList(tester);
    final element = tester.element(find.byType(DeviceListPanel));
    final container = ProviderScope.containerOf(element);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('边界防火墙')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('确认删除'), findsOneWidget, reason: '删设备是不可逆的');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(devicesProvider), hasLength(2), reason: '取消不该删');

    // 再来一次，这回确认。
    final again = await tester.startGesture(
      tester.getCenter(find.text('边界防火墙')),
      buttons: kSecondaryButton,
    );
    await again.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();

    expect(container.read(devicesProvider).map((d) => d.id), ['d1']);
  });

  testWidgets('拖拽能改顺序，且顺序落到 devices.json（FR-D-03）', (tester) async {
    await pumpList(tester);
    final element = tester.element(find.byType(DeviceListPanel));
    final container = ProviderScope.containerOf(element);
    expect(container.read(devicesProvider).map((d) => d.id), ['d1', 'd2']);

    // 抓住第一台的拖拽把手，往下拖过第二台。
    final handle = find.byIcon(Icons.drag_handle).first;
    final from = tester.getCenter(handle);
    final to = tester.getCenter(find.text('边界防火墙'));

    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(Offset(from.dx, to.dy + 20));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(container.read(devicesProvider).map((d) => d.id), ['d2', 'd1']);
  });
}
```

**`kSecondaryButton` 来自 `package:flutter/gestures.dart`** —— 若分析器报未定义，加那行 import。

**测试里 `tester.tap(find.byTooltip('连接 核心交换机'))` 的 tooltip 名字是约定**：每台设备的按钮 tooltip 必须带上设备名，否则两台设备的按钮在测试里无法区分 —— 而"区分彼此"正是 §9.2 第 4 条要验的东西。

- [ ] **Step 2: 跑测试确认红**

Run: `flutter test test/ui/device_list_panel_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: .../device_list_panel.dart`）。

- [ ] **Step 3: 实现状态点**

```dart
import 'package:flutter/material.dart';

import '../../connection/connection_manager.dart';

/// 设备状态点（§7.1 的左侧列表）。
///
/// **颜色与文案由 [state] 一处决定**，不要在别处再写一份 `switch` —— 两处
/// 各写一份的下场是加了新状态之后其中一处悄悄落进 `default`。
class DeviceStatusDot extends StatelessWidget {
  const DeviceStatusDot({super.key, required this.state, this.size = 10});

  final DeviceConnectionState state;
  final double size;

  static Color colorOf(BuildContext context, DeviceConnectionState state) =>
      switch (state) {
        DeviceConnectionState.disconnected => Theme.of(context).disabledColor,
        DeviceConnectionState.connecting => Colors.amber,
        DeviceConnectionState.connected => Colors.green,
        DeviceConnectionState.reconnecting => Colors.orange,
        DeviceConnectionState.failed => Theme.of(context).colorScheme.error,
      };

  /// 悬停说明。**`failed` 用"连接失败"而不是"已断开"** —— 两者的下一步动作
  /// 不同（一个要查配置，一个可以直接重连）。
  static String labelOf(DeviceConnectionState state) => switch (state) {
    DeviceConnectionState.disconnected => '未连接',
    DeviceConnectionState.connecting => '连接中',
    DeviceConnectionState.connected => '已连接',
    DeviceConnectionState.reconnecting => '重连中',
    DeviceConnectionState.failed => '连接失败',
  };

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: labelOf(state),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: colorOf(context, state),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 实现设备列表面板**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/device_profile.dart';
import '../../state/providers.dart';
import '../widgets/status_dot.dart';

/// 设备列表（FR-D）：选中、连接/断开、拖拽排序、删除。
///
/// **它自己不持有"当前选中哪台"，选中状态在 `selectedDeviceProvider`。**
/// 编辑区与输出区都要读它，而窗口级的快捷键也要读 —— 那不是某个 widget 的
/// 内部状态。
class DeviceListPanel extends ConsumerWidget {
  const DeviceListPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final selected = ref.watch(selectedDeviceProvider);

    if (devices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('还没有设备', textAlign: TextAlign.center),
        ),
      );
    }

    return ReorderableListView.builder(
      itemCount: devices.length,
      onReorder: (oldIndex, newIndex) {
        // **`ReorderableListView` 的 `newIndex` 是"插入到删除之前的哪个位置"**，
        // 所以往后拖时要减一。少了这一步的表现是"往下拖一格没反应、拖两格只
        // 动一格"。
        if (newIndex > oldIndex) newIndex -= 1;
        final ids = devices.map((d) => d.id).toList();
        final moved = ids.removeAt(oldIndex);
        ids.insert(newIndex, moved);
        ref.read(devicesProvider.notifier).reorder(ids);
      },
      itemBuilder: (context, index) {
        final device = devices[index];
        return _DeviceTile(
          key: ValueKey(device.id),
          device: device,
          selected: device.id == selected,
          index: index,
        );
      },
    );
  }
}

class _DeviceTile extends ConsumerWidget {
  const _DeviceTile({
    super.key,
    required this.device,
    required this.selected,
    required this.index,
  });

  final DeviceProfile device;
  final bool selected;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(sessionProvider(device.id));
    final live = status.state == DeviceConnectionState.connected;

    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showMenu(context, ref, details.globalPosition),
      child: ListTile(
        selected: selected,
        onTap: () => ref.read(selectedDeviceProvider.notifier).select(device.id),
        leading: DeviceStatusDot(state: status.state),
        title: Text(device.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${device.host}:${device.port}',
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // tooltip 带设备名：两台设备的按钮必须能彼此区分。
            IconButton(
              tooltip: live ? '断开 ${device.name}' : '连接 ${device.name}',
              icon: Icon(live ? Icons.link_off : Icons.link, size: 18),
              onPressed: () {
                final notifier = ref.read(sessionProvider(device.id).notifier);
                if (live) {
                  notifier.disconnect();
                } else {
                  notifier.connect();
                }
              },
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.drag_handle, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
    if (choice != 'delete' || !context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('删除「${device.name}」？它的命令库与草稿会一并删除，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // **先把选中挪走再删。** 顺序反了的话，`sessionProvider(已删除的 id)` 会在
    // 被拆掉之前先被建一次 —— 而 `SessionNotifier.build()` 要从设备列表里
    // `firstWhere`，那个 id 已经不在了。
    if (ref.read(selectedDeviceProvider) == device.id) {
      final rest = ref
          .read(devicesProvider)
          .where((d) => d.id != device.id)
          .toList();
      ref
          .read(selectedDeviceProvider.notifier)
          .select(rest.isEmpty ? null : rest.first.id);
    }
    await ref.read(devicesProvider.notifier).remove(device.id);
  }
}
```

**`sessionProvider` 的订阅会不会建出一个不该建的会话？** 会 —— `ref.watch(sessionProvider(device.id))` 会给**每一台**设备建一个 controller。那是设计如此：`ConnectionManager` 在没有 `connect()` 时不开任何连接，而列表需要每台设备的状态点。**它不会自动连**（`autoConnect` 的扫描只在启动时跑一次，见 `connectAutoConnectDevices`）。

- [ ] **Step 5: 跑测试确认绿**

Run: `flutter test test/ui/device_list_panel_test.dart`
Expected: 5 条全绿。

**若拖拽那条红了**：先确认 `kSecondaryButton` 的 import 在不在，再看 `moveTo` 的落点是否越过了第二项的**中线** —— `ReorderableListView` 按中线决定插入位置，拖到刚过一点是不够的。按 `to.dy + 20` 仍不过中线时把它调大，但**要在报告里说明调整了什么、为什么**。

- [ ] **Step 6: 提交**

```bash
git add lib/ui/widgets/status_dot.dart lib/ui/panels/device_list_panel.dart test/ui/device_list_panel_test.dart
git commit -m "$(cat <<'EOF'
feat(ui): 设备列表（状态点 / 连接断开 / 拖拽排序 / 删除）

状态点的颜色与文案由 state 一处决定，不在别处再写第二份 switch —— 两处各写
一份的下场是加了新状态之后其中一处悄悄落进 default。

ReorderableListView 的 newIndex 是"插入到删除之前的哪个位置"，往后拖要减一；
少了这一步的表现是"往下拖一格没反应、拖两格只动一格"。

删除前先挪走选中：顺序反了的话 sessionProvider(已删除的 id) 会先被建一次，
而 SessionNotifier.build() 要从设备列表 firstWhere，那个 id 已经不在了。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: 主窗口、分隔条与快捷键

**§9.2 的第 2 条落在本任务**（设备切换）。

**本任务要改两处已提交的代码**，都在下面 Step 2 里给全：把编辑区与输出区的
State 类**公开**并各留一个动作方法，供窗口级快捷键调用。

**Files:**
- Modify: `lib/ui/panels/editor_panel.dart`（State 类公开 + `send()` 公开）
- Modify: `lib/ui/panels/output_panel.dart`（State 类公开 + `clearOutput()` 公开）
- Modify: `lib/state/providers.dart`（加 `selectedDeviceProvider`）
- Create: `lib/ui/widgets/splitter.dart`
- Create: `lib/ui/main_window.dart`
- Modify: `lib/app.dart`（`home` 换成 `MainWindow`）
- Test: `test/ui/main_window_test.dart`

- [ ] **Step 1: 在 `providers.dart` 末尾加选中设备**

```dart
/// 当前选中的设备（界面的选择状态）。
///
/// **它在状态层而不是某个 widget 的 State 里**：设备列表、编辑区、输出区三处
/// 都要读它，窗口级的快捷键也要读。
///
/// `build()` 用 `read` 取初始值，所以**删掉当前选中的设备之后它不会自动挪走**
/// —— 处理那件事的是设备列表面板的删除路径（先 select 再 remove）。主窗口另外
/// 还会挡一道：它只把"确实还在设备列表里"的 id 交给面板（见 `main_window.dart`
/// 的 `_active`），所以残留的过期选中不会让面板去建一个不存在的会话。
class SelectedDeviceNotifier extends Notifier<String?> {
  @override
  String? build() {
    final devices = ref.read(devicesProvider);
    return devices.isEmpty ? null : devices.first.id;
  }

  void select(String? id) => state = id;
}

final selectedDeviceProvider =
    NotifierProvider<SelectedDeviceNotifier, String?>(SelectedDeviceNotifier.new);
```

- [ ] **Step 2: 把那两个 State 类公开**

`editor_panel.dart`：

- `ConsumerState<EditorPanel> createState() => EditorPanelState();`
- `class _EditorPanelState extends ConsumerState<EditorPanel>` → `class EditorPanelState extends ConsumerState<EditorPanel>`
- `void _send()` → `void send()`
- 工具栏里 `onPressed: connected ? _send : null` → `onPressed: connected ? send : null`

`output_panel.dart`：

- `ConsumerState<OutputPanel> createState() => OutputPanelState();`
- `class _OutputPanelState` → `class OutputPanelState`
- 清屏按钮的 `onPressed` 抽成公开方法：

```dart
  /// 清屏（FR-O-05 / Ctrl+L）。**只在显示层动手**：`OutputBuffer.clear()` 按
  /// 设计不调 `onText`，所以日志分毫不动。
  void clearOutput() {
    _buffer?.clear();
    setState(_auto.jumpToBottom);
  }
```

并把按钮改成 `onPressed: clearOutput`。

- [ ] **Step 3: 写失败测试**

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/main_window.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';
import 'package:win_cli_tool/ui/panels/output_panel.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_win_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> pumpWindow(
    WidgetTester tester, {
    FakeSessionFactory? factory,
    AppSettings settings = const AppSettings(),
  }) => pumpUi(
    tester,
    root: root,
    devices: [
      fakeProfile(id: 'd1', name: '核心交换机', autoConnect: true),
      fakeProfile(id: 'd2', name: '边界防火墙'),
    ],
    settings: settings,
    factory: factory,
    child: const MainWindow(),
  );

  testWidgets('三个区都在，且默认选中第一台（§7.1 的布局）', (tester) async {
    await pumpWindow(tester);
    expect(find.byType(EditorPanel), findsOneWidget);
    expect(find.byType(OutputPanel), findsOneWidget);
    expect(find.text('核心交换机'), findsWidgets);
  });

  testWidgets('切换设备会把编辑区与输出区都换过去（§9.2 第 2 条）', (tester) async {
    await pumpWindow(tester);

    var editor = tester.widget<EditorPanel>(find.byType(EditorPanel));
    expect(editor.deviceId, 'd1');

    await tester.tap(find.text('边界防火墙'));
    await tester.pumpAndSettle();

    editor = tester.widget<EditorPanel>(find.byType(EditorPanel));
    final output = tester.widget<OutputPanel>(find.byType(OutputPanel));
    expect(editor.deviceId, 'd2', reason: '编辑区要跟着换');
    expect(output.deviceId, 'd2', reason: '输出区也要跟着换，否则会看到上一台的输出');
  });

  testWidgets('切换设备时草稿跟着换（FR-E-03）', (tester) async {
    await pumpWindow(tester);

    await tester.enterText(find.byType(TextField), 'sys');
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.text('边界防火墙'));
    await tester.pumpAndSettle();
    expect(find.text('sys'), findsNothing, reason: 'B 设备不该看到 A 的草稿');

    await tester.tap(find.text('核心交换机').first);
    await tester.pumpAndSettle();
    expect(find.text('sys'), findsOneWidget, reason: '切回来草稿还在');
  });

  testWidgets('Ctrl+L 清屏（§4.8）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpWindow(tester, factory: factory);
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(MainWindow));
    final container = ProviderScope.containerOf(element);
    container.read(outputBufferProvider('d1')).add('一些输出\n');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    expect(find.textContaining('一些输出'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.textContaining('一些输出'), findsNothing);
  });

  testWidgets('Esc 中止命令队列（§4.8）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpWindow(tester, factory: factory);
    await tester.tap(find.byTooltip('连接 核心交换机'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a\nb\nc\nd');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final session = factory.sessions.single;
    // **队列是一条一条发的**：第一条出去之后要等提示符才轮到第二条。这里一直
    // 没吐提示符，所以此刻出去的只有头一条（或还没有 —— 见下面的写法）。
    final before = session.written.length;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 中止之后把提示符补上：队列若还活着，下一条会跟着出去。
    session.emit('<Huawei>');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    // **断言写成"没有再增加"而不是"等于某一条"**：前者不依赖"第一条是同步写出
    // 去的"这个实现细节，而后者会。判别力不受影响 —— 没有 abort 的话，这个
    // 提示符会让队列前进，`written` 必然变长。
    expect(session.written.length, before,
        reason: 'Esc 之后剩余命令不该再发出去（FR-E-13）');
  });

  testWidgets('分隔条拖动会写回 editorSplitRatio（§7.3）', (tester) async {
    await pumpWindow(tester);
    final element = tester.element(find.byType(MainWindow));
    final container = ProviderScope.containerOf(element);
    final before = container.read(settingsProvider).editorSplitRatio;

    final splitter = find.byKey(const ValueKey('splitter-h'));
    await tester.drag(splitter, const Offset(0, 60));
    await tester.pumpAndSettle();

    final after = container.read(settingsProvider).editorSplitRatio;
    expect(after, greaterThan(before), reason: '往下拖应当让编辑区变高');
  });
}
```

**夹具的实际情况（已核实）**：`FakeSession` 有 `written`（`Session.write` 收到的
原始文本，含行尾）、`emit(String)`（模拟对端吐数据）、`drop()`（模拟断线）；它
**没有** `sent`，也**没有** `aborted` —— `abort()` 不写任何东西，所以它只能通过
"队列有没有继续前进"间接观察，这正是上面那条用例的写法。

**`FakeSessionFactory.sessions` 在 `create()` 时就把会话 `add` 进去**，所以它记的
是"**建过**几个会话"而不是"连上了几个"。`app_test.dart` 里那条 autoConnect 断言
靠的是"`create()` 只在真的去连时才被调用"，不是靠 `sessions` 的语义 —— 别把它
读成后者。

- [ ] **Step 4: 跑测试确认红**

Run: `flutter test test/ui/main_window_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: .../main_window.dart`）。

- [ ] **Step 5: 实现分隔条**

```dart
import 'package:flutter/material.dart';

/// 可拖拽分隔条（§7.3）。
///
/// **它只上报"新的比例"，不自己存。** 比例的真相在 `AppSettings.editorSplitRatio`
/// 里，存两份必然有一份会旧。
class Splitter extends StatelessWidget {
  const Splitter({
    super.key,
    required this.axis,
    required this.onDrag,
    this.thickness = 6,
  });

  /// 分隔条的走向。**纵向**分隔条（左右分栏之间）用 [Axis.vertical]。
  final Axis axis;

  /// 拖动时回调：参数是**沿拖动方向的像素增量**。
  final void Function(double delta) onDrag;

  final double thickness;

  @override
  Widget build(BuildContext context) {
    final cursor = axis == Axis.vertical
        ? SystemMouseCursors.resizeColumn
        : SystemMouseCursors.resizeRow;
    return MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: axis == Axis.vertical
            ? (d) => onDrag(d.delta.dx)
            : null,
        onVerticalDragUpdate: axis == Axis.horizontal
            ? (d) => onDrag(d.delta.dy)
            : null,
        child: SizedBox(
          width: axis == Axis.vertical ? thickness : null,
          height: axis == Axis.horizontal ? thickness : null,
          child: Center(
            child: Container(
              width: axis == Axis.vertical ? 1 : null,
              height: axis == Axis.horizontal ? 1 : null,
              color: Theme.of(context).dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 6: 实现主窗口**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../state/providers.dart';
import 'panels/device_list_panel.dart';
import 'panels/editor_panel.dart';
import 'panels/output_panel.dart';
import 'widgets/splitter.dart';

/// 主窗口（§7.1）：工具栏 + 左侧设备列表 + 右上编辑区 + 右下输出区。
///
/// **它是唯一持有那两把 `GlobalKey` 的地方**，因为窗口级的快捷键（§4.8）要
/// 调到编辑区的"发送"与输出区的"清屏" —— 那两个动作的状态在各自的 State 里。
/// 把动作上提到 provider 也能做，但那样 `TextEditingController` 与滚动位置
/// 也跟着上提，得不偿失。
class MainWindow extends ConsumerStatefulWidget {
  const MainWindow({super.key});

  @override
  ConsumerState<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends ConsumerState<MainWindow> {
  final _editorKey = GlobalKey<EditorPanelState>();
  final _outputKey = GlobalKey<OutputPanelState>();

  static const double _minPane = 160;

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider);
    final selected = ref.watch(selectedDeviceProvider);
    final settings = ref.watch(settingsProvider);

    // **过期的选中在这里被挡掉。** 删掉一台设备之后 `selected` 可能还指着它，
    // 而 `sessionProvider(那个 id)` 会去设备列表里 `firstWhere` 并抛。挡在这一处，
    // 两个面板与快捷键就都不用各自防一遍。
    final active = devices.any((d) => d.id == selected) ? selected : null;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): _clearOutput,
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true): _clearOutput,
        const SingleActivator(LogicalKeyboardKey.escape): _abort,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _addDevice,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _addDevice,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('网络设备命令行工具'),
            actions: [
              IconButton(
                tooltip: '添加设备',
                icon: const Icon(Icons.add),
                onPressed: _addDevice,
              ),
            ],
          ),
          body: active == null ? _empty() : _body(active, settings),
        ),
      ),
    );
  }

  Widget _empty() => const Center(child: Text('请先添加一台设备'));

  Widget _body(String deviceId, AppSettings settings) {
    // 工具栏的"添加设备"与 Ctrl+N 都走这里。设备编辑对话框属 5b-2，所以 5b-1
    // 只能给出提示 —— **这是一个已知的占位**，不是遗漏。
    void addDevice() => _addDevice();

    return Row(
      children: [
        SizedBox(
          width: settings.deviceListWidth,
          child: DeviceListPanel(),
        ),
        // 设备列表与右侧之间的分隔条改动的是列表宽度。
        Splitter(
          key: const ValueKey('splitter-v'),
          axis: Axis.vertical,
          onDrag: (delta) {
            final next = (settings.deviceListWidth + delta)
                .clamp(_minPane, 480.0);
            if (next == settings.deviceListWidth) return;
            ref
                .read(settingsProvider.notifier)
                .update(settings.copyWith(deviceListWidth: next));
          },
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final total = constraints.maxHeight;
              final editorHeight =
                  (total * settings.editorSplitRatio).clamp(_minPane, total - _minPane);
              return Column(
                children: [
                  SizedBox(
                    height: editorHeight,
                    child: EditorPanel(key: _editorKey, deviceId: deviceId),
                  ),
                  Splitter(
                    key: const ValueKey('splitter-h'),
                    axis: Axis.horizontal,
                    onDrag: (delta) {
                      if (total <= 0) return;
                      final next = ((editorHeight + delta) / total).clamp(0.15, 0.85);
                      ref
                          .read(settingsProvider.notifier)
                          .update(settings.copyWith(editorSplitRatio: next));
                    },
                  ),
                  Expanded(
                    child: OutputPanel(key: _outputKey, deviceId: deviceId),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  void _send() => _editorKey.currentState?.send();

  void _clearOutput() => _outputKey.currentState?.clearOutput();

  void _abort() {
    final id = ref.read(selectedDeviceProvider);
    if (id == null) return;
    ref.read(sessionProvider(id).notifier).abort();
  }

  void _addDevice() {
    // FR-D-01 / Ctrl+N。**设备编辑对话框属 5b-2**，这里是有意留的占位：
    // 快捷键的接线（本任务真正要交付的东西）是真的，落点还没有。
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设备编辑对话框将在 5b-2 提供')),
    );
  }
}
```

**`_body` 里那个 `addDevice` 局部函数是多余的吗？** 是 —— 删掉它，`_empty()`
分支之外不需要它。上面留着是为了让你看清它**不该**存在；实现时不要写它。

**`AppSettings` 需要一个新字段 `deviceListWidth`。** 在 `lib/models/app_settings.dart`
里按既有字段的写法加：`final double deviceListWidth`，默认 `240`，进构造函数的
默认值、`copyWith`、`fromJson`（`(json['deviceListWidth'] as num?)?.toDouble() ?? 240`）
与 `toJson`。**照抄 `editorSplitRatio` 那一套**（它的默认值是 0.4）。

- [ ] **Step 7: 把主窗口接进 `app.dart`**

```dart
      home: const MainWindow(),
```

并把 `_PlaceholderPage` **整个类删掉**（它的文档写着"别在这里长东西"），以及
`app.dart` 顶部不再需要的 import。

- [ ] **Step 8: 跑测试确认绿**

Run: `flutter test test/ui/main_window_test.dart`
Expected: 6 条全绿。

- [ ] **Step 9: 跑全仓，确认 `app_test.dart` 的两条没被外壳换掉打红**

Run: `flutter test`
Expected: 全绿。

**`app_test.dart` 的第 2 条（autoConnect 扫描）值得单独看一眼**：它现在装的是
真的 `MainWindow`，而 `MainWindow` 会给**每一台**设备建 `sessionProvider`。
`autoConnect: false` 的那台被建出 controller 不等于被连接，所以那条断言
（`factory.sessions` 只有一台）应当仍然成立。**若它变红，先查
`FakeSessionFactory` 是不是在 `create` 时就把 session 记进了 `sessions`** ——
若是，那说明该断言本来就没在验"谁被连了"。**这种情况要停下来报告**，
不要改断言。

- [ ] **Step 10: 提交**

```bash
git add lib/ui/main_window.dart lib/ui/widgets/splitter.dart lib/ui/panels/editor_panel.dart lib/ui/panels/output_panel.dart lib/state/providers.dart lib/models/app_settings.dart lib/app.dart test/ui/main_window_test.dart test/state/providers_test.dart test/models/app_settings_test.dart
git commit -m "$(cat <<'EOF'
feat(ui): 主窗口、分隔条与四个快捷键（§4.8 / §7.1）

过期选中在 MainWindow 一处挡掉：删掉设备后 selected 可能还指着它，而
sessionProvider(那个 id) 会去列表 firstWhere 并抛。挡在一处，两个面板与快捷键
都不用各自防一遍。

分隔条只上报新比例，不自己存 —— 比例的真相在 AppSettings.editorSplitRatio，
存两份必然有一份会旧。

Ctrl+N 目前只给提示（设备编辑对话框属 5b-2）。快捷键接线是真的，落点是占位，
这是知情留的。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: golden 截图

**为什么做**：用户看不到界面 —— 这台机器 `DISPLAY` 是空的、Xvfb 没装，GUI 起不来。
golden PNG 是**唯一**能让用户看到"界面长什么样"的东西（2026-09-25 拍板的验收方式）。

**代价是已知且已接受的**：golden 对字体与渲染后端敏感，换机器/换字体版本就会变，
界面改样子时要重新生成。所以它们**默认不跑**（见下面的开关），不会让 `flutter test`
在别的机器上变红。

**Files:**
- Create: `test/ui/golden_harness.dart`
- Create: `test/ui/main_window_golden_test.dart`
- Create: `test/ui/golden/*.png`（生成物，**要提交**）
- Modify: `test/ui/ui_harness.dart`（`pumpUi` 加 `theme` 与 `debugShowCheckedModeBanner`）

- [ ] **Step 1: 探针测过的三件事，写代码时必须照做**

| 结论 | 做法 |
| --- | --- |
| `FontLoader` 能加载 `.ttc` 字体集合，中文真渲染 | 加载 `NotoSansCJK-Regular.ttc`，family 名叫 `Noto Sans CJK SC` |
| **不指定 `fontFamily` 的文字渲染成豆腐块** | golden 的主题必须显式设 `fontFamily` |
| 默认画布 800×600 @DPR 3.0，且 `MaterialApp` 带 debug 横幅 | 显式设 `physicalSize` + `devicePixelRatio: 1.0`，并 `debugShowCheckedModeBanner: false` |

- [ ] **Step 2: 写 golden 夹具**

```dart
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
const _monoFamily = 'DejaVu Sans Mono';

/// 把中文字体与等宽字体装进测试进程。
///
/// **字体族名必须与 [goldenTheme] 里写的 `fontFamily` 逐字相同** —— 实测过：
/// 不指定 `fontFamily` 的文字会渲染成豆腐块（一排方框），而不是回退到某个能
/// 显示中文的字体。
Future<void> loadTestFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    final loader = FontLoader(family)
      ..addFont(Future.value(file.readAsBytesSync().buffer.asByteData()));
    await loader.load();
  }

  // NotoSansCJK-Regular.ttc 是一个**字体集合**，`FontLoader` 收得下（实测）。
  await load(_cjkFamily, '/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc');
  await load(_monoFamily, '/usr/share/fonts/dejavu/DejaVuSansMono.ttf');
}

/// 本机缺少 golden 需要的字体时，**跳过而不是失败**。
///
/// 换一台机器（或换个发行版的字体包）就没有这些文件，而那不是本项目的回归。
/// 报成红的只会训练人忽略红的。
bool get fontsAvailable =>
    File('/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc').existsSync();

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
```

- [ ] **Step 3: 写 golden 用例**

```dart
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/main_window.dart';
import 'package:win_cli_tool/ui/panels/device_list_panel.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';
import 'package:win_cli_tool/ui/panels/output_panel.dart';

import '../fixtures/fake_session.dart';
import 'golden_harness.dart';

/// golden 的开关：**默认跳过**。
///
/// 跑它们：
/// ```
/// WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart
/// ```
/// 界面改样子之后重新生成：
/// ```
/// WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart --update-goldens
/// ```
///
/// **为什么不默认跑**：golden 的比对结果取决于字体文件与渲染后端。换机器、
/// 换字体版本、换 Flutter 版本都会变 —— 而那不是回归。默认跑的下场是
/// `flutter test` 在别人机器上变红，然后所有人学会忽略红。
void main() {
  final skip = !goldensEnabled
      ? 'golden 默认不跑（设 WCT_GOLDEN=1 开启）'
      : (!fontsAvailable ? '本机缺少 golden 需要的中文字体' : null);

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_golden_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  // **`fakeProfile` 目前不接受 `host`**（已核实：只有 `id` / `name` /
  // `autoConnect` / `postLogin`）。给它加两个可选参数，让每台设备的副标题在
  // golden 里彼此不同 —— 三台都写 `10.0.0.1:22` 的截图看不出列表在渲染什么：
  //
  //   DeviceProfile fakeProfile({
  //     String id = 'd1',
  //     String name = '核心交换机',
  //     String host = '10.0.0.1',
  //     int port = 22,
  //     bool autoConnect = false,
  //     List<String> postLogin = const [],
  //   }) => DeviceProfile(
  //     ... host: host, port: port, ...
  //   );
  //
  // **只改夹具，不改产品代码。**
  final devices = [
    fakeProfile(id: 'd1', name: '核心交换机-01', host: '10.0.0.1'),
    fakeProfile(id: 'd2', name: '边界防火墙', host: '10.0.0.254'),
    fakeProfile(id: 'd3', name: '接入交换机-3F', host: '10.0.1.7'),
  ];

  /// 往缓冲里灌一段**带颜色**的、像真设备回显的输出。
  void seedOutput(WidgetTester tester, String deviceId) {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MainWindow)),
    );
    final buffer = container.read(outputBufferProvider(deviceId));
    buffer.add('\x1b[1m<Huawei>display version\x1b[0m\n');
    buffer.add('Huawei Versatile Routing Platform Software\n');
    buffer.add('VRP (R) software, Version 8.180 (CE6865 V200R019C10SPC800)\n');
    buffer.add('\x1b[32mInfo:\x1b[0m 系统运行正常，已运行 \x1b[33m42\x1b[0m 天\n');
    buffer.add('\x1b[31mError:\x1b[0m 接口 GE0/0/3 光模块 \x1b[7m不在位\x1b[0m\n');
    buffer.add('<Huawei>');
  }

  testWidgets('主窗口 —— 浅色', (tester) async {
    await loadTestFonts();
    useGoldenSurface(tester);
    await pumpForGolden(
      tester,
      root: root,
      brightness: Brightness.light,
      devices: devices,
      child: const MainWindow(),
    );
    seedOutput(tester, 'd1');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();

    await expectLater(
      find.byType(MainWindow),
      matchesGoldenFile('golden/main_window_light.png'),
    );
  });

  testWidgets('主窗口 —— 深色', (tester) async {
    await loadTestFonts();
    useGoldenSurface(tester);
    await pumpForGolden(
      tester,
      root: root,
      brightness: Brightness.dark,
      settings: const AppSettings(theme: AppTheme.dark),
      devices: devices,
      child: const MainWindow(),
    );
    seedOutput(tester, 'd1');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();

    await expectLater(
      find.byType(MainWindow),
      matchesGoldenFile('golden/main_window_dark.png'),
    );
  });

  testWidgets('面板 —— 设备列表 / 编辑区 / 输出区', (tester) async {
    await loadTestFonts();
    useGoldenSurface(tester, size: const Size(360, 520));

    await pumpForGolden(
      tester,
      root: root,
      brightness: Brightness.light,
      devices: devices,
      child: const Scaffold(body: DeviceListPanel()),
    );
    await expectLater(
      find.byType(DeviceListPanel),
      matchesGoldenFile('golden/device_list_panel.png'),
    );

    await pumpForGolden(
      tester,
      root: root,
      brightness: Brightness.light,
      devices: devices,
      child: const Scaffold(body: EditorPanel(deviceId: 'd1')),
    );
    await tester.enterText(
      find.byType(TextField),
      'sys\ninterface GE0/0/1\n description 上行链路\ndisplay version\nquit',
    );
    await tester.pump();
    await expectLater(
      find.byType(EditorPanel),
      matchesGoldenFile('golden/editor_panel.png'),
    );

    await pumpForGolden(
      tester,
      root: root,
      brightness: Brightness.light,
      devices: devices,
      child: const Scaffold(body: OutputPanel(deviceId: 'd1')),
    );
    seedOutput(tester, 'd1');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump();
    await expectLater(
      find.byType(OutputPanel),
      matchesGoldenFile('golden/output_panel.png'),
    );
  });
}
```

**`seedOutput` 用 `find.byType(MainWindow)` 取容器** —— 面板那一条里没有
`MainWindow`，所以面板那部分要另取（用 `find.byType(OutputPanel)`）。执行者按实际
结构取，**只要拿到同一个容器即可**；取不到就换一个能找到的 widget 类型。

- [ ] **Step 4: 生成 PNG**

```bash
WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart --update-goldens
```
Expected: 3 条通过，`test/ui/golden/` 下出现 5 个 PNG。

- [ ] **Step 5: 亲眼看一遍**

```bash
ls -la test/ui/golden/
```

用 Read 工具逐个打开那 5 张图，确认：
- 中文是**真字**，不是一排方框；
- 没有右上角的 debug 红斜带；
- 输出区那几张里 `Info:` 是绿的、`Error:` 是红的、`不在位` 是反显的。

**任何一条不符就先修，再提交。** 这一步不能跳 —— golden 的价值全在"人能看到"。

- [ ] **Step 6: 确认默认跑仍然是绿的**

```bash
flutter test test/ui/main_window_golden_test.dart
```
Expected: `+0 ~3: All tests skipped` 之类 —— **跳过，不是失败**。

- [ ] **Step 7: 提交**

```bash
git add test/ui/golden_harness.dart test/ui/main_window_golden_test.dart test/ui/golden/ test/ui/ui_harness.dart
git commit -m "$(cat <<'EOF'
test(ui): golden 截图（主窗口浅色/深色 + 三个面板）

用户看不到界面 —— 这台机器 DISPLAY 是空的、Xvfb 没装，GUI 起不来。golden
是唯一能让用户看到"界面长什么样"的东西。

默认不跑（WCT_GOLDEN=1 开启）：golden 的比对结果取决于字体文件与渲染后端，
换机器/换字体版本/换 Flutter 都会变，而那不是回归。默认跑的下场是 flutter
test 在别人机器上变红，然后所有人学会忽略红。

夹具里有三条实测结论必须照做：FontLoader 能加载 .ttc（中文真渲染）、不指定
fontFamily 的文字是豆腐块、MaterialApp 默认带 debug 红斜带。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: 收尾验收

**Files:** 无（只跑命令、只记录）。

- [ ] **Step 1: §9.2 六条界面行为测试逐条对账**

| §9.2 条目 | 落在哪 | 用例名 |
| --- | --- | --- |
| 发送范围 | Task 4 / Task 7 | `发送选中范围覆盖到的行`（+ `send_range_test.dart` 14 条纯逻辑） |
| 设备切换 | Task 9 | `切换设备会把编辑区与输出区都换过去`、`切换设备时草稿跟着换` |
| 后台队列 | Task 7 | `队列执行中显示进度，发送按钮转为停止` |
| 设备按钮状态 | Task 8 | `列出全部设备，状态点是"未连接"`、`连上之后状态点变绿` |
| 输出自动滚动 | Task 6 | `内容变长时跟到底部`、`用户滚上去之后不再被拽回底部` |
| 清屏 | Task 6 | `清屏只清显示内容，日志那一路分毫不动` |

**逐条把这个表里的用例名在测试输出里找到**。找不到的写进报告 —— 表格是承诺，
不是描述。

- [ ] **Step 2: 全仓测试**

Run: `flutter test`
Expected: 全绿（5a 的 440 条 + 本计划的约 45 条）。**没有 skipped 之外的意外。**

- [ ] **Step 3: 静态分析**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 4: 确认 5a 的完成标准没被打破**

```bash
grep -rn "package:flutter" lib/data lib/connection lib/command lib/render lib/models
```
Expected: **无输出**（NFR-M-01：那五层是纯 Dart）。

- [ ] **Step 5: 提交验收记录**

把 Step 1 的对账表（含实际跑出的条数）写进
`docs/superpowers/plans/2026-09-25-ui-main-window.md` 的末尾，然后：

```bash
git add docs/superpowers/plans/2026-09-25-ui-main-window.md
git commit -m "$(cat <<'EOF'
docs(plans): 5b-1 收尾验收记录

§9.2 六条界面行为测试逐条对账到具体用例名，全仓测试与分析器的实际结果。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## 未决项（留给 5b-2 与以后）

1. **FR-E-08 的逃生口不成立。** 原文说"确需发送空行时，在行内输入一个空格"，
   而 `CommandDispatcher.enqueue` 会 `trim()` 后丢弃空串（`:135-138`），`' '`
   变成 `''` 就被丢了。`test/command/command_dispatcher_test.dart:32` 那条用例
   正好钉着这个行为。**5b-1 与它保持一致（也丢）**，所以用户当前**发不出空行**。
   修它要动已合并的命令层语义（改 `enqueue` 的过滤规则，或加一个"原样发送"的
   参数），是一件独立的事。
2. **Ctrl+N / 工具栏"添加设备"是占位。** 快捷键接线是真的，落点给的是
   `SnackBar('设备编辑对话框将在 5b-2 提供')`。5b-2 用真对话框替换。
3. **设备列表没有"编辑"入口。** 与上一条同源：设备编辑对话框属 5b-2。
4. **NFR-F-03（200 行/秒交互不卡顿）没有被测。** `RefreshThrottle` 把重绘压到
   约 16 次/秒（有 `fakeAsync` 用例钉着），但"一次重绘 5000 行 `TextSpan` 要多久"
   **没量过**。这是本计划最大的未验证假设。
5. **`AppSettings.deviceListWidth` 是新字段。** 旧 `settings.json` 里没有它，
   `fromJson` 的默认值兜住（240）；但**回写之后旧版本读不了**，没有版本协商。
   与既有的 `editorSplitRatio` 等字段处境相同，不是新问题。
6. **5a 的两笔验证欠账仍然开着**：① Tasks 1–6 的 diff 没有被独立复读过；
   ② 用例 `删设备：一并删掉草稿，日志不动（FR-D-06）` 实际没断言日志 —— 按用户
   2026-09-25 的日志决定，这一笔**已失效（moot）**。
7. **未决项 1–13**（5a 计划末尾）全部仍然开着，5b-1 一条都没碰。其中与界面直接
   相关的是第 3 条：`onUnknownHostKey` 为 null 时**失败关闭**，而 FR-C-11 要求
   首次连接弹指纹确认 —— **那个对话框属 5b-2**，所以本计划交付的版本在遇到未知
   主机密钥时**连不上**（安全的一侧，但不是完整功能）。
8. **`ui_harness.pumpUi` 里 `MaterialApp` 的 `Scaffold` 是共享的。** 面板 golden
   用的是 `pumpForGolden`（不套 Scaffold），两份夹具长得像但用途不同 —— 若哪天
   要加第三个夹具，先想想是不是该合并。

---

## 自检记录

**Spec 覆盖**（§8.5 的文件布局 / §9.2 的六条 / §4.8 的四个快捷键）：

| 项 | 归属 |
| --- | --- |
| `lib/ui/main_window.dart` | Task 9 |
| `lib/ui/panels/`（设备列表 / 命令编辑 / 输出） | Task 8 / 7 / 6 |
| `lib/ui/dialogs/`（设备编辑 / 设置 / 确认） | **5b-2** —— 5b-1 只有删除的内联确认对话框 |
| `lib/ui/widgets/`（状态点 / 分隔条） | Task 8 / 9（另有 ANSI 映射、节流、发送范围、自动滚动、行高亮） |
| Ctrl+Enter / Ctrl+L / Esc | Task 9 |
| Ctrl+N | Task 9（**占位**） |
| FR-S 命令库、FR-E-15/16 导入、FR-E-17 同步 | **5b-2** |

**占位扫描**：本计划里没有 TBD / "稍后补" / "类似 Task N"。唯一有意留的占位是
Ctrl+N 的 SnackBar，已在 Task 9 与未决项第 2 条两处写明。

**类型一致性**：`linesToSend` / `commandsToSend`（Task 4）与 Task 7 的调用一致；
`OutputPanelState.clearOutput` / `EditorPanelState.send`（Task 9 Step 2 的改名）
与 Task 9 的快捷键一致；`RefreshThrottle(source:, interval:)`、`AutoScroll(controller:, slack:)`、
`DraftAutosave({save, debounce, onError})`、`SentLineController.sentLines` 在定义处
与使用处逐一核对过。

**一处已知的不一致，有意保留**：Task 1 里 `OutputBuffer` 的类文档说"节流是订阅方
的事，见 `lib/ui/widgets/refresh_throttle.dart`"，而那个文件在 Task 2 才建。**先有
注释后有文件是有意的** —— Task 1 必须先跑完（`OutputBuffer` 得先会通知），Task 2
才有东西可节流。Task 1 单独提交时那个引用暂时指不到东西，Task 2 提交后成立。
