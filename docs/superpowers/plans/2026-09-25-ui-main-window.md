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

**为什么它是纯函数**：`AnsiStyle` / `AnsiColor` 是 `lib/render/` 的产物（纯 Dart，NFR-M-01），把它们映射成 Flutter 的 `Color` 与 `TextSpan` 是**纯计算**，不需要渲染任何东西就能验。

**颜色换算一律走 `AnsiColor.rgb`，本文件不做任何换算。** 那个 getter 是**公开的**（在 `lib/render/ansi_parser.dart` 的 `sealed class AnsiColor` 上），文档明写「换算放在这一层，**不留给调用方**」—— 16 色表、256 色的 6×6×6 立方与 24 级灰阶都已经在那里实现、也已经在那里被测（`test/render/ansi_parser_test.dart:173-189` 逐条钉着 `AnsiBasic(1)` / `Ansi256(196)` / `Ansi256(240)` / `AnsiRgb` 的值）。

**所以本文件一行颜色数学都不该有。** 我最初写这一节时复制了一份 16 色表并重写了立方/灰阶公式，理由是"那份 `_basicRgb` 是库私有的"——**那个理由是错的**：私有的是那张表，公开的是 `rgb` getter。复制表的代价不是多写二十行，而是**制造第二个真相**：我抄的那份在 4 号色上就抄错了（写成 `0xCD` 即 205，真实是 `238`），而两处的差异不会有任何用例去发现。

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
  group('颜色：一律委托给 AnsiColor.rgb', () {
    test('没有颜色时给 null（调用方据此用主题默认色，而不是硬编码黑白）', () {
      expect(ansiColorOf(null), isNull);
    });

    test('16 色走 rgb getter —— 用 4 号色钉住"没有第二份表"', () {
      // **4 号色是这一节存在的理由。** 我最初那版在这里自己维护了一份 16 色表，
      // 而它把 4 号色抄成了 205（真实是 238）。下面第一行断言的是 render 层的
      // 事实，第二行断言的是本文件确实**委托**给了它 —— 一旦有人再抄一份表，
      // 露馅的第一个就是这一格。
      expect(const AnsiBasic(4).rgb, (0, 0, 238), reason: '前提：render 层的值');
      expect(ansiColorOf(const AnsiBasic(4)), const Color(0xFF0000EE));
      expect(ansiColorOf(const AnsiBasic(1)), const Color(0xFFCD0000));
      expect(ansiColorOf(const AnsiBasic(15)), const Color(0xFFFFFFFF));
    });

    test('256 色与真彩色同样走 rgb', () {
      expect(ansiColorOf(const Ansi256(196)), const Color(0xFFFF0000));
      expect(ansiColorOf(const Ansi256(240)), const Color(0xFF585858));
      expect(ansiColorOf(const AnsiRgb(0x12, 0x34, 0x56)), const Color(0xFF123456));
    });

    test('256 个索引逐个走一遍都不抛（把 rgb 的断言暴露出来）', () {
      for (var i = 0; i < 256; i++) {
        expect(ansiColorOf(Ansi256(i)), isNotNull);
      }
    });
  });

  group('样式映射', () {
    test('前/背景色直接落到 TextStyle', () {
      final span = ansiSpanOf(
        const AnsiSpan('x', AnsiStyle(foreground: AnsiBasic(1), background: AnsiBasic(4))),
      );
      expect(span.style!.color, const Color(0xFFCD0000));
      expect(span.style!.backgroundColor, const Color(0xFF0000EE),
          reason: '4 号色的真实值 —— 抄错表的那一版会在这里红');
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

/// [AnsiColor] → Flutter 的 [Color]；`null` 给 `null`。
///
/// **`null` 不是"黑色"，是"没有指定"**——调用方据此用主题的前景色/背景色，
/// 这样深色主题下不带颜色的输出才是可读的。硬编码成黑白会让深色主题下的
/// 普通输出变成黑底黑字。
///
/// **换算本身一行都不在这里。** [AnsiColor.rgb] 是公开的，而且 `render/` 层的
/// 文档明写「换算放在这一层，不留给调用方」—— 16 色表、256 色的 6×6×6 立方与
/// 24 级灰阶都已经在那里实现、也已在那里被测。这里只是把那个三元组包成
/// Flutter 的 [Color]。
///
/// **别在这里加表或公式。** 那会制造第二个真相，而两处的差异不会有任何用例
/// 去发现 —— 本文件的第一版就是这样，把 4 号色抄成了 205（真实是 238）。
Color? ansiColorOf(AnsiColor? color) {
  if (color == null) return null;
  final (r, g, b) = color.rgb;
  return Color.fromARGB(255, r, g, b);
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
  // **总是返回带 `children` 的节点，空的时候也不返回 `const TextSpan()`。**
  //
  // `TextSpan.children` 的类型是 `List<InlineSpan>?`，构造器直接存参、不做
  // "空表归一成 null" 的转换 —— 所以 `const TextSpan().children` 是 **null**，
  // 而不是空表。于是"空输入给得出一个空的 children"那条断言会在 `isEmpty` 上
  // 抛 `NoSuchMethodError`（该匹配器直接对值调 `.isEmpty`，不接受 null）。
  //
  // 两种写法渲染结果没有区别，但只有这一种能让那条断言成立。这不是迁就断言：
  // 那条断言要钉的是"空输入不吐出任何子节点"，而 `const TextSpan()` 恰好让它
  // 退化成一个匹配器内部的空指针错误 —— 断言表达不出它要说的话。
  return TextSpan(children: children);
}
```

- [ ] **Step 4: 跑测试确认绿**

Run: `flutter test test/ui/ansi_text_test.dart`
Expected: 全绿。

**注意"空缓冲"那条**：`ansiLinesToTextSpan([<AnsiSpan>[]])` 的输入长度是 1（`OutputBuffer` 的 `_lines` 永远至少有一项），循环进去 0 个片段、也不加 `\n`，所以 `children` 是空的 —— 断言 `root.children` 为空成立。

**它成立的前提是 Step 3 里那句"总是 `return TextSpan(children: children)`"。** 计划的前一版在这里写的是 `if (children.isEmpty) return const TextSpan();`，那条断言对它**恒红**：`const TextSpan().children` 是 `null`（不是空表），`isEmpty` 会在 `null` 上抛 `NoSuchMethodError`。实测过，没有例外 —— **不存在**能让 `TextSpan.children` 在空输入时成为非 null 空表、同时又走 `const TextSpan()` 分支的写法。所以错在实现，不在断言。若实现里把"空 children"改成"给个空串"，那条会红，**那时才**是断言该讨论的时候，不要默认去改它。

**这一节里没有 16 色表、没有立方公式、没有灰阶公式，这是对的。** 如果你觉得"总得有个地方把 `AnsiColor` 变成 `Color`"，那就是 `ansiColorOf` 那个三行函数，而值来自 `AnsiColor.rgb`。计划的前一版在这里放了一份复制的表和一套重写的公式，被推翻了 —— 理由与修正见上面的说明。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/widgets/ansi_text.dart test/ui/ansi_text_test.dart
git commit -m "$(cat <<'EOF'
feat(ui): ANSI 到 Flutter 的颜色与 TextSpan 映射

颜色换算一行都不在本文件：AnsiColor.rgb 是公开的，render/ 层的文档明写"换算
放在这一层，不留给调用方"，16 色表与 256 色的立方/灰阶都已经在那边实现并测过。

计划初稿在这里复制了一份 16 色表，理由是"那份 _basicRgb 是库私有的" —— 理由
是错的（私有的是表，公开的是 getter），代价是制造第二个真相：抄的那份在 4 号
色上就抄错了（205 vs 真实 238），而差异不会有用例发现。用例里用 4 号色钉住
"没有第二份表"。

无颜色的字段一律留 null，让主题决定 —— 硬编码黑白会让深色主题下的普通输出
变成黑底黑字。

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

  // 每一行的起始字符偏移，长度 lines.length + 1。最后一项**恒为文本总长 + 1**
  // （最后一行并不真的有换行符，这一项却按有算了），而 `lineOf` 的搜索上界是
  // `lines.length - 1`，所以**它从不被读到**。留着只是让 `starts` 对每一行的
  // 起点都有定义 —— 别把它当成"文本总长"用。
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

- [ ] **Step 4: 跑测试确认绿**

Run: `flutter test test/ui/send_range_test.dart`
Expected: 全绿（**17 条** —— Step 1 那个块里有 17 个 `test(`、5 个 `group(`；此处早先写的"14 条"是残留，实测修正）。

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

      // 防抖定时器**应当**被取消。但下面这一条断言**钉不住"取消"本身** ——
      // 即便那个定时器漏掉了，它到点时 `_pending` 已被 `flush` 清空，`_write`
      // 会当场早退，写不出第二次。我构造不出让漏取消咬人的用例（要 `_pending`
      // 非空才有效，而 `schedule` 又会先取消旧定时器），所以这里只把"退出后不
      // 再多写一次"当作依据，**不声称它验了取消**。
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

  /// 上一次**交给 [save]** 的内容（**不是"最后成功落盘的"** —— 见 [_write]）。
  /// 用来跳过无谓的重复写 —— 切设备会重建编辑区、`setState` 会重跑
  /// `initState` 之外的路径，那些都不该产生磁盘写。
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
    // **先记下再写**，而不是等 `save` 成功之后再记。本类不认识存储层，也拿不到
    // "写成功了"这个事实 —— `save(text)` 是异步的，这里并不 await 它。所以
    // `_lastSaved` 的准确含义是"最后一次**交给** `save` 的内容"，不是"最后一次
    // **成功落盘**的内容"。失败了由 [onError] 报给调用方去提示，本类**不重试**。
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
              builder: (_, n, _) => ListView.builder(
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

**这一步的红是干净的**：`test/ui/auto_scroll_test.dart` 只 import 三处（`material` / `flutter_test` / `auto_scroll.dart`），**没有** `import 'ui_harness.dart';`。Dart 的 import 不传递、编译单元也不共享，所以共享夹具里的问题**不会**夹进这条红里 —— 夹具第一次被编进来是 Step 6（`output_panel_test.dart` 才 import 它），而它的 import 块到 Step 5 才写（`misc.dart` 那一行是承重的，理由见 Step 5）。

**`builder: (_, n, _)` 里两个下划线不是笔误**：Dart 3.7+ 的 `_` 是**非绑定通配符**，可以重复；写成 `__` 会被 `flutter_lints` 的 `unnecessary_underscores` 记一条 info，而"`dart analyze lib/ test/` 干净"是验收项。

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
// **`Override` 不在 `flutter_riverpod.dart` 里。** riverpod 3.x 把它移到了次要
// 入口：主入口的 show 列表没有它，`misc.dart` 才有（实测 flutter_riverpod
// 3.4.3）。少这一行，本文件红在 `non_type_as_type_argument`，而它连带把
// 所有 `import 'ui_harness.dart';` 的测试文件一起拖红。
import 'package:flutter_riverpod/misc.dart';
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

**`import 'package:flutter_riverpod/misc.dart';` 那一行是承重的，别"清理"掉。** riverpod 3.x 把 `Override` 移出了主入口 —— 实测 3.4.3 的 `flutter_riverpod.dart` 是个 `show` 列表，**不含 `Override`**；`misc.dart` 才导出它。少那一行，本文件红在 `non_type_as_type_argument`（`The name 'Override' isn't a type`），而且因为是共享夹具，它会**把每一个 `import 'ui_harness.dart';` 的测试文件一起拖红**。

**`extra` 目前零调用者**（Task 6/7/8/9 的 `pumpUi` 调用都只传具名参数），留着是给后续面板测试当逃生口的 —— 那时才需要 `extra:`，但要 override 的东西恰好都在主入口里，所以这个参数能一直用到 5b-2。

- [ ] **Step 6: 写输出面板的失败测试**

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/state/output_buffer.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/panels/output_panel.dart';

import '../fixtures/fake_session.dart';
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

**`find.textContaining` 与 `TextSpan` 树**：`SelectableText.rich` 的 `find.textContaining` 会匹配到整棵树的纯文本，所以这些断言是有效的。**实测依据**：`SelectableText.rich` 内部建的是 `_TextSpanEditingController`，其构造器 `super(text: textSpan.toPlainText(...))`，而 `_MatchTextFinder` 对 `EditableText` 取的就是 `widget.controller.text` —— 两边接得上。若某条查不到，**先确认面板确实用了 `SelectableText.rich` 而不是 `RichText`** —— `RichText` 默认不参与 `find.text*`（要 `findRichText: true`）。

**那两条 import 不是多余的**（`output_buffer.dart` 与 `../fixtures/fake_session.dart`）：`OutputBuffer` 是 `bufferOf` 的返回类型，`fakeProfile` 来自夹具文件 —— 而 **Dart 的 import 不传递**，`ui_harness.dart` 里 import 了它们不等于本文件能用它们的名字。

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
                // 而不是 ScrollNotification**：前者只在**滚动方向变化**时报
                // （`updateUserScrollDirection`），也就是拖拽、以及 goIdle /
                // goBallistic 把方向改回 idle 时。
                //
                // **这只是稳健性偏好，不是承重。** 程序化跟底那一跳确实**可能**
                // 报（`jumpTo` → `goIdle()` → `beginActivity` 见到非滚动活动就
                // 把方向置回 idle，若此前是 forward/reverse 就会报一次），但那一
                // 刻 pixels 已经在底部、`extentAfter` ≈ 0，`onUserScroll` 判出来
                // 的结论相同 —— 见 [AutoScroll.onUserScroll] 的文档。
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
    //
    // **下划线不在根节点上。** `TextEditingController.buildTextSpan`（实测
    // SDK 源码）返回的是 `TextSpan(style: style, children: [前, 组字段, 后])`，
    // 根节点的 style 就是传进来的 `style`（这里是 `TextStyle(fontSize: 14)`，
    // 没有 decoration），**带下划线的是中间那个子节点**。所以断言必须落在
    // 那个子节点上 —— 写成 `expect(span.style?.decoration, ...)` 会**恒红**。
    expect(span.toPlainText(), 'zhong');
    final composing = span.children!
        .cast<TextSpan>()
        .firstWhere((s) => s.text == 'zhong');
    expect(composing.style?.decoration, TextDecoration.underline,
        reason: '组字下划线必须还在，否则中文输入法的候选提示会没有锚点');
  });

  testWidgets('标记按行号落在对应的行上', (tester) async {
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

**这条用例原来的名字是"行数变了之后旧的行号标记不会串到别的行上"**，但它从头到尾没有改过 `text` —— 名字声称的场景没被跑到。改成现在这个名字（与它真正断言的事一致）。**"行号会变旧"这件事本身是真的**：`sentLines` 只在 `_send()` 里 `clear()+addAll()`，用户手工增删行时它不动，于是被标暗的可能不再是当初发出去的那一行。这是 FR-E-10 的语义取舍（"已发送的行"按行号记），不是缺陷，记在计划末尾的未决项里。

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
import 'package:flutter_test/flutter_test.dart';
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

  /// 让命令队列往前走 [count] 步：每步吐一个提示符，再推过 `promptDebounce`
  /// （生产默认 120ms，见 `CommandDispatcher` 的构造默认值；这里给 300ms 留余量）。
  ///
  /// **`FakeSession` 不会自己回提示符** —— 它的 `output` 是空的广播流，只有
  /// `emit` 才吐数据。而队列是**一条一条发的**：第一条出去之后要等提示符才轮到
  /// 第二条。少了这一步，队列就停在第一条，那条 10 秒超时定时器会一直挂着，
  /// 用例在拆卸期红在 `A Timer is still pending even after the widget tree was
  /// disposed`，**而 `written` / `sentLines` 的断言其实已经过了** —— 别被那个
  /// 假象骗了，以为断言写错了。（Task 9 里推队列用的也是这个手法。）
  Future<void> drainQueue(
    WidgetTester tester,
    FakeSessionFactory factory,
    int count,
  ) async {
    for (var i = 0; i < count; i++) {
      factory.sessions.single.emit('Switch# ');
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

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
    await tester.pump();
    // 队列里就这一条，吐一个提示符它就结束了。
    await drainQueue(tester, factory, 1);

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
    // **`enterText` 会把光标收到文本末尾**（`TextSelection.collapsed(offset: 5)`），
    // 而"没有选中就只发光标那一行" —— 那样队列里只有 `c` 一条，"队列执行中"
    // 就名不副实了。全选，让三条都进队列。
    final editor = tester.widget<TextField>(find.byType(TextField)).controller!;
    editor.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    expect(find.text('执行中 1/3'), findsOneWidget,
        reason: 'FR-E-14：队列执行中要有 执行中 n/m，且 m 是队列长度');
    expect(find.byTooltip('中止'), findsOneWidget);

    // 三条命令，三个提示符，队列跑完。
    await drainQueue(tester, factory, 3);
    expect(find.byTooltip('发送'), findsOneWidget, reason: '队列空了应当能再发');
  });

  testWidgets('未连接时发送按钮不可用（§9.2 第 4 条的一半）', (tester) async {
    await pumpEditor(tester);
    // **不能用 `tester.widget<IconButton>(find.byTooltip('发送'))`。**
    // `find.byTooltip` 匹配的是 `Tooltip` / `RawTooltip` 组件本身（实测
    // SDK 源码），不是那个 `IconButton` —— 取 widget 会红在类型转换上。
    // 要按图标定位按钮：`IconButton` 是 `Icon` 的祖先。
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send),
    );
    expect(button.onPressed, isNull, reason: '没有会话时发出去的命令会掉进空处');
  });

  testWidgets('已发送的行被标出来（FR-E-10）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a\nb');
    await tester.pump();
    // 同上：不给选中就只发光标那一行，而本用例要的是两行都被标出来。
    final editor = tester.widget<TextField>(find.byType(TextField)).controller!;
    editor.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await drainQueue(tester, factory, 2);

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

**本步的三段片段是同一个文件的三截**（import + 状态类 / `build` / 行号栏与工具栏），
按顺序拼接：**片段之间留一个空行**，文件末尾是单个 `}\n`（最后一段的类收尾 `}`
就是文件的最后一行）。实测：片段之间不留空行、或末尾多一个空行，都会让"与计划
逐字节一致"这条自查对不上（两种都仍能编译，但那条自查就没意义了）。

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../command/command_dispatcher.dart';
// **`DeviceConnectionState` 只能从这里来。** 它在 `connection_manager.dart` 里
// 定义，而 Dart 的 import **不传递** —— `providers.dart` 虽然 import 了它，
// 却不会把它再导出给本文件。
import '../../connection/connection_manager.dart';
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
- Modify: `lib/state/providers.dart`（加 `selectedDeviceProvider`；并让
  `SessionNotifier.build()` 容忍已删除的设备）
- Modify: `test/ui/ui_harness.dart`（加 `settleDisk`）
- Test: `test/ui/device_list_panel_test.dart`

**本任务不含"编辑设备"入口。** 设备编辑对话框属 5b-2，所以右键菜单只有 连接 /
断开 / 删除三项；删除带一个内联的确认对话框（不需要设备编辑那一套表单，所以
留在 5b-1 是合适的）。

- [ ] **Step 1: 写失败测试**

```dart
import 'dart:io';

import 'package:flutter/gestures.dart';
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
    // **这里不能用 `pumpAndSettle()`**：删除要写盘，而假时钟里真盘 I/O 走不完
    // （理由见 `settleDisk` 的文档）—— 表现是"点了确认，设备还在"。
    await settleDisk(tester);

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
    // **落点必须越过第二项的底边。** `to.dy + 20` 落在框架的死区里（`_insertIndex`
    // 会等于被拖项的原地下标，`onReorderItem` 一次都不调）—— 三种落点的实测见 Step 6。
    await gesture.moveTo(Offset(from.dx, to.dy + 90));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    // 排序也要写盘，理由同上面删除那条。
    await settleDisk(tester);

    expect(container.read(devicesProvider).map((d) => d.id), ['d2', 'd1']);
  });
}
```

**`kSecondaryButton` 来自 `package:flutter/gestures.dart`** —— 实测这个 SDK 版本里
`material.dart` 与 `widgets.dart` **都没有** re-export 它（在 `/home/lwliu/flutter/packages/flutter/lib/`
的两个入口里 grep `package:flutter/gestures.dart` 都空手而归，定义在
`src/gestures/events.dart`），所以上面那行 import 是**承重的**，别当无用 import 删掉。

**测试里 `tester.tap(find.byTooltip('连接 核心交换机'))` 的 tooltip 名字是约定**：每台设备的按钮 tooltip 必须带上设备名，否则两台设备的按钮在测试里无法区分 —— 而"区分彼此"正是 §9.2 第 4 条要验的东西。

- [ ] **Step 2: 跑测试确认红**

Run: `flutter test test/ui/device_list_panel_test.dart`
Expected: **编译失败**（`Target of URI doesn't exist: .../device_list_panel.dart`）。

**此刻 `selectedDeviceProvider` 也还不存在**（它在 Step 4 才加），所以这条红里
还会带一条 `Undefined name 'selectedDeviceProvider'`；测试里用到的 `settleDisk`
要到 Step 5 才加进 `ui_harness.dart`，同样会带一条 —— 三条都对，别以为是自己写错了。

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

- [ ] **Step 4: 加 `selectedDeviceProvider`、修 `SessionNotifier.build()`，并实现设备列表面板**

**这个 provider 原本写在 Task 9 里，现在挪到本任务** —— 第一个用到它的是设备列表，
而任务是**按顺序执行**的：留在 Task 9，本任务就先编译不过（Task 9 的那一步已改成
只做核对）。加在 `lib/state/providers.dart` 的**末尾**：

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

**接着修同一个文件里的 `SessionNotifier.build()` —— 这是本任务实测出来的一处真机崩溃，
不是测试的毛病。** 设备列表里每一行的 `_DeviceTile` 都
`ref.watch(sessionProvider(device.id))`，而 `DevicesNotifier.remove()` 会
`ref.invalidate(sessionProvider(id))`；被删的那一行**此刻还在树上**（widget 要到下一帧
才拆），Riverpod 于是在同一帧的 `_performRefresh` 里重建它 —— `build()` 里那句
`firstWhere` 找不到设备，抛 `Bad state: No element`。实测：**删掉一台设备，界面直接打红。**

把 `_controller` 改成可空，并在 `build()` 里早返回一个"未连接"的空状态。先是字段与
`build()` 开头这两处：

```dart
  /// 设备已被删除时为 null（见 `build()`）。此时本 provider 只剩一个"未连接"的
  /// 空状态，下面四个方法都退化成空操作 —— 已经没有界面会调它们，但也不能抛。
  SessionController? _controller;

  @override
  SessionStatus build() {
    final settings = ref.read(settingsProvider);
    final devices = ref.read(devicesProvider);
    final index = devices.indexWhere((d) => d.id == deviceId);
    if (index < 0) {
      // **设备已经不在了（FR-D-04 删除），这里不能抛。**
      //
      // `DevicesNotifier.remove()` 会 `invalidate` 本 provider，而设备列表里那一行
      // 此刻还在 `watch` 它（widget 要到下一帧才拆），于是 Riverpod 当场重建 ——
      // 原来那句 `firstWhere` 找不到设备，抛 `Bad state: No element`，
      // **删一台设备就把界面打红**（实测）。设备都没了，会话状态当然是"未连接"。
      _controller = null;
      return const SessionStatus();
    }
    final profile = devices[index];
```

**具体是删掉下面这几行、换成上面那一段**（其余不动）：

```dart
  late final SessionController _controller;

  @override
  SessionStatus build() {
    final settings = ref.read(settingsProvider);
    final profile = ref
        .read(devicesProvider)
        .firstWhere((d) => d.id == deviceId);
```

**还有 `build()` 里造 controller 的那一段** —— 可空字段不会被类型提升，所以要先落进
一个局部变量、再用它：

```dart
    final controller = SessionController(
      profile: profile,
      factory: ref.read(sessionFactoryProvider),
      buffer: ref.read(outputBufferProvider(deviceId)),
      // FR-L-02：设置里给了就用设置里的，否则用应用数据目录下的 logs/
      // （`logsDirPath` 是 `Provider<String>`，由 `main()` 覆盖）。
      logsDir: Directory(settings.logDir ?? ref.read(logsDirPath)),
      logEnabled: settings.logEnabled,
      onLogError: (error) => ref
          .read(issuesProvider.notifier)
          .add(LoadIssue(LoadIssueKind.corruptFile, '日志写入失败：$error')),
    );
    _controller = controller;
    // controller 的状态变化（含从 `ConnectionManager` 来的那些）推给 Riverpod。
    controller.onStatus = (status) => state = status;
    ref.onDispose(controller.dispose);
    return controller.status;
```

（原来是 `_controller = SessionController(` 打头，末尾三行写的是
`_controller.onStatus` / `ref.onDispose(_controller.dispose)` / `return _controller.status`。）

再是类末尾那四个方法 —— 都要容忍 `_controller` 为空：

```dart
  Future<void> connect() async {
    await _controller?.connect();
  }

  Future<void> disconnect() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.disconnect();
    state = controller.status;
  }

  /// 把命令排进该设备的队列（FR-E-01）。队列在后台继续跑，切设备不影响它。
  void enqueue(List<String> commands) => _controller?.enqueue(commands);

  /// 中止队列（FR-E-13 / Esc）。
  void abort() => _controller?.abort();
```

然后是面板本身：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// **`DeviceConnectionState` 只能从这里来**：Dart 的 import **不传递**，
// `providers.dart` 虽然 import 了它，却不会转手导出给本文件。
import '../../connection/connection_manager.dart';
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
      // **`onReorderItem` 的 `newIndex` 已经是"移除之后该插到哪个下标"** ——
      // 框架替你调好了（SDK 文档原话："remove the manual adjustment of newIndex"）。
      // 旧的 `onReorder` 才要求自己 `if (newIndex > oldIndex) newIndex -= 1;`，
      // 而它在这版 SDK（3.44.4）里**已废弃**（"after v3.41.0-0.0.pre"），
      // `deprecated_member_use` 又只是条 info —— 正好会打掉"`dart analyze` 干净"
      // 这条验收项，所以必须换。**换了之后别把那个 `-= 1` 一起搬过来**：
      // 再减一次的表现是"往下拖一格没反应、拖两格只动一格"。
      onReorderItem: (oldIndex, newIndex) {
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
        // **标题不能也叫"确认删除"。** 用例既断言 `find.textContaining('确认删除')`
        // 只有一个、又用 `find.text('确认删除')` 去点按钮：两处字符串一样的话，
        // 两者都会匹配到 2 个 widget（标题那个 Text + 按钮里的那个 Text），
        // `findsOneWidget` 与 `tap` 会双双失败。这条是实测出来的，别"顺手统一"。
        title: const Text('删除设备'),
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

- [ ] **Step 5: 给 `ui_harness.dart` 加 `settleDisk`**

**这是本任务实测出来的第二件事：在 `testWidgets` 里，真盘 I/O 不会自己走完。**

`testWidgets` 的整段测试体跑在假时钟（`FakeAsync`）里：`pump()` 只 flush 微任务队列、
**不转真实事件循环**（`AutomatedTestWidgetsFlutterBinding.pump` 里就是
`_currentFakeAsync!.flushMicrotasks()`），而 `dart:io` 的每一步都要一次真实事件循环的轮转
才会推进。`DeviceStore.save()` 内部至少是 `create(recursive: true)` + `writeAsString()`
两步，于是两条路都停在半路：

- 只 `pumpAndSettle()`：写完第一步就停住 —— 表现为"**点了确认删除，设备还在**"；
- 只 `runAsync(() => Future.delayed(...))`：转了一次真实事件循环，但假队列里排下的续体
  没人 flush —— 同样停住（实测：`save()` 之后连文件都没建出来）。

**两者交替**才走得完。在 `test/ui/ui_harness.dart` 的**末尾**加：

```dart
/// 让**真盘 I/O** 走完：转一圈真实事件循环，再 flush 一次假时钟的微任务队列，交替若干轮。
///
/// **为什么不能只用其中一个**（实测）：`pump()` 只 flush 微任务、不转真实事件循环；
/// `runAsync(delay)` 只转一次真实事件循环。而 `dart:io` 的每一步都要一次真实的轮转才
/// 推进，`DeviceStore.save()` 至少是 `create(recursive: true)` + `writeAsString()` 两步
/// —— 只做其中之一就停在半路，表现为"点了确认删除，设备还在"。
///
/// 凡是用例要观察**写盘之后**的状态（删除、拖拽排序、改设置），都用它代替
/// `pumpAndSettle()`。
Future<void> settleDisk(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pumpAndSettle();
}
```

- [ ] **Step 6: 跑测试确认绿**

Run: `flutter test test/ui/device_list_panel_test.dart`
Expected: 5 条全绿。

**拖拽那条的落点是实测出来的，别按直觉改。** `ReorderableListView` 判定插入位置用的是
**被拖那一项的矩形**（`_dragUpdateItems`：`proxyItemStart = 指针 y − 抓取点偏移`），
看它与第二项的重叠关系 —— **不是"指针过没过中线"**。两行各 56 高、抓在第一行正中
（偏移 28）时，指针 y 与结果的关系是：

| 指针 y | 结果 |
|---|---|
| 84–112（第二项**下半**） | `_insertIndex = 1`，去掉被拖项后正好等于原地 → **`onReorderItem` 一次都不调** |
| 56–84（第二项**上半**） | `_insertIndex = 2` → 真的下移一格 |
| > 140（越过第二项底边再加 28） | `_insertIndex = 2` → 真的下移一格 |

`to.dy + 20` = 104 正落在**死区**里（`to.dy` 是第二项文字的中心，= 84）。三种落点都实测过：
`to.dy - 10` ✓、`to.dy + 90` ✓、`to.dy + 20` ✗。所以计划里写的是 `to.dy + 90`。

**若还是红**：先确认 `kSecondaryButton` 的 import 在不在（`material.dart` 与 `widgets.dart`
都不 re-export `package:flutter/gestures.dart`）；再确认 `find.byIcon(Icons.drag_handle).first`
拿到的是面板自己那个把手 —— 测试平台上框架不会插第二个 `Icons.drag_handle`
（实测：2 项 → `Icons.drag_handle` 2 个、`ReorderableDragStartListener` 2 个）。

- [ ] **Step 7: 提交**

```bash
git add lib/ui/widgets/status_dot.dart lib/ui/panels/device_list_panel.dart lib/state/providers.dart test/ui/ui_harness.dart test/ui/device_list_panel_test.dart
git commit -m "$(cat <<'EOF'
feat(ui): 设备列表（状态点 / 连接断开 / 拖拽排序 / 删除）

状态点的颜色与文案由 state 一处决定，不在别处再写第二份 switch —— 两处各写
一份的下场是加了新状态之后其中一处悄悄落进 default。

ReorderableListView 用 onReorderItem 而不是已废弃的 onReorder：旧回调的 newIndex
要自己减一，新回调由框架调好，再减一次就是"往下拖一格没反应、拖两格只动一格"；
而 deprecated_member_use 只是条 info，正好会打掉"dart analyze 干净"这条验收。

删除前先挪走选中：顺序反了的话 sessionProvider(已删除的 id) 会先被建一次，
而 SessionNotifier.build() 要从设备列表 firstWhere，那个 id 已经不在了。

SessionNotifier.build() 改成容忍已删除的设备：DevicesNotifier.remove() 会 invalidate
它，而被删的那一行此刻还在 watch 它（widget 下一帧才拆），原来的 firstWhere 当场抛
Bad state: No element —— 删一台设备就把界面打红（实测）。设备都没了，会话状态就是
"未连接"，四个方法一并退化成空操作。

ui_harness 加 settleDisk：假时钟里 pump() 不转真实事件循环、runAsync 不 flush 假队列，
而 dart:io 的每一步都要一次真实轮转，save() 至少两步 —— 两者交替才走得完。删除与拖拽
这两条用例要观察写盘之后的状态，所以不能只 pumpAndSettle()。

选中状态放在状态层（selectedDeviceProvider）而不是某个 widget 的 State 里：
设备列表、编辑区、输出区与窗口级快捷键四处都要读它。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: 主窗口、分隔条与快捷键

**§9.2 的第 2 条落在本任务**（设备切换）。

**本任务要改两处已提交的代码**（`editor_panel.dart` 与 `output_panel.dart`），
都在下面 Step 2 里给全：把两个 State 类**公开**并各留一个动作方法，供窗口级快捷键
调用。同一步里还带上两处**实测出来的**小改：`didUpdateWidget` 的参数名（类一公开
就会报 info）与 `_loadDraft` 的续体回认设备（切走再切回来会丢草稿）。

**Files:**
- Modify: `lib/ui/panels/editor_panel.dart`（State 类公开 + `send()` 公开 + `didUpdateWidget` 参数名 + `_loadDraft` 续体回认设备）
- Modify: `lib/ui/panels/output_panel.dart`（State 类公开 + `clearOutput()` 公开）
- Modify: `lib/models/app_settings.dart`（加 `deviceListWidth`）
- Create: `lib/ui/widgets/splitter.dart`
- Create: `lib/ui/main_window.dart`
- Modify: `lib/app.dart`（`home` 换成 `MainWindow`）
- Test: `test/ui/main_window_test.dart`

- [ ] **Step 1: 核对 `selectedDeviceProvider` 已经在 Task 8 加过（本步不要再添加）**

它**原本写在本步，现在移到了 Task 8 的 Step 4** —— 第一个用到它的是设备列表，
而任务是按顺序执行的：留在本任务，Task 8 就先编译不过。
**这一段留着只是给你核对**：打开 `lib/state/providers.dart` 确认末尾有
`selectedDeviceProvider` 与 `SelectedDeviceNotifier` 即可。**不要重复添加**
（重复定义会红在 `already_declared`）。定义与理由见 Task 8 Step 4。

- [ ] **Step 2: 改已提交的两个面板（State 类公开 + 各留一个动作方法 + 两处实测缺陷）**

**本步一共七处改动，两个文件**，都在下面给全。第 3、4 处（`editor_panel.dart` 的后两处）
**原本不在计划里** —— 是派发前照本步的代码把整个 Task 摆出来跑的时候红的，现象分别是
`dart analyze` 多出一条 info、以及"切回 A 之后草稿是空的"。

`editor_panel.dart` 四处：

**（1）State 类公开：**

```dart
  ConsumerState<EditorPanel> createState() => EditorPanelState();
```

```dart
class EditorPanelState extends ConsumerState<EditorPanel> {
```

**（2）`_send` 公开**：`void _send()` → `void send()`，工具栏里
`onPressed: connected ? _send : null` → `onPressed: connected ? send : null`。

**（3）`didUpdateWidget` 的参数名要一起改** —— 类一公开，`old` 这个名字就开始报
`avoid_renaming_method_parameters`（info）：

```dart
  void didUpdateWidget(EditorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId == widget.deviceId) return;
```

实测：HEAD 上同名的参数**不报**（那时 State 类还是私有的），把类公开、参数名不动之后
`dart analyze lib/ test/` 输出 1 条 info，改名之后才回到 `No issues found!`。info 会打掉
本计划"analyze 干净"这条验收，所以这不是"顺手改"。

**（4）`_loadDraft` 的续体要回认设备**（真机缺陷）：方法开头加 `final deviceId =
widget.deviceId;`，`draftProvider(widget.deviceId)` 换成 `draftProvider(deviceId)`，
**两个** `if (!mounted) return;` 都改成 `if (!mounted || deviceId != widget.deviceId) return;`：

```dart
  Future<void> _loadDraft() async {
    // **续体要回认设备。** 本方法是异步的：切到 B 之后 B 那次读还没回来，
    // 用户又切回 A —— B 的续体会把**A 的**编辑区刷成 B 的草稿。实测的表现是
    // "切回 A 之后草稿是空的"（`draftProvider('d1')` 已经是 `AsyncData('sys')`，
    // 而编辑区的 text 是 `''`）。`didUpdateWidget` 只管得住换设备的那一刻，
    // 管不住换完之后回来的续体，所以这里自己比一次。
    final deviceId = widget.deviceId;
    try {
      final text = await ref.read(draftProvider(deviceId).future);
      if (!mounted || deviceId != widget.deviceId) return;
```

`output_panel.dart` 三处：

**（1）`ConsumerState<OutputPanel> createState() => OutputPanelState();`
（2）`class _OutputPanelState` → `class OutputPanelState`
（3）清屏按钮的 `onPressed` 抽成公开方法：**

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
  }) async {
    await pumpUi(
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
    // 编辑区要在 `initState` 里把草稿读出来才算就绪，而那次读是**真盘 I/O**
    // （`pumpAndSettle` 里走不完，见 `settleDisk` 的文档）。
    await settleDisk(tester);
  }

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
    await settleDisk(tester);
    await tester.tap(find.text('边界防火墙'));
    await tester.pumpAndSettle();
    expect(find.text('sys'), findsNothing, reason: 'B 设备不该看到 A 的草稿');

    await tester.tap(find.text('核心交换机').first);
    await settleDisk(tester);

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
    await settleDisk(tester);

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
读成后者。**这一点对本文件的 Esc 那条尤其要紧**：`pumpUi` 装的是 `MainWindow`
而不是 `WinCliToolApp`，所以 `connectAutoConnectDevicesAtStartup`（唯一调用点在
`app.dart` 的 `initState`）**根本不会跑** —— `autoConnect: true` 在这里是惰性的，
`sessions.single` 就是那条用例自己点出来的那一台。

**泵盘（`settleDisk`）在这里有四处是承重的**，都是实测出来的，少一处就红：

1. **`pumpWindow` 结尾那次**：编辑区在 `initState` 里读草稿，而那次读是**真盘 I/O**。
   `pumpUi` 结尾的 `pumpAndSettle()` **走不完它** —— 实测派发前那一版里
   `draftProvider('d1')` 在 `pumpAndSettle` 之后仍是 `AsyncLoading`，于是
   `_seeded` 一直是 false、`_onTextChanged` 直接早返回、防抖根本没被武装，
   表现是"写进编辑区的内容一个字都没落盘"。
2. **`enterText` 之后那次**：`DraftAutosave` 的 500ms 防抖到点才发起写，
   `pump(600ms)` 只把**定时器**烧掉，写本身仍要真盘轮转。
3. **切回来之后那次**：`draftProvider('d1')` 这时已经是 `AsyncData`，但把它灌进
   `TextEditingController` 仍要跨一次 `await`（微任务），而假时钟里的
   `pumpAndSettle` 之后**未必**已经落到界面上了。这两处用 `settleDisk` 都是一次
   到底，不必推敲。
4. **分隔条那条**：拖动松手后要写 `settings.json`（同 1、2 的理由）。

**分隔条那条为什么用 `onDragEnd` 落盘、而断言只看"变大了"**：`tester.drag(Offset(0, 60))`
实测会被 touch slop 拆成 **20 + 40 两段**（探针打印过），也就是**一次拖动两次
`onDrag`**。若按每次 `onDrag` 都写盘，两次写就**同时上路**，而
`writeFileAtomically` 是先写同目录 `.tmp` 再 rename —— 先完成的那次把 `.tmp`
挪走了，后一次的 rename 直接抛
`PathNotFoundException: Cannot rename file .../settings.json.tmp (errno = 2)`
（实测，那条用例当时就红在这里）。所以 `MainWindow` 在拖动期间只动本地值、
松手落盘一次；顺带把未决项 10 与 11 一起了掉（见那两条的说明）。

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
    this.onDragEnd,
    this.thickness = 6,
  });

  /// 分隔条的走向。**纵向**分隔条（左右分栏之间）用 [Axis.vertical]。
  final Axis axis;

  /// 拖动时回调：参数是**沿拖动方向的像素增量**。
  final void Function(double delta) onDrag;

  /// 松手时回调。**落盘要挂在这里，不要挂在 [onDrag] 上** —— 理由见
  /// `main_window.dart` 里 `_draggingWidth` 的文档。
  final VoidCallback? onDragEnd;

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
        onHorizontalDragEnd: axis == Axis.vertical
            ? (_) => onDragEnd?.call()
            : null,
        onVerticalDragEnd: axis == Axis.horizontal
            ? (_) => onDragEnd?.call()
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

**`onDragEnd` 不是可选的装饰**，它是 `MainWindow` 唯一能落盘的地方 —— 理由见
Step 3 末尾那一段与 `main_window.dart` 里 `_draggingWidth` 的文档。

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

  /// 拖动中的临时宽度／比例（null = 没在拖）。
  ///
  /// **拖动过程里不写 settings。** 每次 `onDragUpdate` 都写一趟的话：
  /// （一）那条链里有 `chmod` —— 一个**进程** —— 60Hz 的拖动就是每秒起 60 个；
  /// （二）两次写会重叠，而 `writeFileAtomically` 是先写同目录 `.tmp` 再 rename，
  /// 重叠时先完成的那次把 `.tmp` 挪走了，后一次的 rename 就红在
  /// `Cannot rename file .../settings.json.tmp (errno = 2)`。这两条都是实测的：
  /// `tester.drag(Offset(0, 60))` 一次就被 touch slop 拆成 20 + 40 两段，
  /// 于是两条写同时上路，那条测试红在 PathNotFoundException 上。
  ///
  /// 所以拖动期间只动本地状态（界面照样实时跟手），松手才落盘一次。
  double? _draggingWidth;
  double? _draggingRatio;

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
    final width = _draggingWidth ?? settings.deviceListWidth;

    return Row(
      children: [
        SizedBox(
          width: width,
          child: DeviceListPanel(),
        ),
        // 设备列表与右侧之间的分隔条改动的是列表宽度。
        Splitter(
          key: const ValueKey('splitter-v'),
          axis: Axis.vertical,
          onDrag: (delta) {
            final base = _draggingWidth ?? settings.deviceListWidth;
            setState(() => _draggingWidth = (base + delta).clamp(_minPane, 480.0));
          },
          onDragEnd: () {
            final next = _draggingWidth;
            if (next == null || next == settings.deviceListWidth) {
              setState(() => _draggingWidth = null);
              return;
            }
            _commit(settings.copyWith(deviceListWidth: next));
          },
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final total = constraints.maxHeight;
              // 拖动中的比例走本地值：设置里那份要等松手才更新。
              final ratio = _draggingRatio ?? settings.editorSplitRatio;
              final editorHeight =
                  (total * ratio).clamp(_minPane, total - _minPane);
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
                      final base = _draggingRatio ?? settings.editorSplitRatio;
                      setState(
                        () => _draggingRatio =
                            (base + delta / total).clamp(0.15, 0.85),
                      );
                    },
                    onDragEnd: () {
                      final next = _draggingRatio;
                      if (next == null || next == settings.editorSplitRatio) {
                        setState(() => _draggingRatio = null);
                        return;
                      }
                      _commit(settings.copyWith(editorSplitRatio: next));
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

  /// 松手时把拖动中的值写回设置。**成功与失败都要清掉本地值** —— 留着的话，
  /// 之后 `settings` 再怎么变界面都不跟着走了。
  Future<void> _commit(AppSettings next) async {
    try {
      // 存盘成功之后 `SettingsNotifier` 才改内存状态，所以 await 回来时
      // `settingsProvider` 已经是 `next`，清本地值不会闪回旧值。
      await ref.read(settingsProvider.notifier).update(next);
    } catch (_) {
      // 存盘失败时异常从 `update` 原样抛出来（见它的文档）。**不能静默回弹** ——
      // 用户会把"拖了但没生效"当成拖动失灵，而真正的原因是设置没写下去。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设置未能保存')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _draggingWidth = null;
          _draggingRatio = null;
        });
      }
    }
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

**`_body` 里不要有 `addDevice` 局部函数。** 5b-1 的 Ctrl+N 只给 SnackBar 提示
（见 `_addDevice`），没有第二个落点需要它；多一个没人调的函数会红在
`unused_element`（info），又打掉"analyze 干净"。

**`AppSettings` 需要一个新字段 `deviceListWidth`。** 在 `lib/models/app_settings.dart`
里按既有字段的写法加六处：构造函数的 `this.deviceListWidth = 240,`、字段声明
`final double deviceListWidth;`、`copyWith` 的形参与赋值、`fromJson` 的
`(json['deviceListWidth'] as num?)?.toDouble() ?? 240`、以及 `toJson`。**照抄
`editorSplitRatio` 那一套**（它的默认值是 0.4）。

**同时在 `test/models/app_settings_test.dart` 里补三处**，否则 Step 10 的 `git add`
里那个路径是个空动作，而这个新字段最容易在 `fromJson` 上写漏（漏了就是"每次启动
列表宽度都弹回默认"）：

```dart
      expect(s.editorSplitRatio, 0.4);
      expect(s.deviceListWidth, 240);            // 默认值那条用例里
```

```dart
        editorSplitRatio: 0.6,
        deviceListWidth: 320,                     // 往返用例的构造参数里
```

```dart
      expect(restored.editorSplitRatio, 0.6);
      expect(restored.deviceListWidth, 320);      // 往返用例的断言里
```

```dart
      expect(restored.editorSplitRatio, defaults.editorSplitRatio);
      expect(restored.deviceListWidth, defaults.deviceListWidth);   // 缺失回落那条
```


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
git add lib/ui/main_window.dart lib/ui/widgets/splitter.dart lib/ui/panels/editor_panel.dart lib/ui/panels/output_panel.dart lib/models/app_settings.dart lib/app.dart test/ui/main_window_test.dart test/models/app_settings_test.dart
git commit -m "$(cat <<'EOF'
feat(ui): 主窗口、分隔条与四个快捷键（§4.8 / §7.1）

过期选中在 MainWindow 一处挡掉：删掉设备后 selected 可能还指着它，而
sessionProvider(那个 id) 会去列表 firstWhere 并抛。挡在一处，两个面板与快捷键
都不用各自防一遍。

分隔条只上报新比例，不自己存 —— 比例的真相在 AppSettings.editorSplitRatio，
存两份必然有一份会旧。

Ctrl+N 目前只给提示（设备编辑对话框属 5b-2）。快捷键接线是真的，落点是占位，
这是知情留的。

分隔条的落盘挂在 onDragEnd 而不是每次 onDragUpdate：一次 tester.drag 实测被 touch slop
拆成 20 + 40 两段，每次都写盘就是两条原子写同时上路，而 writeFileAtomically 是先写
同目录 .tmp 再 rename —— 先完成的那条把 .tmp 挪走，后到的那条红在 PathNotFoundException。
拖动期间只动本地值（界面照旧实时跟手），松手落盘一次。顺带了掉未决项 10 与 11。

_loadDraft 的续体回认设备：切到 B 之后 B 那次读还没回来、用户又切回 A 时，B 的续体会把
A 的编辑区刷成 B 的草稿（实测表现为"切回来草稿是空的"）。didUpdateWidget 只管得住换设备
那一刻，管不住换完之后回来的续体。

两个 State 类公开之后 didUpdateWidget 的参数名要一起改：old 这个名字在类私有时不报，
公开后报 avoid_renaming_method_parameters（info），而 info 会打掉"analyze 干净"这条验收。

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
9. **"已发送的行"高亮会变旧。** `SentLineController.sentLines` 只在 `_send()` 里
   `clear() + addAll(linesToSend(...))`，**用户手工增删行时它不动**。所以发完
   `a\nb` 再在上面插入一行，被标暗的仍是行号 0/1 —— 而那两行已经不是当初发出去
   的内容了。这是 FR-E-10 按**行号**记的语义取舍（按"行号"而不是按"内容"记才
   能在同一行多次发送时不乱），不是缺陷；真要修得给每次发送留一个内容指纹。
   Task 7 那条高亮用例**只验了"标记落在对的行上"**，没有验这个场景 —— 名字已
   按实测范围改准。
10. ~~**同一个画面里的多次拖拽会各自从同一个基准算起。**~~ **已在 Task 9 修掉。**
    分隔条现在在 `MainWindow` 的本地状态里累积（`_draggingWidth` / `_draggingRatio`），
    `onDrag` 以本地值为基准，所以一次拖动里到达的多个 pointer move 会**相加**而不是
    各自从旧值重算 —— 实测 `tester.drag(Offset(0, 60))` 的两段（20 + 40）合起来正好
    是 60px 对应的比例，而改之前只有 40 那段生效。
11. ~~**拖动分隔条是"一次 pointer move 写一次 `settings.json`"。**~~ **已在 Task 9
    修掉，而且原先那句"功能上没错"是错的。** 落盘现在挂在 `onDragEnd` 上，一次拖动
    一次写。原判断错的理由：重叠的两次原子写**不是"多写几次盘"，而是会抛** ——
    `writeFileAtomically` 写 `.tmp` 再 rename，先完成的那条把 `.tmp` 挪走，后到的
    那条 rename 红在 `PathNotFoundException: ... (errno = 2)`，实测复现（见 Step 3
    末尾）。另一条代价也真实存在：那条链里有 `chmod`（**一个进程**），60Hz 的拖动
    就是每秒起 60 个。
12. **重叠的原子写是一个**通用**隐患，Task 9 只堵住了拖动这一条路。**
    `writeFileAtomically` 的两步（写 `.tmp` → rename）**不支持同一路径上的并发写**：
    后到的那条 rename 会抛 `PathNotFoundException`（见未决项 11 的实测）。Task 9 把
    拖动改成"松手写一次"，界面上唯一"高频写同一个文件"的路径就此没有了；但**别的路径
    仍可能重叠** —— 例如在设备列表里连着删两台（两次 `DevicesNotifier.remove` →
    两次 `_save` → 两条 `devices.json` 原子写）。真机上要两只手同时按才碰得上，所以
    这一版没修。要修的话位置在 `json_file.dart`（给 `.tmp` 加唯一后缀 —— 不再互踩，
    但"最后落盘的到底是谁"变成不确定的）或在 store 那一层串行化（推荐，顺序也一起
    保住了）。
13. **`settleDisk` 的轮数是拍的**（12 轮 × 5ms 真实时间 + 16ms 假时间）。它够用是因为
    `save()` 的 I/O 链就两三步；**哪天 `DeviceStore` 的写入步数变多，这个数字就可能
    不够**，表现是用例偶发红在"状态没变"—— 而那个现象看着像断言写错了（Task 8 第 2 条
    就是这么骗了一次）。真要收紧，正确做法不是把轮数继续加大，而是给 store 开一个
    测试用的完成钩子（或在 `pumpUi` 里换成内存 store）。**在有人加轮数之前，先看一眼
    这条。**

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

**实现期在 Task 7 抓到四处誊抄错 + 两处 `unused_import`，已就地改掉**
（改完实测 `flutter test test/ui/editor_panel_test.dart` = 5/5 绿，
`test/ui/sent_line_controller_test.dart` = 4/4 绿，
`dart analyze` 这四个文件 = `No issues found!`）：

1. **Step 7 的三段片段拼起来少一个类收尾 `}`**（`{` 32 个、`}` 31 个）——
   照抄会红在 `Can't find '}' to match '{'`。已补。
2. **Step 7 的 import 块没有 `DeviceConnectionState` 的来源**：它定义在
   `lib/connection/connection_manager.dart:20`，而 **Dart 的 import 不传递**，
   `providers.dart` 虽然 import 了它却不会转手导出。已补
   `import '../../connection/connection_manager.dart';`。
3. **Step 5 原先那句"`FakeSession` 的提示符是同步回的"是错的**：它**没有**提示符
   行为（`output` 是空的广播流，只有 `emit` 才吐数据），而队列是**一条一条发的** ——
   不吐提示符就停在第一条，那条 10 秒超时定时器一直挂着，用例在**拆卸期**红在
   `A Timer is still pending even after the widget tree was disposed`，
   而 `written` / `sentLines` 的断言**其实已经过了**。这是个会把人引向"断言写错了"
   的假象。已改成 `drainQueue()`（`emit('Switch# ')` + `pump(300ms)`，越过
   `CommandDispatcher` 默认的 120ms `promptDebounce`），三处各按队列长度推 1 / 3 / 2 步。
   **Task 9 的 Esc 用例本来就是这么推队列的**，Task 7 当时没跟上。
4. **第 5 条用例断言 `sentLines == {0, 1}` 却没设选中**：`tester.enterText` 会把光标
   收到文本末尾（`TextSelection.collapsed(offset: 2)` = 第 2 行），而"没有选中就只发
   光标那一行" → 只发出 1 条，`Actual: Set:[1]`。已按第 1 条的写法显式设
   `TextSelection(baseOffset: 0, extentOffset: 3)`；第 3 条同样需要（它的名字叫
   "队列执行中"，只发一条就名不副实），顺手把断言从 `textContaining('执行中')`
   收紧成 `find.text('执行中 1/3')`。
5. **Step 5 的 import 块里两处 `unused_import`**（`flutter_riverpod` 与
   `state/providers.dart`：两者都由 `ui_harness.dart` 代劳）已删 —— 它们会让
   "`dart analyze lib/ test/` 干净"这条验收项挂掉。

**实现期在 Task 8 又抓到六处，其中第 1 条是**真机缺陷**（删一台设备就把界面打红，
不是测试的毛病）** —— 1–3 是照计划的代码实测 `flutter test test/ui/device_list_panel_test.dart`
时红的，4–6 是**派发前**照计划把代码摆出来跑的时候抓到的。改完实测：该用例文件
**5/5 绿**、全仓 `flutter test` = **501 条全绿**、`dart analyze lib/ test/` = `No issues found!`。

1. **删设备时 `SessionNotifier.build()` 抛 `Bad state: No element`（真机缺陷）**：
   设备列表里每一行都 `ref.watch(sessionProvider(device.id))`，而
   `DevicesNotifier.remove()` 会 `ref.invalidate(sessionProvider(id))` —— 被删的
   那一行**要到下一帧才拆**，Riverpod 于是在同一帧的 `_performRefresh` 里重建它，
   原来那句 `firstWhere` 找不到设备就抛。**计划里原本没有这一处改动**，是删除那条
   用例红出来的。已给 `SessionNotifier` 补"设备已删 → 返回空状态"的早返回，
   `_controller` 改成可空、四个方法一并容忍（Step 4）。注意 `build()` 里造 controller
   的那一段也得跟着改（可空字段不会被类型提升），所以是**三处**替换、不是一个。
2. **"`pumpAndSettle()` 之后状态没变"不是断言写错了，是假时钟里真盘 I/O 走不完**：
   `DeviceStore.save()` 至少是 `create(recursive: true)` + `writeAsString()` 两步，
   而 `pump()` 只 flush 微任务、**不转真实事件循环**；`runAsync(delay)` 只转一次真实
   轮转、**不 flush 假队列**。两条路都实测过：`save()` 之后连文件都没建出来
   （`existsSync()` 是 false）。所以新增 `settleDisk()`（两者交替若干轮，Step 5），
   删除与拖拽两条用例改用它。
   **这两条用例的名字仍然站得住**：`_save` 是先落盘、成功了才改内存状态
   （`await ...save(next); state = next;`），所以"状态变了"就蕴含"盘写成了"——
   断言内存状态并不比断言文件内容弱。
3. **拖拽那条的落点原本落在框架的死区里**：计划原写 `to.dy + 20`（= 104）。框架判
   插入位置看的是**被拖那一项的矩形**与第二项的重叠关系（`_dragUpdateItems`），
   指针落在第二项**下半**（84–112）时 `_insertIndex` 等于被拖项的原地下标，
   去掉被拖项后正好是原地 —— **`onReorderItem` 一次都不调**。三种落点都实测过：
   `to.dy - 10` ✓、`to.dy + 90` ✓、`to.dy + 20` ✗。已改成 `to.dy + 90`，并把原先
   那句"`ReorderableListView` 按中线决定插入位置"（**错的**）换成了实测表格。
4. **`onReorder` 在这版 SDK 已废弃，且 `newIndex` 的语义跟着变了**：
   `deprecated_member_use` 只是条 info，正好打掉"`dart analyze` 干净"这条验收；
   换成 `onReorderItem` 的同时**必须删掉** `if (newIndex > oldIndex) newIndex -= 1;`
   —— 框架已经替你调好了（SDK 原话："remove the manual adjustment of newIndex"），
   再减一次的表现是"往下拖一格没反应、拖两格只动一格"，而拖拽用例的
   `['d2', 'd1']` 会永远不成立。
5. **删除确认对话框的标题不能也叫"确认删除"**：用例既用
   `find.textContaining('确认删除')` 断言只有一个、又用 `find.text('确认删除')` 去点
   按钮 —— 两处字符串一样的话，标题那个 `Text` 与按钮里那个 `Text` 会被双双匹配到，
   `findsOneWidget` 与 `tap` 一起失败。已把标题改成 `删除设备`，并在代码里写明了
   别"顺手统一"。
6. **`selectedDeviceProvider` 原本定义在 Task 9，却第一个被 Task 8 用到**：任务按顺序
   执行，照原计划 Task 8 连编译都过不去（`Undefined name 'selectedDeviceProvider'`）。
   已把那个块**整体挪到 Task 8 Step 4**，Task 9 的那一步改成只做核对（"本步不要再添加"）。

**实现期在 Task 9 又抓到四处**，全部是**派发前**照计划的代码摆出来跑的时候红的
（`flutter test test/ui/main_window_test.dart`）。改完实测：该用例文件 **6/6 绿**、
全仓 `flutter test` = **507 条全绿**、`dart analyze lib/ test/` = `No issues found!`。
改后的代码已作为 Step 3 / 5 / 6 的围栏逐字贴回本计划。

1. **草稿用例的两处泵盘**：`pumpUi` 结尾的 `pumpAndSettle()` 走不完编辑区 `initState`
   里那次真盘读（实测：`draftProvider('d1')` 仍是 `AsyncLoading`），于是 `_seeded`
   一直是 false、`_onTextChanged` 早返回、防抖根本没武装 —— 表现是"敲进去的字一个
   都没落盘"。已在 `pumpWindow` 结尾与 `enterText` 之后各补一次 `settleDisk`。
   **这一条也是"假时钟里真盘 I/O 走不完"的第三种表现**（前两种是 Task 8 的删除与拖拽）：
   前两种是**写**，这一种是**读**。
2. **`_loadDraft` 的续体不回认设备**（真机缺陷）：切到 B 再立刻切回 A 时，B 那次读的
   续体会把 A 的编辑区刷成 B 的草稿。实测的现象是"切回来草稿是空的"，而
   `draftProvider('d1')` 那一刻已经是 `AsyncData('sys')` —— 证据在**编辑区的 text**
   而不是在 provider 里，所以只看状态层永远查不出来。已在 Step 2 加了 `deviceId`
   比对（真机上"手快"就能碰到，不是测试的毛病）。
3. **分隔条的两种写法都会红，而且原因不同**：原先"每次 `onDrag` 都写盘"红在
   `PathNotFoundException: Cannot rename file .../settings.json.tmp (errno = 2)`
   —— 探针打印出一次 `tester.drag(Offset(0, 60))` 会发**两次** `onDrag`（touch slop
   把它拆成 20 + 40），两条原子写同时上路，先完成的那条把 `.tmp` 挪走了。
   **这不是"多写几次盘"，是会抛**，所以未决项 11 原先那句"功能上没错"是错的。
   已改成"拖动期间只动本地值、`onDragEnd` 落盘一次"（`Splitter` 因此多了一个
   `onDragEnd` 参数），顺带把未决项 10 的"多次 move 各自从旧值重算"一起了掉。
4. **`didUpdateWidget(EditorPanel old)` 在类公开之后会报 info**：HEAD 上不报（类当时
   是私有的），公开后 `dart analyze lib/ test/` 输出 1 条
   `avoid_renaming_method_parameters`。info 会打掉"analyze 干净"这条验收，所以参数名
   要一起改成 `oldWidget`（Step 2 第 3 处）。
