# 计划 5b-2：对话框、命令库与导入同步 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 5b-1 留下的三个占位（设备编辑、设置、指纹确认）与四条功能（命令库抽屉、导入文件、同步到另一台、断线告警）全部落地，让这个应用从"能连能发"变成"需求文档里写的东西都在"。

**Architecture:** 界面层只新增两类东西：`lib/ui/dialogs/` 下的模态对话框（设备编辑、设置、导入、同步、指纹确认），和两个 provider（`fileReaderProvider` 提供可注入的文件读取缝、`hostKeyPromptProvider` 把 SSH 握手中的"首次连接确认指纹"变成一个 Completer + 一个挂在 `MaterialApp.home` 上的对话框宿主）。**状态层只在两处动**：`sessionFactoryProvider` 补上 `onUnknownHostKey`（今天这一行缺失，导致 FR-C-11 的"接受并保存"整条路径不可达），以及 `Lib/connection/connection_manager.dart` 的 `_scheduleRetry` 让首次失败可达红灯（FR-C-06）。**不新增任何 pub 依赖。**

**Tech Stack:** Flutter 3.44.4 / Dart 3.12.2、flutter_riverpod 3.4.3、dartssh2 4.1.0、`flutter_test`。

---

## 这份计划的地基（执行者先读这一段）

- **`flutter test`，不是 `dart test`。** 两条命令都会"跑起来"，但只有前者带了 Flutter 的测试绑定；用后者跑 widget 测试会红在一片看不懂的地方。
- **`dart analyze lib/ test/` 必须打印 `No issues found!`** —— 连 `info` 级的 lint 都算验收不通过。本仓已经因为 `deprecated_member_use` 栽过一次（见 `device_list_panel.dart` 里那段注释）。
- **不要跑 `dart format`。** 本仓的换行是手排的，格式化会把承重的注释与代码对齐一起搅乱。
- **绝不并发跑两个 `flutter test`**（spec §13.23：锁竞争实测把一次运行拖成 13 分钟）。
- **`git add` 一律按显式路径**，不要 `git add -A`。
- **提交信息末尾固定一行**：`Co-Authored-By: Claude Code <noreply@anthropic.com>`。
- **不要改 `git config user.email`、不要配 remote、不要 push、不要 rebase/amend/reset。**
- **不要编辑 `docs/superpowers/plans/` 下的任何文件** —— 计划是评审过的产物，控制器负责拼接。
- **发现的代码块/断言看起来是错的就停下来报告**，不要就地"修好"或把断言放松。你的报告不带用户授权。
- 计划里的 `dart` 围栏是**逐字抄的**，不是示意。抄进去的时候不要"顺手改好"。

### 测对话框之前必须先知道的两件事（Task 4 实测踩出来的，Task 5/6/7/9 同样适用）

1. **默认的测试窗口是 800×600，装不下一张长对话框。** 实测设备编辑对话框的内容
   有 798 逻辑像素高，而视口只有 384 —— 折在窗口外的控件 `tap` 只是**空点一下**，
   不报错。设备对话框里「启动时自动连接」在 y=866、行尾符下拉在 y=634，
   两个都在 600 之外。**`tester.ensureVisible` 救不了**：内容滚到底（`pixels=322`，
   上限 `maxScrollExtent` 414）那两个控件仍在视口下沿之外。
   要**点到**靠下的控件，用例开头调 `useTallSurface(tester)`（在 `ui_harness.dart`）。
2. **`pumpAndSettle` 与 `settleDisk` 都推不动真 I/O。** `settleDisk` 的轮数是写死的
   （12 × 5ms ≈ 60ms 真实时间），够不够看机器当下忙不忙 —— 实测**同一份代码多一句
   `debugPrint` 就从红变绿**。断开那条路上还有 `restrictToOwner` 的
   `Process.run('chmod', …)`，那是**一个真子进程**。**不要靠多推几帧，按条件等**，
   `ui_harness.dart` 里三个都现成：

   | 等什么 | 用哪个 |
   |---|---|
   | 某样东西出现（SnackBar、某个控件） | `pumpUntil(tester, find.byType(...))` |
   | 某个条件为真（常是 provider 的状态） | `pumpUntilTrue(tester, () => …)` |
   | SnackBar | `pumpUntilSnackBar(tester)` |

   **而且别用状态断言代替它**：连接状态是经 `onStatus` 回调推进 provider 的，
   不等那个 await —— 实测状态已经是 `disconnected` 时 SnackBar 一个都还没有。
   反过来也一样：**要断状态就等状态**，别去等 SnackBar。
3. **用例结束时如果会话还连着，收尾要调 `drainCommandTimeout(tester)`。** 否则用例
   会红在**所有 `expect` 之后**：`connect()` 会把 `postLoginCommands` 排进
   `CommandDispatcher`，那是一个 10s 的命令超时定时器（默认值，
   `command_dispatcher.dart:75`），而 `FakeSession` 从不吐提示符，它就那么挂着；
   `flutter_test` 在用例体跑完后断言"没有挂着的定时器"（`binding.dart` 的
   `!timersPending`），于是报 `A Timer is still pending even after the widget tree
   was disposed`。**认出来的办法是数通过的条数** —— 每条 `expect` 其实都过了。
   会断开的用例**不需要**它（`disconnect()` 把 dispatcher 连同定时器一起拆了）。
   实测于 Task 5：同一个文件里两条正向用例绿、两条负向用例红，差别只在于断没断。
   **凡是故意让会话保持连接到结束的用例（Task 6 的「连接」菜单用例要当心），
   结尾都加这一行，位置在所有断言之后。**

### 已经定下来的四个用户决策（不要再重新论证）

1. **改连接参数就断开**（Task 5）：编辑设备时若连接参数变了，保存后断开该设备的会话并提示用户重连；只改显示字段（名字、自动连接、命令库）不动会话。
2. **FR-C-06 首次失败即变红，之后再退避**（Task 12）：第一次连接失败立刻变红灯，随后仍按 FR-C-07 退避重试（重试期间是黄灯）。
3. **断线告警只改文案、不动事件**（Task 13）：`QueueDropped(count)` 的形状不变，只订正措辞 —— 它现在说"未发送"，而 `count` 里含在途的那条，那条**已经发出去了**。
4. **导入文件（FR-E-15）用零依赖的路径输入框**（Task 7）：不引 `file_picker`/`file_selector`（会把 GTK 侧依赖与打包配置一起带进来），改成"路径输入框 + 可注入的读取缝"。

### 一条纠正（本计划对 5b-1 收尾记录里那句话的更正）

5b-1 的验收记录里写过"这台机器看不到界面，所以 golden 是唯一的眼睛"。**那句话是错的**，2026-09-26 已实测更正（见 `2026-09-25-ui-main-window.md` 的 Task 10 与「运行实测（2026-09-26 补）」两节）。本机有 xrdp 会话，`DISPLAY=:11` 能起窗口也能截图。所以 Task 15 的收尾里有一条**真机实测**，不是可选项。

---

## 文件结构

**新增（lib）**

| 路径 | 职责 |
|---|---|
| `lib/state/file_reader.dart` | `FileBytesReader` typedef + `fileReaderProvider`。**唯一的**文件读取入口，测试里换掉它就不必在临时目录造真文件 |
| `lib/state/host_key_prompt.dart` | `HostKeyPrompt`（一次待答的提问）+ `HostKeyPromptNotifier` + `hostKeyPromptProvider`。把"握手中途要问用户"变成一次 Completer |
| `lib/ui/widgets/host_key_prompt_host.dart` | 监听 `hostKeyPromptProvider`，起指纹对话框。挂在 `MaterialApp.home` 那一层 |
| `lib/ui/dialogs/device_edit_dialog.dart` | 设备编辑对话框（FR-D-01…05、11、12）+ `connectionParamsDiffer` |
| `lib/ui/dialogs/host_key_dialog.dart` | 指纹确认对话框（FR-C-11） |
| `lib/ui/dialogs/import_dialog.dart` | 导入文件对话框（FR-E-15/16） |
| `lib/ui/dialogs/settings_dialog.dart` | 设置对话框（FR-G-01/02、FR-C-13） |
| `lib/ui/dialogs/known_hosts_section.dart` | 设置里的「已知主机密钥」区（FR-G-01 的查看与逐条清除） |
| `lib/ui/dialogs/sync_dialog.dart` | 同步到另一台设备（FR-E-17） |
| `lib/ui/panels/snippet_drawer.dart` | 命令库抽屉（FR-S-01/02/03/04） |

**修改（lib）**

| 路径 | 改动 |
|---|---|
| `lib/models/device_profile.dart` | `Snippet` 补 `==` / `hashCode` |
| `lib/state/providers.dart` | `newSnippetId()`；`sessionFactoryProvider` 补 `onUnknownHostKey` |
| `lib/ui/panels/editor_panel.dart` | `insertAtCursor` / `replaceAllText` / `appendText` 三个公开方法；工具栏补 命令库 / 导入文件 / 同步 三个按钮；`QueueDropped` 文案 |
| `lib/ui/panels/device_list_panel.dart` | 右键菜单补「连接/断开/编辑」 |
| `lib/ui/main_window.dart` | `endDrawer` 挂命令库；AppBar 补「设置」；`_addDevice` 接真对话框 |
| `lib/app.dart` | `home` 外面套 `HostKeyPromptHost` |
| `lib/state/session_controller.dart` | 断线告警文案 |
| `lib/connection/connection_manager.dart` | `_scheduleRetry` 首次失败变红 + `DeviceConnectionState` 的文档 |
| `lib/connection/telnet_session.dart` | `connect()` 补入口守卫（spec §13.21-2） |
| `lib/connection/session.dart` | `close()` 的文档补"`connect()` 失败后仍需 `close()`"（spec §13.21-4） |

**新增（test）**

`test/ui/editor_text_api_test.dart`、`test/ui/snippet_drawer_test.dart`、`test/ui/device_edit_dialog_test.dart`、`test/ui/device_params_change_test.dart`、`test/ui/import_dialog_test.dart`、`test/ui/sync_dialog_test.dart`、`test/ui/settings_dialog_test.dart`、`test/ui/known_hosts_section_test.dart`、`test/ui/host_key_dialog_test.dart`、`test/state/host_key_prompt_test.dart`

**修改（test）**

`test/models/device_profile_test.dart`、`test/ui/ui_harness.dart`、`test/ui/main_window_test.dart`、`test/ui/device_list_panel_test.dart`、`test/state/session_controller_test.dart`、`test/connection/connection_manager_test.dart`、`test/connection/telnet_session_test.dart`

---

## 任务依赖图

```
Task 1  Snippet 值相等 ─────────────┐
Task 2  编辑器文本 API ──┬── Task 3  命令库抽屉
                        └── Task 7  导入文件
Task 4  设备编辑对话框 ──┬── Task 5  改参数即断开
                        └── Task 6  右键菜单 + ＋ 接线
Task 8  设置对话框 ──────── Task 9  已知主机密钥区
Task 10 指纹对话框 + 接线
Task 7  导入文件 ──────┐
Task 8  设置对话框 ────┼── Task 11 同步到另一台（要 settings? 不要；顺序只为让编辑器工具栏一次改完）
Task 11 同步 ──────────┘
Task 12 FR-C-06 红灯 ──── 独立
Task 13 断线文案 ──────── 独立
Task 14 §13.21 顺手项 ─── 独立
Task 15 收尾验收
```

Task 11 排在 Task 7/8 之后只是因为它们都在改编辑区工具栏与 `main_window.dart` —— 按顺序做，冲突面最小。Task 12/13/14 与界面无关，可以在任何一个卡住时先做掉。

---

## Task 1：`Snippet` 的值相等

**为什么做：** spec §13.7 记着 5a 的一笔未决 —— `Snippet` 没有 `==`/`hashCode`，于是两次 `Snippet.fromJson` 出来的同一个片段在 `List.contains` / `Set` 里**不相等**。命令库抽屉要用 `indexWhere((s) => s.id == ...)` 判"这条是不是已存在"，值相等是那一层的地基。

**Files:**
- Modify: `lib/models/device_profile.dart:26-50`
- Test: `test/models/device_profile_test.dart`

- [ ] **Step 1：写失败的测试**

在 `test/models/device_profile_test.dart` 的 `group('Snippet', ...)` **里面**追加（那个 group 现在只有一条 JSON 往返用例，在该 group 的右花括号前插入）：

```dart
    test('值相等：三个字段全同才相等（spec §13.7）', () {
      // **两个操作数都必须是非 const 构造，这不是风格问题。** Dart 会把参数
      // 相同的 `const` 字面量**规范化成同一个实例**，而 `Object.==` 是按身份
      // 答的 —— 写成 `const a = Snippet(...); const b = Snippet(同样参数);`
      // 的话 `a == b` 在**没有** `==` 的时候也是 true，这四条用例会全部变绿，
      // 于是它们守不住任何东西（实测：那种写法下四条全绿，连删掉本任务加的
      // `==` 都不红）。`fromJson` 是运行期构造，拿到的一定是新实例，只有
      // **值相等**才能让它绿 —— 这也正是本任务"为什么做"里说的那个场景。
      final a = Snippet.fromJson(
        const Snippet(id: 's1', name: '看版本', content: 'display version')
            .toJson(),
      );
      final b = Snippet.fromJson(
        const Snippet(id: 's1', name: '看版本', content: 'display version')
            .toJson(),
      );

      // 把"这是两个不同实例"也断言出来：否则将来有人把上面改回 const，
      // 用例会安安静静地退化成恒真，没人会注意到。
      expect(identical(a, b), isFalse, reason: '前提：两个不同的实例');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('缺任一字段就不相等', () {
      const base = Snippet(id: 's1', name: '看版本', content: 'display version');
      final copy = Snippet.fromJson(base.toJson());

      expect(copy, equals(base), reason: '前提：字段全同的副本是相等的');
      expect(copy.copyWith(name: '看接口'), isNot(equals(copy)));
      expect(copy.copyWith(content: 'display interface'), isNot(equals(copy)));
      expect(
        Snippet(id: 's2', name: '看版本', content: 'display version'),
        isNot(equals(copy)),
        reason: 'id 也是身份的一部分：两条同名片段是允许的',
      );
    });

    test('List.contains / Set 按值判（命令库据此判重）', () {
      const a = Snippet(id: 's1', name: 'x', content: 'y');
      final b = Snippet.fromJson(a.toJson());

      expect(identical(a, b), isFalse, reason: '前提：两个不同的实例');
      expect(<Snippet>[a].contains(b), isTrue);
      expect(<Snippet>{a}.contains(b), isTrue);
      expect(<Snippet>{a, b}, hasLength(1), reason: '值相等 → Set 里塌成一条');
    });

    test('与别的类型比不相等，且不抛', () {
      final a = Snippet.fromJson(
        const Snippet(id: 's1', name: 'x', content: 'y').toJson(),
      );

      // **`a == Object()` 里的括号不能省，也不能换成 `a == 's1'`。**
      // 三种写法的分析器结果（在 flutter 3.44.4 上实测）：
      //   - `a == null`  → `unnecessary_null_comparison`（`Snippet` 非空，
      //                    恒为 false）—— 会打破 Step 5 的"分析器干净"；
      //   - `a == 's1'`  → `unrelated_type_equality_checks`（info）—— 同样打破；
      //   - `a == Object()` → **干净**（`Object` 是 `Snippet` 的超类型，
      //                    那条 lint 不管）。
      // 它守的是"别把类型判断漏掉"：若实现写成 `(other as Snippet).id == id`
      // 少了 `other is Snippet`，这一句会抛 `CastError`。
      expect(a == Object(), isFalse);
    });
```

- [ ] **Step 2：跑测试，确认它红**

Run: `flutter test test/models/device_profile_test.dart`
Expected: FAIL —— 前三条红（`Expected: <Instance of 'Snippet'> / Actual: <Instance of 'Snippet'>` 与 `Expected: true / Actual: <false>`），第四条"与别的类型比"**绿**（`Object.==` 对不同类型的两个对象本来就这么答）。这是对的：它守的是"你写 `==` 的时候别把类型判断漏掉"，与值相等无关，现在还没写 `==`，它当然过。

（实测记录：这四条在**没有** `==` 时是 3 红 1 绿；加上 `==` 之后 4 条全绿。这个红绿差就是它们真正的守备范围。）

- [ ] **Step 3：实现**

在 `lib/models/device_profile.dart` 的 `Snippet` 类里，`toJson` 之后（第 49 行那个 `};` 与第 50 行的 `}` 之间）加：

```dart
  /// 值相等（spec §13.7）。
  ///
  /// **三个字段全参与**，包括 [id]。两条同名同内容的片段是合法的（用户可能
  /// 想把同一条命令按不同用途存两份），所以不能用"名字 + 内容"当身份 —— 那样
  /// 后者会把前者顶掉。反过来，`id` 单独当身份也不行：`Snippet` 的 id 只在
  /// 一台设备的数组里唯一，跨设备比会误判成同一条。
  @override
  bool operator ==(Object other) =>
      other is Snippet &&
      other.id == id &&
      other.name == name &&
      other.content == content;

  @override
  int get hashCode => Object.hash(id, name, content);
```

- [ ] **Step 4：跑测试，确认全绿**

Run: `flutter test test/models/device_profile_test.dart`
Expected: PASS（整个文件，不只是新加的四条）

- [ ] **Step 5：静态检查**

Run: `dart analyze lib/models/device_profile.dart test/models/device_profile_test.dart`
Expected: `No issues found!`

- [ ] **Step 6：提交**

```bash
git add lib/models/device_profile.dart test/models/device_profile_test.dart
git commit -m "feat(models): Snippet 补值相等（spec §13.7 / 5a 未决项 4）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 2：编辑区的文本变更 API

**为什么做：** 命令库抽屉（FR-S-03）要往光标处插一段文本，导入文件（FR-E-15）要整份替换或追加 —— 而 `EditorPanelState` 今天只有 `send()` 和 `clearOutput()` 这类动作，**没有任何改文本的入口**。三个方法一起加，因为它们共享同一条"改完要落盘、要重画行号"的约束。

**Files:**
- Modify: `lib/ui/panels/editor_panel.dart`（在 `send()` 那一族方法附近，第 148 行之前）
- Test: `test/ui/editor_text_api_test.dart`（新建）

- [ ] **Step 1：写失败的测试**

新建 `test/ui/editor_text_api_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_edapi_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<EditorPanelState> pumpEditor(WidgetTester tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [fakeProfile(id: 'd1', name: 'A')],
      child: const SizedBox(height: 400, child: EditorPanel(deviceId: 'd1')),
    );
    // 编辑区在 `initState` 里读草稿是**真盘 I/O**，`pumpAndSettle` 走不完。
    await settleDisk(tester);
    return tester.state<EditorPanelState>(find.byType(EditorPanel));
  }

  /// 编辑区里那个 `TextEditingController`。
  TextEditingController controllerOf(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!;

  /// 把文本换成 [text] 并把光标停在 [offset]。
  ///
  /// **不能只靠 `tester.enterText`**：它会把整段文本选中（`baseOffset: 0,
  /// extentOffset: length`），于是 `insertAtCursor` 走的是"替换整个编辑区"
  /// 而不是"插入"。光标必须显式摆一次。
  void setTextAndCaret(WidgetTester tester, String text, int offset) {
    controllerOf(tester).value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  testWidgets('光标所在行非空：先换行再插入（FR-S-03）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a\nb', 3);

    state.insertAtCursor('save');

    expect(controllerOf(tester).text, 'a\nb\nsave');
  });

  testWidgets('光标所在行是空行：不添换行（FR-S-03）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a\n', 2);

    state.insertAtCursor('save');

    expect(controllerOf(tester).text, 'a\nsave');
  });

  testWidgets('只有空白字符的行不算非空行（FR-E-08 的"一个空格是空行"）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a\n   ', 5);

    state.insertAtCursor('save');

    expect(controllerOf(tester).text, 'a\n   save');
  });

  testWidgets('从未获得过焦点（selection 无效）时插到末尾', (tester) async {
    final state = await pumpEditor(tester);
    controllerOf(tester).value = const TextEditingValue(
      text: 'a',
      selection: TextSelection.collapsed(offset: -1),
    );

    state.insertAtCursor('save');

    expect(controllerOf(tester).text, 'a\nsave');
  });

  testWidgets('插入之后光标在插入内容的末尾（连着双击两条不会倒着拼）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a', 1);

    state.insertAtCursor('save');

    expect(controllerOf(tester).selection.baseOffset, 6);
    expect(controllerOf(tester).selection.isCollapsed, isTrue);
  });

  testWidgets('replaceAllText 整份替换并把光标放到末尾', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'old', 3);

    state.replaceAllText('x\ny');

    expect(controllerOf(tester).text, 'x\ny');
    expect(controllerOf(tester).selection.baseOffset, 3);
  });

  testWidgets('appendText：原文本不以换行结尾时补一个（FR-E-15 的"追加到末尾"）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a', 1);

    state.appendText('save');

    expect(controllerOf(tester).text, 'a\nsave');
  });

  testWidgets('appendText：原文本以换行结尾时不补', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a\n', 2);

    state.appendText('save');

    expect(controllerOf(tester).text, 'a\nsave');
  });

  testWidgets('appendText：编辑区是空的时候不产生开头的空行', (tester) async {
    final state = await pumpEditor(tester);

    state.appendText('save');

    expect(controllerOf(tester).text, 'save');
  });

  testWidgets('改文本会触发草稿落盘（接上 FR-E-03）', (tester) async {
    final state = await pumpEditor(tester);
    setTextAndCaret(tester, 'a\nb', 3);

    state.insertAtCursor('save');
    // 防抖窗口是 500ms（`DraftAutosave` 的默认值），推过去再等盘。
    await tester.pump(const Duration(milliseconds: 600));
    await settleDisk(tester);

    expect(File('${root.path}/drafts/d1.txt').readAsStringSync(), 'a\nb\nsave');
  });
}
```

- [ ] **Step 2：跑测试，确认它红**

Run: `flutter test test/ui/editor_text_api_test.dart`
Expected: FAIL —— 编译错误 `The method 'insertAtCursor' isn't defined for the type 'EditorPanelState'`（以及 `replaceAllText` / `appendText`）。这是"红"的正常形状：方法还不存在。

- [ ] **Step 3：实现**

在 `lib/ui/panels/editor_panel.dart` 里 `void send()`（第 148 行）**之前**插入：

```dart
  /// FR-S-03：把一段文本插入**当前光标处**。
  ///
  /// **光标所在行非空时先换行**（FR-S-03 原文）。判的是光标所在那一行，不是
  /// "文本末尾" —— 把片段接在 `display version` 的尾巴上会拼出一条谁也没写过
  /// 的命令，而那条命令会真的发到设备上。
  ///
  /// **只有空白字符的行不算非空行。** FR-E-08 规定"确需发送空行时，在行内输入
  /// 一个空格"，所以一行 `'   '` 是**空的**；它上面没有命令可拼，添一个换行只会
  /// 平白多出一个空行。
  void insertAtCursor(String content) {
    final text = _text.text;
    final selection = _text.selection;
    // 从未获得过焦点时 selection 是 `collapsed(offset: -1)`（`isValid` 为
    // false）。此时按"插到末尾"处理 —— 直接抛或什么都不做，都会让"双击命令库
    // 但编辑区还没点过"变成一个静默失败。
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;

    // `lastIndexOf` 在 start-1 < 0 时返回 -1，加一正好是 0。
    final lineStart = text.lastIndexOf('\n', start - 1) + 1;
    final lineEndIndex = text.indexOf('\n', start);
    final lineEnd = lineEndIndex < 0 ? text.length : lineEndIndex;
    final lineIsBlank = text.substring(lineStart, lineEnd).trim().isEmpty;

    final insertion = lineIsBlank ? content : '\n$content';
    _setText(
      text.replaceRange(start, end, insertion),
      caret: start + insertion.length,
    );
  }

  /// 用 [content] **整份替换**编辑区内容（FR-E-15 的「替换现有内容」）。
  void replaceAllText(String content) => _setText(content, caret: content.length);

  /// 把 [content] **追加到末尾**（FR-E-15 的「追加到末尾」）。
  ///
  /// 原文本非空且不以换行结尾时补一个换行 —— 不补的话，原来的最后一行会和导入
  /// 进来的第一行粘成一条，而那正是用户最不容易发现的一种错。
  void appendText(String content) {
    final text = _text.text;
    if (text.isEmpty) {
      replaceAllText(content);
      return;
    }
    replaceAllText('$text${text.endsWith('\n') ? '' : '\n'}$content');
  }

  /// 三个改文本的入口都走这里。
  ///
  /// 一次写 `value`（而不是先改 `text` 再改 `selection`）有两个好处：
  /// `_text.text = ...` 会把 selection 收成无效值，而 listeners 会在那一次就
  /// 被通知 —— `_onTextChanged` 于是排一次落盘、`setState` 重画一次行号栏；
  /// 写两次就是白做一轮。
  void _setText(String next, {required int caret}) {
    _text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
  }

```

- [ ] **Step 4：跑测试，确认全绿**

Run: `flutter test test/ui/editor_text_api_test.dart`
Expected: PASS（10 条）

- [ ] **Step 5：跑一遍相关的旧测试，确认没打破什么**

Run: `flutter test test/ui/editor_panel_test.dart test/ui/main_window_test.dart`
Expected: PASS

- [ ] **Step 6：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 7：提交**

```bash
git add lib/ui/panels/editor_panel.dart test/ui/editor_text_api_test.dart
git commit -m "feat(ui): 编辑区补文本变更 API（插入光标处 / 替换 / 追加）

FR-S-03 的插入语义与 FR-E-15 的两种导入方式共用同一条落盘与重画路径。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 3：命令库抽屉（FR-S-01/02/03/04）

**为什么做：** 命令片段这半边 `DeviceProfile.snippets` 从计划 2 起就存在、也能持久化，但**没有任何界面能增删改，也没有任何地方能插入它** —— FR-S-01…04 四条需求今天一条都不可达。

**Files:**
- Create: `lib/ui/panels/snippet_drawer.dart`
- Modify: `lib/state/providers.dart`（加 `newSnippetId()`）
- Modify: `lib/ui/main_window.dart`（挂 `endDrawer`）
- Modify: `lib/ui/panels/editor_panel.dart`（工具栏加「命令库」按钮）
- Test: `test/ui/snippet_drawer_test.dart`（新建）

**一个必须先知道的形状：** 抽屉挂在**主窗口**的 `Scaffold.endDrawer` 上（`test/ui/ui_harness.dart` 的 `pumpUi` 包的 `Scaffold` 没有抽屉），所以：
- 编辑区工具栏的「命令库」按钮调 `Scaffold.of(context).openEndDrawer()` —— 编辑区是主窗口 `Scaffold.body` 里的一棵树，`Scaffold.of` 找得到它。
- **`test/ui/editor_panel_test.dart` 与 `test/ui/editor_text_api_test.dart` 里绝不能点那个按钮**：那两个用例装的 `Scaffold` 没有 `endDrawer`。点下去**不炸** —— `ScaffoldState.openEndDrawer()` 的实现是 `_endDrawerKey.currentState?.open();`（`scaffold.dart:2310`），`endDrawer` 为 null 时 `currentState` 也是 null，`?.` 直接跳过，静默无操作。它比炸更坏：**那种用例会"绿着什么都没测"** —— 断言照过，抽屉根本没开过。命令库的用例一律走 `MainWindow`。

- [ ] **Step 1：先加 id 生成器**

在 `lib/state/providers.dart` 的 `newDeviceId()`（第 328 行）**之后**加：

```dart
/// 生成一个命令片段的 id。
///
/// **与 [newDeviceId] 共用同一个生成器是刻意的**：片段 id 不是文件名（它只在
/// 同一台设备的 `snippets` 数组里唯一），所以大小写不敏感的卷、Windows 保留
/// 设备名这些理由对它都不成立；但再写一份随机数代码只会多一处要维护的东西。
/// 留一个具名函数是为了让调用点读起来是"片段 id"，而不是"设备 id 用在了片段上"。
String newSnippetId() => newDeviceId();
```

- [ ] **Step 2：写失败的测试**

新建 `test/ui/snippet_drawer_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/main_window.dart';
// 「抽屉真的关了吗」这条断言要靠 `find.byType(SnippetDrawer)` 来问 ——
// 见下面那条用例里的注释。
import 'package:win_cli_tool/ui/panels/snippet_drawer.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_snip_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// d1 有两条片段，d2 一条都没有 —— FR-S-01 要的"各自独立"就靠这个对比。
  DeviceProfile withSnippets(String id, String name, List<Snippet> snippets) =>
      fakeProfile(id: id, name: name).copyWith(snippets: snippets);

  Future<void> pumpWindow(WidgetTester tester) async {
    await pumpUi(
      tester,
      root: root,
      devices: [
        withSnippets('d1', '核心交换机', const [
          Snippet(id: 's1', name: '保存配置', content: 'save\nY'),
          Snippet(id: 's2', name: '看版本', content: 'display version'),
        ]),
        withSnippets('d2', '边界防火墙', const []),
      ],
      child: const MainWindow(),
    );
    await settleDisk(tester);
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MainWindow)));

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byTooltip('命令库'));
    await tester.pumpAndSettle();
  }

  /// 双击。**`tester` 没有 doubleTap**，两次 `tap` 之间的间隔必须落在
  /// `kDoubleTapTimeout`（300ms）内，识别器才认。
  Future<void> doubleTap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('抽屉列出当前设备的片段（FR-S-01/02）', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);

    expect(find.text('保存配置'), findsOneWidget);
    expect(find.text('看版本'), findsOneWidget);
    expect(find.textContaining('命令库 · 核心交换机'), findsOneWidget);
  });

  testWidgets('换设备之后抽屉列的是新设备的（FR-S-01：各自独立）', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);
    expect(find.text('保存配置'), findsOneWidget);

    // 关掉抽屉再切设备：抽屉开着的时候点不到列表。
    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('边界防火墙'));
    await tester.pumpAndSettle();
    await openDrawer(tester);

    expect(find.text('保存配置'), findsNothing, reason: 'A 的片段不该出现在 B 的命令库里');
    expect(find.text('还没有命令片段'), findsOneWidget);
  });

  testWidgets('双击片段插入光标处，且抽屉关掉、主窗口还在（FR-S-03）', (tester) async {
    await pumpWindow(tester);

    final editor = tester.widget<TextField>(find.byType(TextField)).controller!;
    editor.value = const TextEditingValue(
      text: 'sys',
      selection: TextSelection.collapsed(offset: 3),
    );
    await tester.pump();

    await openDrawer(tester);
    await doubleTap(tester, find.text('看版本'));

    expect(
      editor.text,
      'sys\ndisplay version',
      reason: '光标在非空行上，插入前要先换行',
    );
    // 这两条合起来才证明"抽屉关了、而页面还在"。
    //
    // **别把它写成 `find.text('还没有命令片段')`。** d1 是有片段的，那句话在
    // d1 的抽屉里根本不会渲染 —— 写成它，这条断言就恒真了：抽屉关没关都绿。
    // （和 Task 1 里 const 规范化让相等用例恒真是同一类错误：断言在测空气。）
    // 要问的是抽屉这个**组件**还在不在，不是它里面某句文案。
    expect(find.byType(SnippetDrawer), findsNothing, reason: '抽屉要关上');
    expect(find.byType(MainWindow), findsOneWidget, reason: '关抽屉不能把页面一起弹掉');
  });

  testWidgets('添加片段：进了抽屉，也进了 devices.json（FR-S-04）', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);

    await tester.tap(find.byTooltip('添加命令片段'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('snippet-name')), '看接口');
    await tester.enterText(
      find.byKey(const ValueKey('snippet-content')),
      'display interface',
    );
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(find.text('看接口'), findsOneWidget);

    final stored = containerOf(tester)
        .read(devicesProvider)
        .firstWhere((d) => d.id == 'd1')
        .snippets;
    expect(stored.map((s) => s.name), contains('看接口'));
    expect(stored.first.id, 's1', reason: '加在末尾，前两条不动');
    expect(stored.last.content, 'display interface');
  });

  testWidgets('编辑片段：改名但 id 不变（FR-S-04）', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);

    await tester.tap(find.byTooltip('编辑 保存配置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('snippet-name')), '保存并退出');
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(find.text('保存并退出'), findsOneWidget);
    final stored = containerOf(tester)
        .read(devicesProvider)
        .firstWhere((d) => d.id == 'd1')
        .snippets;
    expect(stored, hasLength(2), reason: '编辑不能变成新增');
    expect(stored.first.id, 's1');
    expect(stored.first.content, 'save\nY', reason: '没动的字段要原样保留');
  });

  testWidgets('删除片段要二次确认；取消则还在（FR-S-04）', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);

    await tester.tap(find.byTooltip('删除 看版本'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除「看版本」'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('看版本'), findsOneWidget, reason: '取消了就不该删');

    await tester.tap(find.byTooltip('删除 看版本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await settleDisk(tester);

    expect(find.text('看版本'), findsNothing);
    final stored = containerOf(tester)
        .read(devicesProvider)
        .firstWhere((d) => d.id == 'd1')
        .snippets;
    expect(stored.map((s) => s.id), ['s1']);
  });

  testWidgets('片段名或内容为空时挡下来', (tester) async {
    await pumpWindow(tester);
    await openDrawer(tester);

    await tester.tap(find.byTooltip('添加命令片段'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('snippet-content')), 'x');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('名称不能为空'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget, reason: '没保存成功，对话框不该关');
  });
}
```

- [ ] **Step 3：跑测试，确认它红**

Run: `flutter test test/ui/snippet_drawer_test.dart`
Expected: FAIL —— **7 条全红**，先红在 `openDrawer` 里那次 `tap`。本机 flutter 3.44.4 的实际措辞是：

```
The finder "Found 0 widgets with widget matching predicate: []" (used in a call to "tap()")
could not find any matching widgets.
```

（不是"Could not find the tooltip"）。这是"功能还不存在"的正常形状。

- [ ] **Step 4：实现抽屉**

新建 `lib/ui/panels/snippet_drawer.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/device_profile.dart';
import '../../state/providers.dart';

/// 命令库抽屉（FR-S-01…04）。
///
/// **它是主窗口的 `Scaffold.endDrawer`**，打开它的按钮在编辑区工具栏里
/// （`Scaffold.of(context).openEndDrawer()`）。
///
/// 片段存在 `DeviceProfile.snippets` 里 —— 归属设备、跟着设备走（FR-S-01），
/// 所以增删改一律走 `devicesProvider.notifier.update`，**不另开一份存储**。
/// 这也是 FR-D-06"删设备时一并删掉命令库"天然成立的原因。
class SnippetDrawer extends ConsumerWidget {
  const SnippetDrawer({
    super.key,
    required this.deviceId,
    required this.onInsert,
  });

  final String deviceId;

  /// 双击一条片段时调用。**由主窗口实现** —— 插入的落点在编辑区的 State 里，
  /// 而抽屉够不到它（编辑区是抽屉的兄弟，不是子节点）。
  final void Function(String content) onInsert;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final index = devices.indexWhere((d) => d.id == deviceId);
    if (index < 0) {
      // 设备被删掉的那一帧，抽屉可能还在树上（`MainWindow` 的 `active` 要到
      // 下一帧才变成 null）。给一个空抽屉，别抛。
      return const Drawer(child: SizedBox.shrink());
    }
    final device = devices[index];

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(
                '命令库 · ${device.name}',
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: '添加命令片段',
                icon: const Icon(Icons.add),
                onPressed: () => _edit(context, ref, device, null),
              ),
            ),
            const Divider(height: 1),
            if (device.snippets.isEmpty)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('还没有命令片段', textAlign: TextAlign.center),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: device.snippets.length,
                  itemBuilder: (context, i) {
                    final snippet = device.snippets[i];
                    // `ListTile` 只有 `onTap`/`onLongPress`，没有 `onDoubleTap`
                    // —— 双击要靠外面这层 `GestureDetector`。
                    //
                    // ⚠ **两个按钮必须放在 `GestureDetector` 外面**，不能图省事
                    // 当 `ListTile.trailing`。`DoubleTapGestureRecognizer` 在第一次
                    // 按下时会 `gestureArena.hold(pointer)`（`gestures/multitap.dart:330`，
                    // `_registerFirstTap` 里），把手势竞技场**按住**到双击超时
                    // （300ms）才释放。按钮是 `GestureDetector` 的后代，于是单击
                    // 要等满 300ms 才轮到它赢；**双击按钮还会顺带触发插入**。
                    // 实测（本机 flutter 3.44.4）：写成 `trailing` 的话，
                    // `tap` 完 `pumpAndSettle()` 之后对话框是 0 个 ——
                    // `pumpAndSettle` 在 ~100ms 后就没有待处理的帧了，而 hold
                    // 还没释放；再推 400ms 才出现。这不是测试写法的问题，
                    // 是真机上按钮真的迟 300ms。
                    return Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onDoubleTap: () => onInsert(snippet.content),
                            child: ListTile(
                              title: Text(
                                snippet.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                snippet.content,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ),
                        ),
                        // tooltip 带片段名：两条片段的按钮必须能彼此区分。
                        IconButton(
                          tooltip: '编辑 ${snippet.name}',
                          icon: const Icon(Icons.edit, size: 18),
                          onPressed: () => _edit(context, ref, device, snippet),
                        ),
                        IconButton(
                          tooltip: '删除 ${snippet.name}',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () =>
                              _delete(context, ref, device, snippet),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    DeviceProfile device,
    Snippet? existing,
  ) async {
    final result = await showDialog<Snippet>(
      context: context,
      builder: (_) => _SnippetEditDialog(existing: existing),
    );
    if (result == null || !context.mounted) return;

    final next = [...device.snippets];
    final at = next.indexWhere((s) => s.id == result.id);
    if (at < 0) {
      next.add(result);
    } else {
      next[at] = result;
    }
    await _save(context, ref, device, next);
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    DeviceProfile device,
    Snippet snippet,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        // 标题与按钮的文字**必须不同**：两边一样的话，`find.text` 会同时匹配到
        // 标题与按钮，`findsOneWidget` 与 `tap` 双双失败。删除设备那条对话框
        // 的注释里记着同一条实测教训。
        title: const Text('删除命令片段'),
        content: Text('删除「${snippet.name}」？此操作不可撤销。'),
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
    if (confirmed != true || !context.mounted) return;

    await _save(
      context,
      ref,
      device,
      device.snippets.where((s) => s.id != snippet.id).toList(growable: false),
    );
  }

  /// 存片段。写的是**整台设备**（片段归属设备），所以走 `devicesProvider.update`
  /// —— 它先存盘再改内存，失败时异常原样抛出来给用户看。
  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    DeviceProfile device,
    List<Snippet> snippets,
  ) async {
    try {
      await ref
          .read(devicesProvider.notifier)
          .update(device.copyWith(snippets: snippets));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('命令库未能保存：$error')));
    }
  }
}

/// 加/改一条片段。
class _SnippetEditDialog extends StatefulWidget {
  const _SnippetEditDialog({this.existing});

  final Snippet? existing;

  @override
  State<_SnippetEditDialog> createState() => _SnippetEditDialogState();
}

class _SnippetEditDialogState extends State<_SnippetEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _content = TextEditingController(
    text: widget.existing?.content ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '名称不能为空');
      return;
    }
    // 内容**不 trim**：片段的多行结构是用户排的，首尾的空行也算数。
    if (_content.text.isEmpty) {
      setState(() => _error = '内容不能为空');
      return;
    }
    Navigator.of(context).pop(
      // **编辑时保留原 id**：id 是身份，`Snippet.copyWith` 也刻意不接受它。
      widget.existing?.copyWith(name: name, content: _content.text) ??
          Snippet(id: newSnippetId(), name: name, content: _content.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '添加命令片段' : '编辑命令片段'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('snippet-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('snippet-content'),
              controller: _content,
              maxLines: 6,
              minLines: 3,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: '内容（可多行）',
                border: OutlineInputBorder(),
              ),
            ),
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
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
```

- [ ] **Step 5：把抽屉挂上主窗口**

在 `lib/ui/main_window.dart` 的 `Scaffold`（第 68 行）里，`body:` 那行**之前**插入 `endDrawer:`：

```dart
          // 命令库抽屉（FR-S-01…04）。**没有选中设备时不给抽屉** —— 片段归属
          // 设备，一个不知道属于谁的抽屉没有意义。
          endDrawer: active == null
              ? null
              : SnippetDrawer(deviceId: active, onInsert: _insertSnippet),
```

并在 `_addDevice()` **之前**加方法：

```dart
  /// 双击命令库里的片段：**先关抽屉，再插入**。
  ///
  /// `Navigator.pop()` 关得掉抽屉而不是把页面弹掉：`DrawerController` 打开时
  /// 往当前路由挂了一个 `LocalHistoryEntry`，`LocalHistoryEntry.didPop` 会
  /// 消费掉这次 pop 并返回 false，于是路由本身留在原地。`snippet_drawer_test.dart`
  /// 里那条"主窗口还在"的断言守的就是这件事。
  void _insertSnippet(String content) {
    Navigator.of(context).pop();
    _editorKey.currentState?.insertAtCursor(content);
  }
```

别忘了在文件顶部加 import：

```dart
import 'panels/snippet_drawer.dart';
```

- [ ] **Step 6：工具栏加「命令库」按钮**

在 `lib/ui/panels/editor_panel.dart` 的 `_toolbar` 里，`const Spacer(),`（**现在在第 363 行**；Task 2 在 `send()` 前面插了 60 行，把它从 303 挤了下来 —— 按内容 grep，别信行号）**之前**插入：

```dart
          const SizedBox(width: 8),
          IconButton(
            tooltip: '命令库',
            icon: const Icon(Icons.menu_book, size: 18),
            // **`Scaffold.of` 找的是主窗口那个 Scaffold** —— 抽屉挂在它的
            // `endDrawer` 上，编辑区只是它 `body` 里的一棵树。
            // 这也是"编辑区的用例不能点这个按钮"的原因：`ui_harness.dart` 的
            // `pumpUi` 包的那个 `Scaffold` 没有 `endDrawer`。
            // 注意它**不是**炸，是**静默无操作**：`ScaffoldState.openEndDrawer`
            // 的实现是 `_endDrawerKey.currentState?.open();`（`scaffold.dart:2310`），
            // 没有 `endDrawer` 时 key 的 currentState 是 null，`?.` 直接跳过。
            // 所以那种用例只会以"什么都没发生"的形式红，不会给出好读的报错。
            onPressed: () => Scaffold.of(context).openEndDrawer(),
          ),
```

- [ ] **Step 7：跑测试，确认全绿**

Run: `flutter test test/ui/snippet_drawer_test.dart`
Expected: PASS（7 条）

一条常见红：`双击片段插入光标处…` 里 `editor.text` 拿到的还是旧值 —— 那说明 `_editorKey.currentState?.insertAtCursor` 走空了（编辑区的 `GlobalKey` 没匹配上）。检查 `MainWindow` 里 `EditorPanel(key: _editorKey, ...)` 那一行没被改动。

- [ ] **Step 8：跑一遍全仓**

Run: `flutter test`
Expected: PASS（5b-1 收尾时是 510 通过 + 3 跳过；本任务之后条数会变多）

- [ ] **Step 9：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 9b：像素变了 —— 重新生成 golden**

工具栏上多了一个图标，**三张** golden 都会不同 —— 不只是 `editor_panel.png`：`main_window_light.png` 与 `main_window_dark.png` 里也含着这条工具栏（实测三张各差 226 个像素，`device_list_panel.png` / `output_panel.png` 没动）。

**现在就跟上**，别留到收尾 —— 一张过期的 golden 比没有 golden 更坏：它是绿的，而它绿的原因是没人跑过它（`WCT_GOLDEN` 没设时那几条是跳过的）。

先不加 `--update-goldens` 跑一遍，**看清单**到底哪几张飘了（比盲更新安全：盲更新会把"本来该红"的一并吞掉）：

Run: `WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart`
Expected: FAIL，报出上面那三张。

再更新：

Run: `WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart --update-goldens`
Expected: PASS，且 `git status` 里那三张 `M`。

**开图看一眼** `test/ui/golden/editor_panel.png`（360×520）确认工具栏依次是「连接 / 断开 / 发送 / **命令库**（`Icons.menu_book`）/ 进度文字」，且行号栏、正文、间距都没被挤歪。顺手删掉失败那次留下的 `test/ui/failures/` 碎屑。

- [ ] **Step 10：提交**

```bash
git add lib/state/providers.dart lib/ui/panels/snippet_drawer.dart lib/ui/panels/editor_panel.dart lib/ui/main_window.dart test/ui/snippet_drawer_test.dart test/ui/golden/editor_panel.png test/ui/golden/main_window_light.png test/ui/golden/main_window_dark.png
git commit -m "feat(ui): 命令库抽屉（FR-S-01…04）

抽屉挂在主窗口的 endDrawer 上；双击插入走编辑区的 insertAtCursor。
片段随设备持久化，所以增删改都经 devicesProvider.update。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 4：设备编辑对话框（FR-D-01…05、11、12；NFR-S-02；FR-G-03）

**为什么做：** 这是整个 5b-2 最要紧的一块。今天加设备唯一的入口是 AppBar 上那个 `＋`，而它弹的是「设备编辑对话框将在 5b-2 提供」—— **应用因此是一个死胡同**：空的 `devices.json` 下界面上只有「请先添加一台设备」，而没有任何办法添加一台。

**Files:**
- Create: `lib/ui/dialogs/device_edit_dialog.dart`
- Test: `test/ui/device_edit_dialog_test.dart`（新建）
- Test: `test/ui/ui_harness.dart`（加 `pumpDialogHost`）

**先把测试脚手架补上。** `showDialog` 不能在 `build` 里调，所以每个对话框用例都得先有一个按钮。

- [ ] **Step 1：给测试脚手架加 `pumpDialogHost`（外加两个通用件）**

在 `test/ui/ui_harness.dart` 的 `settleDisk` **之后**追加**三个**函数。前两个不是
设备对话框独有的，别抄进用例文件里：

- `drainCommandTimeout` —— 见地基第 3 条：用例结束时会话还连着就必须收尾推过那个
  10s 命令超时定时器，否则红在断言之外（Task 5 补进来的，用到就调）；
- `useTallSurface` —— 默认测试窗口只有 800×600，装不下任何一张长对话框；
- `pumpUntilSnackBar` —— 有些 SnackBar 要等真 I/O，`settleDisk` 的固定轮数不够。

两者都会在 Task 5/6/7/9 里再用到（那几张对话框同样经 `pumpDialogHost` 打开）。

```dart
/// 装一个"点一下就开对话框"的宿主。
///
/// `showDialog` 不能在 `build` 里调 —— 它要一次用户动作。所以每个对话框用例
/// 都得先有这么一个按钮；放在这里省得十来条用例各写一遍 `Builder`。
///
/// [open] 里那一下就由按钮的 `onPressed` 挂着（返回的 Future 没人 await，
/// 这正是 `showDialog` 的用法），用例只需 `tap` + `pumpAndSettle`。
Future<void> pumpDialogHost(
  WidgetTester tester, {
  required Directory root,
  required String buttonLabel,
  required Future<void> Function(BuildContext context) open,
  List<DeviceProfile> devices = const [],
  AppSettings settings = const AppSettings(),
  FakeSessionFactory? factory,
  List<Override> extra = const [],
}) => pumpUi(
  tester,
  root: root,
  devices: devices,
  settings: settings,
  factory: factory,
  extra: extra,
  child: Builder(
    builder: (context) => Center(
      child: ElevatedButton(
        onPressed: () => open(context),
        child: Text(buttonLabel),
      ),
    ),
  ),
);
```

```dart
/// 把测试窗口调高到装得下整个对话框。
///
/// **默认的 800×600 装不下**（这是实测设备编辑对话框的数字）：对话框内容
/// 798 逻辑像素高、视口只有 384，折在窗口外的控件 `tap` 只会空点一下 ——
/// 实测开关在 y=866、行尾符下拉在 y=634，都在 600 之外。
///
/// **`ensureVisible` 救不了这个**：它也只把内容滚到 `pixels=322`（上限
/// `maxScrollExtent` 是 414），开关仍在 y=516–572，还是落在视口下沿 480 之外
/// —— 因为那已经是内容最后一项，没有更多东西可滚了。
///
/// 所以凡是**需要点到**对话框里靠下那几个控件的用例，开头先调这一下。
/// 只是断言（不点）的用例不必调。
Future<void> useTallSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// 等到 SnackBar 真的弹出来（最多 [rounds] 轮），动画走完再返回。
///
/// **不能只靠 `settleDisk` / `pumpAndSettle`。** 举断开那条路：
/// `_disconnect` → `await …disconnect()` → `_endLog()` → `_flush(force: true)`，
/// 里面除了 `stat` / `create` / `writeAsString(flush: true)`，还有
/// `restrictToOwner` 的 `Process.run('chmod', …)` —— **起一个真进程**。
/// 假时钟推不动这些真 I/O，而 `settleDisk` 的轮数是写死的
/// （12 × 5ms ≈ 60ms 真实时间），够不够全看机器当下忙不忙：实测同一份代码，
/// 多一句 `debugPrint` 就从红变绿。所以这里按条件等，出现即走。
///
/// **状态断言不能代替它**：`ConnectionManager` 的新状态是经 `onStatus` 回调
/// 推进 provider 的，不等 `_disconnect` 里那个 await —— 实测状态已经是
/// `disconnected` 时 SnackBar 还一个都没有。两条都要断。
Future<void> pumpUntilSnackBar(WidgetTester tester, {int rounds = 400}) async {
  for (var i = 0; i < rounds; i++) {
    if (find.byType(SnackBar).evaluate().isNotEmpty) break;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pumpAndSettle();
}
```

- [ ] **Step 2：写失败的测试**

新建 `test/ui/device_edit_dialog_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_manager.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/dialogs/device_edit_dialog.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_devdlg_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.text('打开')));

  DeviceProfile existing() => const DeviceProfile(
    id: 'd1',
    name: '核心交换机',
    protocol: DeviceProtocol.ssh,
    host: '10.0.0.1',
    port: 22,
    username: 'admin',
    password: 'secret',
  );

  Future<void> open(
    WidgetTester tester, {
    DeviceProfile? device,
    List<DeviceProfile> devices = const [],
    FakeSessionFactory? factory,
  }) async {
    await pumpDialogHost(
      tester,
      root: root,
      buttonLabel: '打开',
      devices: devices,
      factory: factory,
      open: (context) => DeviceEditDialog.show(context, existing: device),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  String fieldOf(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

  Future<void> fill(WidgetTester tester, String key, String text) =>
      tester.enterText(find.byKey(ValueKey(key)), text);

  Future<void> chooseProtocol(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const ValueKey('device-protocol')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  DeviceProfile stored(WidgetTester tester) =>
      containerOf(tester).read(devicesProvider).single;

  testWidgets('NFR-S-02：明文存储的警告就在对话框里', (tester) async {
    await open(tester);

    // **不能写成 `find.textContaining('明文')`。** 对话框里有**两个** Text 含
    // 「明文」：这条警告，和密码输入框的标签「密码（明文保存）」。本机
    // flutter 3.44.4 实测（起一个只有这两样东西的 scratch 用例跑出来的）：
    //   Expected: exactly one matching candidate
    //     Actual: Found 2 widgets with text containing 明文
    // 所以断言要挑那句独特的话，两处各断一次。
    expect(find.textContaining('明文保存在 devices.json'), findsOneWidget);
    expect(find.text('密码（明文保存）'), findsOneWidget);
  });

  testWidgets('新增：填完保存，设备进了列表（FR-D-01/FR-D-02）', (tester) async {
    await open(tester);

    await fill(tester, 'device-name', '边界防火墙');
    await fill(tester, 'device-host', '10.0.0.2');
    await fill(tester, 'device-username', 'admin');
    await fill(tester, 'device-password', 'p@ss');
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    final device = stored(tester);
    expect(device.name, '边界防火墙');
    expect(device.host, '10.0.0.2');
    expect(device.port, 22, reason: 'FR-D-03：SSH 默认端口 22');
    expect(device.password, 'p@ss');
    expect(device.id, isNotEmpty);
  });

  testWidgets('取消：什么都不写（FR-D-02）', (tester) async {
    await open(tester);

    await fill(tester, 'device-name', '写了也不该存');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await settleDisk(tester);

    expect(containerOf(tester).read(devicesProvider), isEmpty);
    expect(File('${root.path}/devices.json').existsSync(), isFalse);
  });

  testWidgets('重名被挡下，且一条都不写盘（FR-D-04）', (tester) async {
    await open(tester, devices: [existing()]);

    await fill(tester, 'device-name', '核心交换机');
    await fill(tester, 'device-host', '10.0.0.9');
    await fill(tester, 'device-username', 'admin');
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(find.textContaining('已有一台设备叫'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget, reason: '没保存成功，对话框不该关');
    expect(containerOf(tester).read(devicesProvider), hasLength(1));
  });

  testWidgets('编辑自己时重名检查把自己排除在外（FR-D-05）', (tester) async {
    await open(tester, devices: [existing()], device: existing());

    // 只改主机，名字原样不动 —— 这时"名字已存在"指的就是它自己。
    await fill(tester, 'device-host', '10.0.0.99');
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(stored(tester).host, '10.0.0.99');
    expect(stored(tester).id, 'd1', reason: 'id 是身份，编辑不改它');
  });

  testWidgets('端口不是 1..65535 的整数时挡下（FR-D-03）', (tester) async {
    await open(tester);
    await fill(tester, 'device-name', 'A');
    await fill(tester, 'device-host', 'h');
    await fill(tester, 'device-username', 'u');

    for (final bad in ['0', '65536', 'abc', '']) {
      await fill(tester, 'device-port', bad);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('端口必须是'),
        findsOneWidget,
        reason: '「$bad」应当被挡下',
      );
    }
    expect(containerOf(tester).read(devicesProvider), isEmpty);
  });

  testWidgets('切换协议时端口跟着换成默认端口（FR-D-03）', (tester) async {
    await open(tester);
    expect(fieldOf(tester, 'device-port'), '22');

    await chooseProtocol(tester, 'telnet');
    expect(fieldOf(tester, 'device-port'), '23');

    await chooseProtocol(tester, 'ssh');
    expect(fieldOf(tester, 'device-port'), '22');
  });

  testWidgets('用户自己填过端口之后，切协议不再改它（FR-D-03 的边界）', (tester) async {
    await open(tester);
    await fill(tester, 'device-port', '2222');

    await chooseProtocol(tester, 'telnet');

    expect(
      fieldOf(tester, 'device-port'),
      '2222',
      reason: '2222 是用户的选择，不该被协议默认值顶掉',
    );
  });

  testWidgets('编辑已有设备时，盘上那个端口算"用户填过"', (tester) async {
    await open(
      tester,
      device: existing().copyWith(port: 2222),
      devices: [existing().copyWith(port: 2222)],
    );
    expect(fieldOf(tester, 'device-port'), '2222');

    await chooseProtocol(tester, 'telnet');

    expect(fieldOf(tester, 'device-port'), '2222');
  });

  testWidgets('提示符正则编译不了时挡下（FR-G-03）', (tester) async {
    await open(tester);
    await fill(tester, 'device-name', 'A');
    await fill(tester, 'device-host', 'h');
    await fill(tester, 'device-username', 'u');
    await fill(tester, 'device-prompt-regex', '[unclosed');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('提示符正则无法编译'), findsOneWidget);
    expect(containerOf(tester).read(devicesProvider), isEmpty);
  });

  testWidgets('清空密码存下来的是 null 而不是空串（`_unset` 的语义）', (tester) async {
    await open(tester, devices: [existing()], device: existing());

    await fill(tester, 'device-password', '');
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(
      stored(tester).password,
      isNull,
      reason: '空串会让「不启用密码认证」这条路径变成"用一个空密码去认证"',
    );
  });

  testWidgets('「登录后执行」按行切、丢掉空行（FR-D-11）', (tester) async {
    await open(tester);
    await fill(tester, 'device-name', 'A');
    await fill(tester, 'device-host', 'h');
    await fill(tester, 'device-username', 'u');
    await fill(tester, 'device-post-login', 'enable\n\n  \nterminal length 0');

    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(stored(tester).postLoginCommands, [
      'enable',
      'terminal length 0',
    ]);
  });

  testWidgets('「启动时自动连接」存得下来（FR-D-12）', (tester) async {
    // 开关在对话框最下面，默认 800×600 的窗口里点不到 —— 见 `useTallSurface`。
    await useTallSurface(tester);
    await open(tester);
    await fill(tester, 'device-name', 'A');
    await fill(tester, 'device-host', 'h');
    await fill(tester, 'device-username', 'u');

    await tester.tap(find.byKey(const ValueKey('device-autoconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(stored(tester).autoConnect, isTrue);
  });

  testWidgets('新增时没有「断开」按钮（FR-C-05 只对已存在的设备）', (tester) async {
    await open(tester);

    expect(find.text('断开'), findsNothing);
  });

  testWidgets('编辑已有设备时可以就地断开（FR-C-05）', (tester) async {
    final factory = FakeSessionFactory();
    await open(tester, device: existing(), devices: [existing()], factory: factory);

    containerOf(tester).read(sessionProvider('d1').notifier).connect();
    await tester.pumpAndSettle();
    expect(
      containerOf(tester).read(sessionProvider('d1')).state,
      DeviceConnectionState.connected,
    );

    await tester.tap(find.text('断开'));
    // **`pumpAndSettle` / `settleDisk` 在这里都不够**：断开要落盘，路上还有
    // `restrictToOwner` 起的 chmod 真进程。按条件等 SnackBar，见它的文档。
    await pumpUntilSnackBar(tester);

    // 状态与 SnackBar **两条都要断**：实测状态先到、SnackBar 后到，而状态是
    // 经 `onStatus` 回调推进的，不等 `_disconnect` 那个 await —— 只断状态的话，
    // 就算 SnackBar 永远不出现，用例也是绿的。
    expect(
      containerOf(tester).read(sessionProvider('d1')).state,
      DeviceConnectionState.disconnected,
    );
    expect(find.textContaining('已断开'), findsOneWidget);
  });

  testWidgets('行尾符是可选的两种（FR-G-03）', (tester) async {
    // 行尾符下拉也在折叠线以下，同上。
    await useTallSurface(tester);
    await open(tester);
    await fill(tester, 'device-name', 'A');
    await fill(tester, 'device-host', 'h');
    await fill(tester, 'device-username', 'u');

    await tester.tap(find.byKey(const ValueKey('device-line-ending')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CRLF (\\r\\n)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await settleDisk(tester);

    expect(stored(tester).lineEnding, '\r\n');
  });
}
```

- [ ] **Step 3：跑测试，确认它红**

Run: `flutter test test/ui/device_edit_dialog_test.dart`
Expected: FAIL —— `Couldn't find constructor 'DeviceEditDialog'` 之类的编译错误。

- [ ] **Step 4：实现对话框**

新建 `lib/ui/dialogs/device_edit_dialog.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/device_store.dart';
import '../../models/device_profile.dart';
import '../../state/providers.dart';

/// 设备编辑对话框（FR-D-01…05、11、12）。
///
/// 三个出口：
/// - **保存**（FR-D-02/03）：校验通过就写 `devicesProvider`；
/// - **取消**（FR-D-02）：什么都不写；
/// - **断开**（FR-C-05）：只在编辑一台**已存在**的设备时出现。它只断开、
///   不改任何字段 —— 它的用处是"参数写错了想重来"，不是"改完再断开"
///   （后者由 Task 5 的"改了连接参数就断开"负责）。
class DeviceEditDialog extends ConsumerStatefulWidget {
  const DeviceEditDialog({super.key, this.existing});

  /// null = 新增（FR-D-01）。
  final DeviceProfile? existing;

  static Future<void> show(BuildContext context, {DeviceProfile? existing}) =>
      showDialog<void>(
        context: context,
        builder: (_) => DeviceEditDialog(existing: existing),
      );

  @override
  ConsumerState<DeviceEditDialog> createState() => _DeviceEditDialogState();
}

class _DeviceEditDialogState extends ConsumerState<DeviceEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _privateKeyPath;
  late final TextEditingController _promptRegex;
  late final TextEditingController _postLogin;

  late DeviceProtocol _protocol;
  late String _lineEnding;
  late bool _autoConnect;

  /// 端口是不是**用户自己填过**（FR-D-03 的边界）。
  ///
  /// "切协议就换成该协议的默认端口"这条只在用户没指定过端口时才该生效 ——
  /// 一台跑在 2222 的 SSH 设备被切到 telnet 又切回来，端口不该被悄悄改成 22。
  ///
  /// 判断用显式的"动过没有"，而不是"`_port.text` 是否等于另一个协议的默认
  /// 端口"：后者会把一台**本来就配在 23 上**的设备误判成"没动过"。
  bool _portTouched = false;

  /// 程序自己在改端口（跟协议走）。此时不要把"用户动过"标上 ——
  /// 不挡这一下的话，第一次切协议就会把 `_portTouched` 置真，
  /// 第二次切协议端口就不跟着走了。
  bool _settingPortProgrammatically = false;

  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _protocol = existing?.protocol ?? DeviceProtocol.ssh;
    _lineEnding = existing?.lineEnding ?? '\n';
    _autoConnect = existing?.autoConnect ?? false;

    _name = TextEditingController(text: existing?.name ?? '');
    _host = TextEditingController(text: existing?.host ?? '');
    _port = TextEditingController(
      text: '${existing?.port ?? _protocol.defaultPort}',
    );
    _username = TextEditingController(text: existing?.username ?? '');
    _password = TextEditingController(text: existing?.password ?? '');
    _privateKeyPath = TextEditingController(
      text: existing?.privateKeyPath ?? '',
    );
    _promptRegex = TextEditingController(text: existing?.promptRegex ?? '');
    _postLogin = TextEditingController(
      text: (existing?.postLoginCommands ?? const []).join('\n'),
    );

    // 新增时端口不算"填过"：那时它是 FR-D-03 给的默认值，切协议就该跟着换。
    // 编辑一台已有的设备则相反 —— 盘上那个端口是用户的选择。
    _portTouched = existing != null;
    // **必须在上面的赋值之后**，否则 `_port.text` 那一次也会把标记置真。
    _port.addListener(_markPortTouched);
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _host,
      _port,
      _username,
      _password,
      _privateKeyPath,
      _promptRegex,
      _postLogin,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _markPortTouched() {
    if (_settingPortProgrammatically) return;
    _portTouched = true;
  }

  void _setPortToDefault(DeviceProtocol protocol) {
    _settingPortProgrammatically = true;
    _port.text = '${protocol.defaultPort}';
    _settingPortProgrammatically = false;
  }

  static String? _emptyToNull(String raw) {
    final value = raw.trim();
    return value.isEmpty ? null : value;
  }

  /// 保存。校验**全部在写盘之前**，任何一条不过就原地报错、什么都不写。
  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _fail('设备名不能为空');
      return;
    }
    final host = _host.text.trim();
    if (host.isEmpty) {
      _fail('主机地址不能为空');
      return;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _fail('端口必须是 1 到 65535 之间的整数');
      return;
    }
    if (_username.text.trim().isEmpty) {
      _fail('用户名不能为空');
      return;
    }

    // FR-D-04：设备名唯一。**口径与 `DeviceStore.save` 一致**（精确匹配、
    // 区分大小写）—— 两边口径不同的表现是"对话框说没问题，保存时却抛重名"。
    // store 那道校验仍然留着当兜底（见下面的 catch）。
    final self = widget.existing?.id;
    final clash = ref
        .read(devicesProvider)
        .any((d) => d.id != self && d.name == name);
    if (clash) {
      _fail('已有一台设备叫「$name」');
      return;
    }

    final promptRegex = _promptRegex.text.trim();
    if (promptRegex.isNotEmpty) {
      try {
        RegExp(promptRegex);
      } on FormatException catch (error) {
        // 坏正则不会当场出事 —— 它会让**提示符永远匹配不上**，表现是每条命令
        // 都跑满 `commandTimeout`（FR-E-12 的超时）。在这里挡住比在设备上发现好。
        _fail('提示符正则无法编译：${error.message}');
        return;
      }
    }

    final draft = DeviceProfile(
      // 新增时这个 id 会被 `add` 丢掉（id 是身份，见它的文档）。传一个有形状
      // 的值而不是空串，是为了万一 `add` 哪天不再换 id，也不至于留下空 id。
      id: self ?? newDeviceId(),
      name: name,
      protocol: _protocol,
      host: host,
      port: port,
      username: _username.text.trim(),
      // **空串要变成 null**（`_unset` 的文档）：null 是有语义的值 ——
      // "不启用密码认证"。留一个空串进去，认证那条路会拿空密码去试。
      password: _emptyToNull(_password.text),
      privateKeyPath: _emptyToNull(_privateKeyPath.text),
      lineEnding: _lineEnding,
      promptRegex: promptRegex.isEmpty ? null : promptRegex,
      postLoginCommands: _postLogin.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(growable: false),
      autoConnect: _autoConnect,
      // **片段只在命令库里改**，对话框不碰它。带上原值是为了不让 update 把它抹掉。
      snippets: widget.existing?.snippets ?? const [],
      // 同理，而且这一条更要紧：这一版的界面里根本没有跳板机这一项（整条链路
      // 已在别处砍掉），但 `jumpHostIds` 是**会持久化的字段**，在构造函数里
      // 默认 `const []`。不带上原值的话，编辑任何一台设备都会把盘上那条链
      // **静默抹成空** —— 对话框不会提示，用户也不会知道。
      jumpHostIds: widget.existing?.jumpHostIds ?? const [],
    );

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (widget.existing == null) {
        await ref.read(devicesProvider.notifier).add(draft);
      } else {
        await ref.read(devicesProvider.notifier).update(draft);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 重名异常带可直接展示的 `message`，别把 `toString()` 摆给用户
        // （`DuplicateDeviceNameError` 的文档点名了这件事）。
        _error = error is DuplicateDeviceNameError
            ? error.message
            : '保存失败：$error';
      });
      return;
    }

    if (mounted) Navigator.of(context).pop();
  }

  void _fail(String message) => setState(() => _error = message);

  Future<void> _disconnect() async {
    final existing = widget.existing;
    if (existing == null) return;
    await ref.read(sessionProvider(existing.id).notifier).disconnect();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已断开，改动在下次连接时生效')));
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return AlertDialog(
      title: Text(existing == null ? '添加设备' : '编辑设备'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // NFR-S-02：**必须告诉用户凭据是明文存的。** V1 有意接受这一点
              // （NFR-S-01），但用户有权知道 —— 否则他可能在这里填一个别处
              // 也在用的密码，而那个密码就躺在 devices.json 里。
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '提示：设备凭据以明文保存在 devices.json 中，'
                  '任何能读到该文件的人都能看到这里填的密码。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('device-name'),
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: '显示名称'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<DeviceProtocol>(
                key: const ValueKey('device-protocol'),
                initialValue: _protocol,
                decoration: const InputDecoration(labelText: '协议'),
                items: [
                  for (final p in DeviceProtocol.values)
                    DropdownMenuItem(value: p, child: Text(p.name)),
                ],
                onChanged: (next) {
                  if (next == null) return;
                  setState(() {
                    _protocol = next;
                    // FR-D-03：没自己指定过端口时，跟着协议换成默认端口。
                    if (!_portTouched) _setPortToDefault(next);
                  });
                },
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-host'),
                controller: _host,
                decoration: const InputDecoration(labelText: '主机地址'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-port'),
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '端口'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-username'),
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-password'),
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码（明文保存）',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-key-path'),
                controller: _privateKeyPath,
                decoration: const InputDecoration(
                  labelText: '私钥文件路径（可选，填了就用密钥认证）',
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const ValueKey('device-line-ending'),
                initialValue: _lineEnding,
                decoration: const InputDecoration(labelText: '行尾符'),
                items: const [
                  DropdownMenuItem(value: '\n', child: Text('LF (\\n)')),
                  DropdownMenuItem(
                    value: '\r\n',
                    child: Text('CRLF (\\r\\n)'),
                  ),
                ],
                onChanged: (next) {
                  if (next == null) return;
                  setState(() => _lineEnding = next);
                },
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-prompt-regex'),
                controller: _promptRegex,
                decoration: const InputDecoration(
                  labelText: '提示符正则（可选，留空用全局默认）',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-post-login'),
                controller: _postLogin,
                maxLines: 3,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: '登录后执行（一行一条，FR-D-11）',
                  border: OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                key: const ValueKey('device-autoconnect'),
                contentPadding: EdgeInsets.zero,
                title: const Text('启动时自动连接'),
                value: _autoConnect,
                onChanged: (next) => setState(() => _autoConnect = next),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (existing != null)
          TextButton(
            onPressed: _busy ? null : _disconnect,
            child: const Text('断开'),
          ),
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
```

- [ ] **Step 5：跑测试，确认全绿**

Run: `flutter test test/ui/device_edit_dialog_test.dart`
Expected: PASS（16 条）

三条容易红的，逐条说明：

1. `切换协议时端口跟着换成默认端口` —— 若第二次切回 ssh 时端口停在 23，说明 `_settingPortProgrammatically` 那道闸没生效。
2. `行尾符是可选的两种` —— `find.text('CRLF (\\r\\n)')` 在 Dart 源码里写的是**两个字符** `\` `r`，菜单项里渲染的也是这两个字符（`Text('CRLF (\\r\\n)')`）。若红在找不到，先确认两边转义一致。
3. `编辑已有设备时可以就地断开` —— `find.textContaining('已断开')` 若找不到，检查 SnackBar 是不是被对话框的 barrier 挡住（`find` 不看遮挡，所以更可能是 `_disconnect` 没被调到）。

- [ ] **Step 6：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 7：提交**

```bash
git add lib/ui/dialogs/device_edit_dialog.dart test/ui/device_edit_dialog_test.dart test/ui/ui_harness.dart
git commit -m "feat(ui): 设备编辑对话框（FR-D-01…05、11、12；NFR-S-02）

含明文凭据警告、端口随协议走、重名与端口/正则的本地校验、就地断开。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 5：改了连接参数就断开（决策①）

**为什么做：** 保存一台已连接设备的连接参数之后，那条活着的会话用的还是**旧主机 / 旧凭据**，而界面上的设备行看起来已经"改好了" —— 用户以为在跟新设备说话。这个决策是用户在 5b-2 立项时拍板的：**改连接参数就断开**，只改显示字段则不动会话。

**Files:**
- Modify: `lib/ui/dialogs/device_edit_dialog.dart`
- Test: `test/ui/device_params_change_test.dart`（新建）

**口径（计划写死，实施时不要再改）：**

| 分类 | 字段 |
|---|---|
| **显示字段**（改了**不断开**） | `name`、`autoConnect`、`snippets` |
| **连接参数**（改了**断开**） | 其余全部：`protocol`、`host`、`port`、`username`、`password`、`privateKeyPath`、`lineEnding`、`promptRegex`、`postLoginCommands` |

⚠ **这是一份比用户当时口头列的更宽的口径。** 用户的原话是"改连接参数就断开"，讨论时举的例子是主机/端口/凭据；这里把 `lineEnding`、`promptRegex`、`postLoginCommands` **也算进连接参数** —— 理由：`lineEnding` 和 `promptRegex` 是**每条命令都要用**的（改了它们，活着的那个 dispatcher 里还是旧值），`postLoginCommands` 是登录时下发的（改了它必须重连才会执行）。**把显示字段写成白名单、其余一律算连接参数，是为了漏掉一个新字段时结果是"多断一次线"（用户重连即可），而不是"改了参数还连着旧会话"。**

- [ ] **Step 1：写失败的测试**

新建 `test/ui/device_params_change_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_manager.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/dialogs/device_edit_dialog.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_params_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  DeviceProfile base() => const DeviceProfile(
    id: 'd1',
    name: '核心交换机',
    protocol: DeviceProtocol.ssh,
    host: '10.0.0.1',
    port: 22,
    username: 'admin',
    postLoginCommands: ['enable'],
  );

  group('connectionParamsDiffer（字段分类的穷举）', () {
    test('显示字段不算连接参数', () {
      final before = base();

      expect(connectionParamsDiffer(before, before.copyWith(name: '改名')), isFalse);
      expect(
        connectionParamsDiffer(before, before.copyWith(autoConnect: true)),
        isFalse,
      );
      expect(
        connectionParamsDiffer(
          before,
          before.copyWith(
            snippets: const [Snippet(id: 's1', name: 'n', content: 'c')],
          ),
        ),
        isFalse,
      );
    });

    test('每一个连接参数字段改了都算', () {
      final before = base();
      final changed = <String, DeviceProfile>{
        'protocol': before.copyWith(protocol: DeviceProtocol.telnet),
        'host': before.copyWith(host: '10.0.0.2'),
        'port': before.copyWith(port: 2222),
        'username': before.copyWith(username: 'root'),
        'password': before.copyWith(password: 'x'),
        'privateKeyPath': before.copyWith(privateKeyPath: '/tmp/k'),
        'lineEnding': before.copyWith(lineEnding: '\r\n'),
        'promptRegex': before.copyWith(promptRegex: r'[>#]\s*$'),
        'postLoginCommands': before.copyWith(postLoginCommands: ['enable', 'conf t']),
      };

      for (final entry in changed.entries) {
        expect(
          connectionParamsDiffer(before, entry.value),
          isTrue,
          reason: '${entry.key} 是连接参数，改了就该断开',
        );
      }
    });

    test('同内容的新列表实例算相同（list 不按 identity 比）', () {
      // **两个 list 必须真的是两个实例。** 初稿两边都写 `const []`，而 Dart 会把
      // 它们**规范化成同一个对象** —— 那样 `a == b` 靠 identity 就成立了，这条
      // 用例在**没有** `_sameJsonValue` 那份列表逻辑时照样绿（和 Task 1 的 const
      // 规范化是同一类：断言在测空气）。`List.of` 保证拿到新实例。
      final before = base().copyWith(
        postLoginCommands: List<String>.of(const ['enable']),
      );
      final after = base().copyWith(
        postLoginCommands: List<String>.of(const ['enable']),
      );

      expect(
        identical(before.postLoginCommands, after.postLoginCommands),
        isFalse,
        reason: '前提：两个不同的列表实例',
      );
      expect(connectionParamsDiffer(before, after), isFalse);
      expect(
        connectionParamsDiffer(
          before,
          before.copyWith(postLoginCommands: ['other']),
        ),
        isTrue,
      );
    });
  });

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.text('打开')));

  DeviceConnectionState stateOf(WidgetTester tester) =>
      containerOf(tester).read(sessionProvider('d1')).state;

  Future<void> openConnected(
    WidgetTester tester, {
    required DeviceProfile device,
  }) async {
    // 对话框内容比默认的 800×600 窗口高，靠下的开关点不到 —— 见 `useTallSurface`。
    // 四条用例都走这个口，所以放在这里。
    await useTallSurface(tester);
    await pumpDialogHost(
      tester,
      root: root,
      buttonLabel: '打开',
      devices: [device],
      factory: FakeSessionFactory(),
      open: (context) => DeviceEditDialog.show(context, existing: device),
    );
    containerOf(tester).read(sessionProvider('d1').notifier).connect();
    // 连接要开日志文件（真 I/O），假时钟推不动 —— 等的是**状态本身**，
    // 不是帧数，也不是某个 Finder（这时对话框还没开）。
    await pumpUntilTrue(
      tester,
      () => stateOf(tester) == DeviceConnectionState.connected,
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(stateOf(tester), DeviceConnectionState.connected, reason: '前置条件');
  }

  Future<void> fill(WidgetTester tester, String key, String text) =>
      tester.enterText(find.byKey(ValueKey(key)), text);

  // `drainCommandTimeout`（把"会话还连着"留下的挂起定时器推过）在
  // `ui_harness.dart` 里 —— 它不是这一个文件的事，凡是有用例让会话保持连接
  // 到结束，都会撞上 `flutter_test` 那条 `!timersPending`。

  testWidgets('改了主机：保存后会话被断开，并提示重连', (tester) async {
    await openConnected(tester, device: base());

    await fill(tester, 'device-host', '10.0.0.2');
    await tester.tap(find.text('保存'));
    // **不能用 `settleDisk`。** 这条路上有两段真 I/O：`update(draft)` 落盘，
    // 然后是 `disconnect()` 收尾（含 `restrictToOwner` 起的 chmod 真进程）。
    // 按条件等 SnackBar，出现即走。
    await pumpUntilSnackBar(tester);

    expect(stateOf(tester), DeviceConnectionState.disconnected);
    expect(find.textContaining('连接参数已改变'), findsOneWidget);
    expect(
      containerOf(tester).read(devicesProvider).single.host,
      '10.0.0.2',
      reason: '断开不影响保存本身',
    );
  });

  testWidgets('改了「登录后执行」：也算连接参数，断开', (tester) async {
    await openConnected(tester, device: base());

    await fill(tester, 'device-post-login', 'enable\nconf t');
    await tester.tap(find.text('保存'));
    // 这条只断状态、不断 SnackBar，但断到的那个状态要等真 I/O 走完
    // （同样不能用 `settleDisk`）。
    await pumpUntilTrue(
      tester,
      () => stateOf(tester) == DeviceConnectionState.disconnected,
    );

    expect(
      stateOf(tester),
      DeviceConnectionState.disconnected,
      reason: '登录后命令要重连才会重新下发（FR-C-08）',
    );
  });

  testWidgets('只改名字：会话不动', (tester) async {
    await openConnected(tester, device: base());

    await fill(tester, 'device-name', '核心交换机 A');
    await tester.tap(find.text('保存'));
    // **这两条"不该断开"的用例要等到对话框真的关掉为止，不能只 `settleDisk`。**
    // `_submit` 是**先 `await update(draft)`、再（若需要）`await disconnect()`、
    // 最后才 `pop()`**，所以"对话框关了"这件事本身就证明了整条保存路径已经跑完
    // —— 包括那个本该发生却没发生的断开。只推 60ms 真实时间的话，万一这条路上
    // 还有没走完的真 I/O，`findsNothing` 与 `connected` 都会在你还没等到的时候
    // 就先绿了（负向断言尤其容易被这种"还没轮到"骗过去）。
    await pumpUntilTrue(tester, () => find.text('保存').evaluate().isEmpty);

    expect(
      stateOf(tester),
      DeviceConnectionState.connected,
      reason: '改名字不该打断一条好好跑着的会话',
    );
    expect(find.textContaining('连接参数已改变'), findsNothing);
    expect(containerOf(tester).read(devicesProvider).single.name, '核心交换机 A');

    // 会话在这里是**故意**还连着的（上面刚断言过），而 `base()` 的
    // `postLoginCommands` 在连接时排进队列、起了一个 10s 命令超时定时器。
    // 不推过它，本用例会红在断言之外。详见 `ui_harness.dart` 的文档。
    await drainCommandTimeout(tester);
  });

  testWidgets('只改「启动时自动连接」：会话不动', (tester) async {
    await openConnected(tester, device: base());

    await tester.tap(find.byKey(const ValueKey('device-autoconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    // 同「只改名字」：等对话框关掉，才算保存路径整条走完。
    await pumpUntilTrue(tester, () => find.text('保存').evaluate().isEmpty);

    expect(stateOf(tester), DeviceConnectionState.connected);
    expect(containerOf(tester).read(devicesProvider).single.autoConnect, isTrue);

    // 同上：会话还连着，收尾要把那个命令超时定时器推过去。
    await drainCommandTimeout(tester);
  });
}
```

- [ ] **Step 2：跑测试，确认它红**

Run: `flutter test test/ui/device_params_change_test.dart`
Expected: FAIL —— 编译错误 `The function 'connectionParamsDiffer' isn't defined`。

- [ ] **Step 3：实现比较函数**

在 `lib/ui/dialogs/device_edit_dialog.dart` 的 **import 之后、`DeviceEditDialog` 之前**加：

```dart
/// 编辑一台设备时，改动**这些**字段不动它的会话（决策①）。
///
/// **写成"显示字段"的白名单、其余一律算连接参数，是为了让漏掉一个新字段的
/// 后果是"多断一次线"（用户重连即可），而不是"改了参数还连着旧会话"** ——
/// 后者的表现是用户以为新参数生效了，而设备上跑的还是旧凭据。
const _displayOnlyFields = {'name', 'autoConnect', 'snippets'};

/// 两台设备的**连接参数**是否不同。
///
/// 比的是逐字段的值，不是 `DeviceProfile` 的相等（它没有 `==`；就算有，
/// `snippets` 也在里面 —— 加一条命令片段不该断线）。
///
/// **列表按内容比，不按 identity。** `List` 不覆写 `==`，直接 `a != b` 会让
/// 两个内容相同的 `postLoginCommands` 判成不同 —— 那样每次保存都会断线一次。
bool connectionParamsDiffer(DeviceProfile before, DeviceProfile after) {
  final a = before.toJson();
  final b = after.toJson();
  for (final key in a.keys) {
    if (_displayOnlyFields.contains(key)) continue;
    if (!_sameJsonValue(a[key], b[key])) return true;
  }
  return false;
}

bool _sameJsonValue(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJsonValue(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
```

- [ ] **Step 4：在保存路径上接上它**

把 `_submit()` 里那段

```dart
    try {
      if (widget.existing == null) {
        await ref.read(devicesProvider.notifier).add(draft);
      } else {
        await ref.read(devicesProvider.notifier).update(draft);
      }
    } catch (error) {
```

换成：

```dart
    // **SnackBar 的 messenger 要在 pop 之前抓。** pop 之后本 widget 的 context
    // 已经不能用了，而 `ScaffoldMessengerState` 活得比对话框长。
    final messenger = ScaffoldMessenger.of(context);
    final existing = widget.existing;
    var disconnected = false;

    try {
      if (existing == null) {
        await ref.read(devicesProvider.notifier).add(draft);
      } else {
        await ref.read(devicesProvider.notifier).update(draft);
        // 决策①：**改了连接参数就断开。** 不断的话，那条活着的会话用的还是
        // 旧主机/旧凭据，而界面上的设备行看起来已经"改好了"——用户以为在跟
        // 新设备说话。只改名字/自动连接/命令库则不动会话。
        if (connectionParamsDiffer(existing, draft)) {
          await ref.read(sessionProvider(existing.id).notifier).disconnect();
          disconnected = true;
        }
      }
    } catch (error) {
```

并把 `catch` 块结束后的收尾改成：

```dart
    if (!mounted) return;
    Navigator.of(context).pop();
    if (disconnected) {
      messenger.showSnackBar(
        const SnackBar(content: Text('连接参数已改变，已断开该设备，请重新连接')),
      );
    }
```

（原来是 `if (mounted) Navigator.of(context).pop();`，删掉它，用上面这四行。）

- [ ] **Step 5：跑测试，确认全绿**

Run: `flutter test test/ui/device_params_change_test.dart`
Expected: PASS（7 条）

- [ ] **Step 6：跑一遍受影响的旧文件**

Run: `flutter test test/ui/device_edit_dialog_test.dart test/ui/main_window_test.dart`
Expected: PASS

- [ ] **Step 7：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 8：提交**

```bash
git add lib/ui/dialogs/device_edit_dialog.dart test/ui/device_params_change_test.dart
git commit -m "feat(ui): 改了连接参数就断开该设备的会话（决策①）

显示字段（name/autoConnect/snippets）白名单，其余一律算连接参数。
列表按内容比，避免每次保存都误判成"变了"。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 6：右键菜单补「连接/断开/编辑」+ `＋` 接真对话框

**为什么做：** spec §7.3 规定设备列表的右键菜单是**四项**（连接 / 断开 / 编辑 / 删除），今天只有「删除」。同时把 `_addDevice` 那个占位（弹「设备编辑对话框将在 5b-2 提供」）换成真对话框 —— 那是这个应用**唯一的**添加入口。

**Files:**
- Modify: `lib/ui/panels/device_list_panel.dart:120-174`
- Modify: `lib/ui/main_window.dart:211-217`
- Test: `test/ui/device_list_panel_test.dart`（追加）
- Test: `test/ui/main_window_test.dart`（追加）

（上面这两个行号按本计划评审时的源码写的；文件后来长大过，**以 grep 到的
`_showMenu` / `_addDevice` 实际位置为准**。`_addDevice` 现在在 211 行。）

- [ ] **Step 1：写失败的测试**

在 `test/ui/device_list_panel_test.dart` **末尾**（`main` 的右花括号之前）追加：

```dart
  testWidgets('右键菜单是四项，顺序为 连接/断开/编辑/删除（§7.3）', (tester) async {
    await pumpPanel(tester);

    await openMenu(tester, '核心交换机');

    expect(find.text('连接'), findsOneWidget);
    expect(find.text('断开'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('已连接时右键的「连接」不可点、「断开」可点（§7.3）', (tester) async {
    final factory = FakeSessionFactory();
    await pumpPanel(tester, factory: factory);
    await tester.tap(find.byTooltip('连接 核心交换机'));
    await tester.pumpAndSettle();

    await openMenu(tester, '核心交换机');

    expect(tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, '连接'),
    ).enabled, isFalse);
    expect(tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, '断开'),
    ).enabled, isTrue);
  });

  testWidgets('右键「编辑」打开设备编辑对话框，且带着那台设备（FR-D-05）', (tester) async {
    await pumpPanel(tester);

    await openMenu(tester, '核心交换机');
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('编辑设备'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('device-host')))
          .controller!
          .text,
      '10.0.0.1',
    );
  });
```

这两个用例要用两个新的辅助函数。**它们依赖 `device_list_panel_test.dart` 里已有的辅助函数 —— 它的实际名字是 `pumpList`**（铺两台设备：`fakeProfile(id: 'd1', name: '核心交换机')` 与 `d2/边界防火墙`，`fakeProfile` 的默认 host 就是 `10.0.0.1`）。上面代码块里写的 `pumpPanel` 按 `pumpList` 调用，**只改名字，别改断言**。

**`import 'package:flutter/gestures.dart';` 不用加** —— 该文件第 3 行已经有了。再加一行是 `duplicate_import`，会打掉「`dart analyze` 干净」这条验收项。

在同一个文件的 `main()` **顶部**（`late Directory root;` 之后）追加：

```dart
  /// 在某个设备行上点右键并把菜单等出来。
  ///
  /// `ListTile` 的右键走 `GestureDetector.onSecondaryTapDown` —— 用
  /// `startGesture(buttons: kSecondaryMouseButton)` 才能触发它，
  /// `tester.tap` 是主键、不会走那条分支。
  Future<void> openMenu(WidgetTester tester, String deviceName) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(deviceName)),
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
  }
```

（`kSecondaryMouseButton` 与文件里已有的 `kSecondaryButton` 是**同一个常量**
—— `events.dart:81` 就是 `const int kSecondaryMouseButton = kSecondaryButton;`
—— 所以两处写法混用没有行为差别，不必"统一"。）

**这一条用例会留着 d1 连着的状态到用例结束，但不会撞上地基第 3 条的挂起定时器**：
`fakeProfile` 的 `postLogin` 默认是 `const []`，而 `ConnectionManager` 只在
`profile.postLoginCommands.isNotEmpty` 时才 `enqueue`（`connection_manager.dart:334`），
所以这里根本没有超时定时器要推。（同文件已有的「连上之后状态点变绿」用例也是这么活的。）

- [ ] **Step 2：跑测试，确认它红**

Run: `flutter test test/ui/device_list_panel_test.dart`
Expected: FAIL —— `Expected: exactly one matching candidate ... Actual: _TextWidgetFinder:<zero widgets with text "连接">`（菜单里只有「删除」）。

- [ ] **Step 3：实现菜单**

把 `lib/ui/panels/device_list_panel.dart` 的 `_showMenu` 从第 120 行起改掉。**`items:` 那段与它后面的删除确认之间**插入三项，并把返回值处理从

```dart
    if (choice != 'delete' || !context.mounted) return;
```

换成

```dart
    if (choice == null || !context.mounted) return;

    if (choice == 'connect') {
      await ref.read(sessionProvider(device.id).notifier).connect();
      return;
    }
    if (choice == 'disconnect') {
      await ref.read(sessionProvider(device.id).notifier).disconnect();
      return;
    }
    if (choice == 'edit') {
      // 编辑对话框自己会处理"该不该断开"（Task 5），这里只管打开它。
      await DeviceEditDialog.show(context, existing: device);
      return;
    }
    if (choice != 'delete') return;
```

`items:` 换成：

```dart
      items: [
        // §7.3 的四项。**不能点的那一项要 `enabled: false` 而不是不显示** ——
        // 菜单项会跳位置的话，用户按肌肉记忆点第二项就会误触。
        PopupMenuItem(
          value: 'connect',
          enabled: !live,
          child: const Text('连接'),
        ),
        PopupMenuItem(
          value: 'disconnect',
          enabled: live,
          child: const Text('断开'),
        ),
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        const PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
```

`_showMenu` 的签名要多收一个 `live`：

```dart
  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position, {
    required bool live,
  }) async {
```

调用点（`build` 里第 79 行）改成：

```dart
      onSecondaryTapDown: (details) =>
          _showMenu(context, ref, details.globalPosition, live: live),
```

文件顶部加 import：

```dart
import '../dialogs/device_edit_dialog.dart';
```

- [ ] **Step 4：把 `＋` 接上真对话框**

在 `lib/ui/main_window.dart` 里把 `_addDevice` 整个方法换成：

```dart
  /// FR-D-01 / Ctrl+N。
  void _addDevice() => DeviceEditDialog.show(context);
```

文件顶部加 import：

```dart
import 'dialogs/device_edit_dialog.dart';
```

- [ ] **Step 5：给 `＋` 补一条用例**

在 `test/ui/main_window_test.dart` 末尾（`main` 的右花括号之前）追加：

```dart
  testWidgets('AppBar 的「添加设备」打开设备编辑对话框（FR-D-01）', (tester) async {
    await pumpWindow(tester);

    await tester.tap(find.byTooltip('添加设备'));
    await tester.pumpAndSettle();

    expect(find.text('添加设备'), findsWidgets, reason: '标题与 tooltip 都会命中');
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('Ctrl+N 走同一条路（§4.8）', (tester) async {
    await pumpWindow(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('保存'), findsOneWidget);
  });
```

`pumpWindow` 是那个文件里已有的辅助函数（铺一台「核心交换机」与一台「边界防火墙」，其中 d1 是 `autoConnect: true`）。**Step 4 之后 `＋` 会打开一个对话框，而不是弹 SnackBar**。

Run: `grep -rn "5b-2" test/ lib/`
Expected: 只剩 `lib/ui/main_window.dart` 里那两行**注释与 SnackBar 文案**，而它们正是 Step 4 要整个删掉的；`test/` 下应该一条都没有。（评审时已核过：现在就没有任何用例断言那句占位文案，所以删掉它不会让别的用例变红。）删完之后再跑一次，Expected: 无输出。

- [ ] **Step 6：跑测试，确认全绿**

Run: `flutter test test/ui/device_list_panel_test.dart test/ui/main_window_test.dart`
Expected: PASS

- [ ] **Step 7：跑一遍全仓**

Run: `flutter test`
Expected: PASS

- [ ] **Step 8：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 9：提交**

```bash
git add lib/ui/panels/device_list_panel.dart lib/ui/main_window.dart test/ui/device_list_panel_test.dart test/ui/main_window_test.dart
git commit -m "feat(ui): 设备右键菜单补连接/断开/编辑（§7.3），＋ 接真对话框（FR-D-01）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 7：导入文件（FR-E-15/16）

**为什么做：** 用户手上有一份从别处抄来的命令清单，今天没有任何办法把它弄进编辑区 —— 只能一条条手打。

**Files:**
- Create: `lib/state/file_reader.dart`
- Create: `lib/ui/dialogs/import_dialog.dart`
- Modify: `lib/ui/panels/editor_panel.dart`（工具栏加「导入文件」+ `_importFile`）
- Test: `test/ui/import_dialog_test.dart`（新建）

**两个设计点，写死在这里：**
1. **零依赖：路径输入框**，不用系统文件选择器（决策④）。
2. **「替换」与「追加」是两个按钮**，不是"先选单选再按确定"。FR-E-15 说的"询问替换还是追加"就是这两个按钮在问 —— 选哪一个本身就是回答。

- [ ] **Step 1：加文件读取的缝**

新建 `lib/state/file_reader.dart`：

```dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 读一个文件的原始字节。
///
/// **做成 provider 是为了可注入。** 「导入文件」（FR-E-15）要读用户磁盘上的
/// 文件，而 widget 测试里没有那个文件；更要紧的是 FR-E-16 那条分支（"不是
/// UTF-8"）—— 测试里换掉本 provider 就能直接喂一段非法字节，不必在临时目录
/// 里造文件再猜它怎么被读。
///
/// 返回 `List<int>` 而不是 `String`：**解码是消费方的事**。这里若先解成字符串，
/// `utf8.decode` 就只剩宽松模式可选，而那正是 FR-E-16 要挡的那件事。
typedef FileBytesReader = Future<List<int>> Function(String path);

final fileReaderProvider = Provider<FileBytesReader>(
  (ref) => (path) => File(path).readAsBytes(),
);
```

- [ ] **Step 2：写失败的测试**

新建 `test/ui/import_dialog_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
// `Override` 不在 `flutter_riverpod.dart` 的主入口里（理由见 `ui_harness.dart`
// 开头那段注释）。`readerOf` 的返回类型用到它，少这一行本文件红在
// `non_type_as_type_argument`。
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/state/file_reader.dart';
import 'package:win_cli_tool/ui/dialogs/import_dialog.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_import_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 让"磁盘上的文件"返回 [bytes]。
  List<Override> readerOf(List<int> bytes) => [
    fileReaderProvider.overrideWithValue((path) async => bytes),
  ];

  Future<void> openDialog(WidgetTester tester, {required List<int> bytes}) async {
    await pumpDialogHost(
      tester,
      root: root,
      buttonLabel: '打开',
      extra: readerOf(bytes),
      open: (context) => ImportDialog.show(context),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> typePath(WidgetTester tester) => tester.enterText(
    find.byKey(const ValueKey('import-path')),
    '/tmp/whatever.txt',
  );

  group('对话框本身', () {
    testWidgets('非 UTF-8 内容被拒，且明确说出来（FR-E-16）', (tester) async {
      // 0xFF 在任何位置都不是合法 UTF-8 的开始字节 —— GBK 文本里到处都是。
      await openDialog(tester, bytes: [0x41, 0xff, 0xfe, 0x42]);

      await typePath(tester);
      await tester.tap(find.text('替换现有内容'));
      await tester.pumpAndSettle();

      expect(find.textContaining('不是 UTF-8'), findsOneWidget);
      expect(find.text('替换现有内容'), findsOneWidget, reason: '没导入成功，对话框不该关');
    });

    testWidgets('读不到文件时给出可读的错误，不是 `FileSystemException` 原文', (tester) async {
      await pumpDialogHost(
        tester,
        root: root,
        buttonLabel: '打开',
        extra: [
          fileReaderProvider.overrideWithValue(
            (path) async => throw const FileSystemException('没有那个文件或目录', '/x'),
          ),
        ],
        open: (context) => ImportDialog.show(context),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      await typePath(tester);
      await tester.tap(find.text('替换现有内容'));
      await tester.pumpAndSettle();

      expect(find.textContaining('读不到这个文件'), findsOneWidget);
    });

    testWidgets('路径是空的时候不发 IO', (tester) async {
      await openDialog(tester, bytes: utf8.encode('x'));

      await tester.tap(find.text('追加到末尾'));
      await tester.pumpAndSettle();

      expect(find.text('请填写文件路径'), findsOneWidget);
    });
  });

  group('接到编辑区上', () {
    Future<TextEditingController> pumpEditor(
      WidgetTester tester, {
      required List<int> bytes,
    }) async {
      await pumpUi(
        tester,
        root: root,
        devices: [fakeProfile(id: 'd1', name: 'A')],
        extra: readerOf(bytes),
        child: const SizedBox(height: 400, child: EditorPanel(deviceId: 'd1')),
      );
      await settleDisk(tester);
      return tester.widget<TextField>(find.byType(TextField)).controller!;
    }

    Future<void> importAs(WidgetTester tester, String label) async {
      await tester.tap(find.byTooltip('导入文件'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('import-path')),
        '/tmp/x.txt',
      );
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('替换：编辑区变成文件内容（FR-E-15）', (tester) async {
      final editor = await pumpEditor(
        tester,
        bytes: utf8.encode('hostname R1\ninterface GE0/0/1\n'),
      );
      editor.value = const TextEditingValue(
        text: '旧内容',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await importAs(tester, '替换现有内容');

      expect(editor.text, 'hostname R1\ninterface GE0/0/1\n');
    });

    testWidgets('追加：原内容还在，接在后面（FR-E-15）', (tester) async {
      final editor = await pumpEditor(tester, bytes: utf8.encode('new'));
      editor.value = const TextEditingValue(
        text: 'old',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await importAs(tester, '追加到末尾');

      expect(editor.text, 'old\nnew');
    });

    testWidgets('追加到空编辑区：不产生开头的空行', (tester) async {
      final editor = await pumpEditor(tester, bytes: utf8.encode('new'));

      await importAs(tester, '追加到末尾');

      expect(editor.text, 'new');
    });

    testWidgets('取消：编辑区一个字都不动', (tester) async {
      final editor = await pumpEditor(tester, bytes: utf8.encode('new'));
      editor.value = const TextEditingValue(
        text: 'old',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('导入文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(editor.text, 'old');
    });
  });
}
```

- [ ] **Step 3：跑测试，确认它红**

Run: `flutter test test/ui/import_dialog_test.dart`
Expected: FAIL —— `Target of URI doesn't exist: 'package:win_cli_tool/ui/dialogs/import_dialog.dart'`。

- [ ] **Step 4：实现对话框**

新建 `lib/ui/dialogs/import_dialog.dart`：

```dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/file_reader.dart';

/// 导入方式（FR-E-15）。
enum ImportMode { replace, append }

/// 一次导入请求：文本 + 用户选的落法。
class ImportRequest {
  const ImportRequest(this.text, this.mode);

  final String text;
  final ImportMode mode;
}

/// 导入文件对话框（FR-E-15/16）。
///
/// **零依赖：路径输入框，不用系统文件选择器**（用户决策④）。加一个
/// `file_picker` / `file_selector` 会把 Linux 侧的 GTK 依赖与打包配置一起带进来，
/// 而这条需求的全部内容是"把磁盘上一个文本文件读成编辑区的内容"。
///
/// **「替换」与「追加」是两个按钮**，不是"先选单选再按确定"：FR-E-15 说的
/// "询问替换还是追加"就是这两个按钮在问，选哪一个本身就是回答 —— 少一步。
class ImportDialog extends ConsumerStatefulWidget {
  const ImportDialog({super.key});

  static Future<ImportRequest?> show(BuildContext context) =>
      showDialog<ImportRequest>(
        context: context,
        builder: (_) => const ImportDialog(),
      );

  @override
  ConsumerState<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<ImportDialog> {
  final _path = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _import(ImportMode mode) async {
    final path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _error = '请填写文件路径');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final List<int> bytes;
    try {
      bytes = await ref.read(fileReaderProvider)(path);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 不把 `FileSystemException.toString()` 直接摆给用户 —— 那串里混着
        // 系统错误号与内部路径，读起来像程序坏了而不是"路径写错了"。
        _error = '读不到这个文件：$error';
      });
      return;
    }

    final String text;
    try {
      // FR-E-16：**必须是 UTF-8。** `utf8.decode` 默认就是严格模式
      // （`allowMalformed: false`）—— 宽松解码会把 GBK 的设备配置静默变成
      // 一串 U+FFFD，而用户看到的是"导入成功"。
      text = utf8.decode(bytes);
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '这个文件不是 UTF-8 编码，无法导入（FR-E-16）';
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(ImportRequest(text, mode));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入文件'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('import-path'),
              controller: _path,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '文件路径',
                helperText: '仅支持 UTF-8 编码的文本文件',
              ),
            ),
            const SizedBox(height: 12),
            const Text('导入的内容怎么放？', style: TextStyle(fontSize: 12)),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _busy ? null : () => _import(ImportMode.replace),
          child: const Text('替换现有内容'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _import(ImportMode.append),
          child: const Text('追加到末尾'),
        ),
      ],
    );
  }
}
```

- [ ] **Step 5：接到编辑区上**

在 `lib/ui/panels/editor_panel.dart` 的 `_toolbar` 里，**Task 3 加的那个「命令库」按钮之后**插入：

```dart
          IconButton(
            tooltip: '导入文件',
            icon: const Icon(Icons.file_open, size: 18),
            onPressed: _importFile,
          ),
```

并在 `insertAtCursor` **之前**加方法：

```dart
  /// FR-E-15：导入一个本地文件到编辑区。
  Future<void> _importFile() async {
    final request = await ImportDialog.show(context);
    if (request == null || !mounted) return;
    // 两个落法都经 `_setText`，所以落盘防抖与行号栏重画都自动接上了。
    switch (request.mode) {
      case ImportMode.replace:
        replaceAllText(request.text);
      case ImportMode.append:
        appendText(request.text);
    }
  }
```

文件顶部加 import：

```dart
import '../dialogs/import_dialog.dart';
```

- [ ] **Step 6：跑测试，确认全绿**

Run: `flutter test test/ui/import_dialog_test.dart`
Expected: PASS（7 条）

- [ ] **Step 7：跑一遍全仓**

Run: `flutter test`
Expected: PASS

- [ ] **Step 8：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 8b：像素又变了 —— 重新生成 golden**

工具栏上再添一个图标（`Icons.file_open`），**又是那三张**（`editor_panel.png` + `main_window_light.png` + `main_window_dark.png`，主窗口那两张里含着这条工具栏）。理由与 Task 3 的 Step 9b 相同：**别让 golden 悄悄过期。**

Run: `WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart --update-goldens`
Expected: PASS，`git status` 里那三张有改动。开图确认多出来的是"打开文件"那个图标。

- [ ] **Step 9：提交**

```bash
git add lib/state/file_reader.dart lib/ui/dialogs/import_dialog.dart lib/ui/panels/editor_panel.dart test/ui/import_dialog_test.dart test/ui/golden/editor_panel.png test/ui/golden/main_window_light.png test/ui/golden/main_window_dark.png
git commit -m "feat(ui): 导入文件（FR-E-15/16）

零依赖的路径输入框 + 可注入的读取缝；严格 UTF-8 解码，非 UTF-8 明确拒绝。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 8：同步到另一台（FR-E-17）

**为什么做：** 同一条命令要在五台交换机上跑，今天是"编辑区里复制一遍、切设备、粘贴、再切回来"。FR-E-17 要的是选中目标设备、选覆盖或追加、写进**目标设备的草稿**。

**Files:**
- Create: `lib/ui/dialogs/sync_dialog.dart`
- Modify: `lib/ui/panels/editor_panel.dart`（工具栏加「同步到另一台」+ `_syncToOther`）
- Test: `test/ui/sync_dialog_test.dart`（新建）

**三个写死的设计点：**

1. **写进的是"草稿"，不是"编辑区"。** FR-E-17 的原话是"追加到**目标设备的草稿**"。目标设备的编辑区此刻**没挂载**（编辑区一次只显示当前那台），所以能写的只有草稿；用户切到那台设备时，`EditorPanel._loadDraft()` 会把草稿灌进编辑区 —— 衔接是天然的。
2. **写必须经 `draftProvider(目标).notifier.save()`，不能直接 `appStores.drafts.write()`。** `draftProvider` 不是 autoDispose，它**缓存着**目标设备上一次读出来的内容；绕过 notifier 直接写盘的话，缓存还是旧的 —— 用户切过去看到的是旧草稿，而盘上是新的。这个 bug 只会在"本次运行里那台设备的草稿被读过一次"之后出现，正好是用户最常走的路径。
3. **要同步的文本由编辑区传进来**（`_text.text`），不是从源草稿读。编辑区里可能压着还没落盘的防抖内容（FR-E-03），从草稿读会漏掉最后那几秒的编辑。

- [ ] **Step 1：写失败的测试**

新建 `test/ui/sync_dialog_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/dialogs/sync_dialog.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_sync_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  final two = [
    fakeProfile(id: 'd1', name: '核心交换机', host: '10.0.0.1'),
    fakeProfile(id: 'd2', name: '边界防火墙', host: '10.0.0.2'),
  ];

  /// 直接读盘上的草稿。**不读 provider** —— 这个用例要验的正是"盘上真的写了"。
  String draftOnDisk(String deviceId) {
    final file = File('${root.path}/drafts/$deviceId.txt');
    return file.existsSync() ? file.readAsStringSync() : '';
  }

  /// 用另一个 `AppStores` 实例预置草稿。
  ///
  /// 能这么写是因为 `DraftStore` 与 `FileHostKeyStore` 一样**不持实例缓存**
  /// （`FileHostKeyStore` 的文档里那段"缓存整个去掉"）。两处都靠这一点。
  Future<void> seedDraft(String deviceId, String text) =>
      AppStores(paths: AppPaths(root)).drafts.write(deviceId, text);

  group('对话框本身', () {
    testWidgets('只有一台设备时说清楚，不给同步（FR-E-17 的边界）', (tester) async {
      await pumpDialogHost(
        tester,
        root: root,
        buttonLabel: '打开',
        devices: [fakeProfile(id: 'd1', name: '核心交换机')],
        open: (context) => SyncDialog.show(
          context,
          sourceDeviceId: 'd1',
          text: 'x',
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.textContaining('没有别的设备'), findsOneWidget);
      expect(find.text('覆盖'), findsNothing);
    });

    testWidgets('目标里不出现源设备自己（FR-E-17）', (tester) async {
      await pumpDialogHost(
        tester,
        root: root,
        buttonLabel: '打开',
        devices: two,
        open: (context) => SyncDialog.show(
          context,
          sourceDeviceId: 'd1',
          text: 'x',
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sync-target')));
      await tester.pumpAndSettle();

      expect(find.text('边界防火墙'), findsWidgets, reason: '下拉里有它');
      expect(
        find.text('核心交换机'),
        findsNothing,
        reason: '自己不在目标候选里 —— 同步给自己没有意义',
      );
    });
  });

  group('接到编辑区上', () {
    Future<TextEditingController> pumpEditor(WidgetTester tester) async {
      await pumpUi(
        tester,
        root: root,
        devices: two,
        child: const SizedBox(height: 400, child: EditorPanel(deviceId: 'd1')),
      );
      await settleDisk(tester);
      return tester.widget<TextField>(find.byType(TextField)).controller!;
    }

    /// 打开对话框，选目标，按 [label] 那个按钮。
    ///
    /// **这里没有 `enterText` 可用** —— `sync-target` 是 `DropdownButton`，
    /// 不是输入框，`tester.enterText` 会因为找不到 `EditableText` 而抛。
    /// 选目标只能"点开、再点那一项"：`find.text('边界防火墙').last` 取的是
    /// **展开菜单里**那一项（`Overlay` 的条目排在对话框路由之后，所以在
    /// 遍历序里靠后；靠前那个是收起状态下按钮自己显示的名字）。
    Future<void> syncAs(WidgetTester tester, String label) async {
      await tester.tap(find.byTooltip('同步到另一台'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sync-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('边界防火墙').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await settleDisk(tester);
    }

    testWidgets('覆盖：目标草稿变成编辑区的内容（FR-E-17）', (tester) async {
      await seedDraft('d2', '旧的目标草稿');
      final editor = await pumpEditor(tester);
      editor.value = const TextEditingValue(
        text: 'hostname R1',
        selection: TextSelection.collapsed(offset: 11),
      );
      await tester.pump();

      await syncAs(tester, '覆盖');

      expect(draftOnDisk('d2'), 'hostname R1');
      expect(find.textContaining('已覆盖到「边界防火墙」'), findsOneWidget);
    });

    testWidgets('追加：目标原有的内容还在（FR-E-17）', (tester) async {
      await seedDraft('d2', '原有命令');
      final editor = await pumpEditor(tester);
      editor.value = const TextEditingValue(
        text: '新命令',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await syncAs(tester, '追加');

      expect(draftOnDisk('d2'), '原有命令\n新命令');
    });

    testWidgets('追加到一个空草稿：不产生开头的空行', (tester) async {
      final editor = await pumpEditor(tester);
      editor.value = const TextEditingValue(
        text: '新命令',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await syncAs(tester, '追加');

      expect(draftOnDisk('d2'), '新命令');
    });

    testWidgets('源设备的草稿一个字都没动', (tester) async {
      await seedDraft('d1', '源的内容');
      final editor = await pumpEditor(tester);
      expect(editor.text, '源的内容', reason: '前置条件：源草稿已经灌进编辑区');

      await syncAs(tester, '覆盖');

      // 编辑区的内容本来就要落回源草稿（FR-E-03），所以这里断言的是
      // **目标的**草稿与源的内容一致，而源的那份没有被同步动作写坏。
      expect(draftOnDisk('d1'), '源的内容');
      expect(draftOnDisk('d2'), '源的内容');
    });

    testWidgets('编辑区是空的：不发同步，给一句提示', (tester) async {
      final editor = await pumpEditor(tester);
      expect(editor.text, isEmpty, reason: '前置条件');

      await tester.tap(find.byTooltip('同步到另一台'));
      await tester.pumpAndSettle();

      expect(find.textContaining('编辑区是空的'), findsOneWidget);
      expect(find.text('覆盖'), findsNothing, reason: '对话框不该开');
    });

    testWidgets('取消：目标草稿一个字都不动', (tester) async {
      await seedDraft('d2', '原有命令');
      final editor = await pumpEditor(tester);
      editor.value = const TextEditingValue(
        text: '新命令',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('同步到另一台'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await settleDisk(tester);

      expect(draftOnDisk('d2'), '原有命令');
    });
  });
}
```

- [ ] **Step 2：跑测试，确认它红**

Run: `flutter test test/ui/sync_dialog_test.dart`
Expected: FAIL —— `Target of URI doesn't exist: 'package:win_cli_tool/ui/dialogs/sync_dialog.dart'`。

- [ ] **Step 3：实现对话框**

新建 `lib/ui/dialogs/sync_dialog.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/draft_store.dart';
import '../../state/providers.dart';

/// 同步方式（FR-E-17：「指定『覆盖』或『追加』」）。
enum SyncMode { overwrite, append }

/// 一次同步的结果：写给了谁、怎么写的。用来拼提示。
class SyncResult {
  const SyncResult(this.targetName, this.mode);

  final String targetName;
  final SyncMode mode;
}

/// 「同步到另一台」对话框（FR-E-17）。
///
/// **它自己完成写入**（而不是把选择返回给调用方）—— 因为"追加"要先读目标
/// 设备现有的草稿，而那是一次异步 IO；让调用方再读一次，两处就要各写一遍
/// `DraftUnreadableException` 的处理。
///
/// 成功时 pop 出 [SyncResult]，取消时 pop 出 null。
class SyncDialog extends ConsumerStatefulWidget {
  const SyncDialog({
    super.key,
    required this.sourceDeviceId,
    required this.text,
  });

  /// 源设备 —— 它**不出现在目标候选里**。
  final String sourceDeviceId;

  /// 要写过去的内容。**由编辑区传进来**（见计划里那个设计点）。
  final String text;

  static Future<SyncResult?> show(
    BuildContext context, {
    required String sourceDeviceId,
    required String text,
  }) => showDialog<SyncResult>(
    context: context,
    builder: (_) => SyncDialog(sourceDeviceId: sourceDeviceId, text: text),
  );

  @override
  ConsumerState<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends ConsumerState<SyncDialog> {
  String? _targetId;
  String? _error;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final targets = ref
        .watch(devicesProvider)
        .where((d) => d.id != widget.sourceDeviceId)
        .toList(growable: false);

    if (targets.isEmpty) {
      return AlertDialog(
        title: const Text('同步到另一台'),
        content: const Text('没有别的设备可以同步 —— 先在设备列表里添加一台。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('好的'),
          ),
        ],
      );
    }

    final selected = targets.any((d) => d.id == _targetId)
        ? _targetId
        : targets.first.id;

    return AlertDialog(
      title: const Text('同步到另一台'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('sync-target'),
              initialValue: selected,
              decoration: const InputDecoration(labelText: '目标设备'),
              items: [
                for (final d in targets)
                  DropdownMenuItem(value: d.id, child: Text(d.name)),
              ],
              onChanged: (next) => setState(() => _targetId = next),
            ),
            const SizedBox(height: 12),
            const Text(
              '写入的是目标设备的草稿 —— 切到那台设备时会在编辑区里看到。',
              style: TextStyle(fontSize: 12),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _busy ? null : () => _run(selected, SyncMode.overwrite),
          child: const Text('覆盖'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _run(selected, SyncMode.append),
          child: const Text('追加'),
        ),
      ],
    );
  }

  Future<void> _run(String targetId, SyncMode mode) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final String existing;
    try {
      // **经 provider 读，不直接读盘。** provider 缓存着这台设备的草稿，
      // 绕过它写盘会让缓存过期（见计划里的设计点 2）。
      existing = await ref.read(draftProvider(targetId).future);
    } on DraftUnreadableException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // **不降级成空串**：那会把用户原有的草稿当成"没有"而覆盖掉。
        _error = '目标设备的草稿无法读取（不是 UTF-8 或读盘失败），为免覆盖已停止同步';
      });
      return;
    }

    final next = switch (mode) {
      SyncMode.overwrite => widget.text,
      SyncMode.append when existing.isEmpty => widget.text,
      SyncMode.append => '$existing${existing.endsWith('\n') ? '' : '\n'}${widget.text}',
    };

    final name = ref
        .read(devicesProvider)
        .firstWhere((d) => d.id == targetId)
        .name;
    try {
      await ref.read(draftProvider(targetId).notifier).save(next);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '同步失败：$error';
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(SyncResult(name, mode));
  }
}
```

- [ ] **Step 4：接到编辑区上**

在 `lib/ui/panels/editor_panel.dart` 的 `_toolbar` 里，**Task 3 加的「命令库」按钮之后、`const Spacer(),` 之前**插入：

```dart
          const SizedBox(width: 8),
          IconButton(
            tooltip: '同步到另一台',
            icon: const Icon(Icons.copy_all, size: 18),
            onPressed: _syncToOther,
          ),
```

并在 `_importFile` 附近加方法：

```dart
  /// FR-E-17：把编辑区当前内容同步给另一台设备的草稿。
  Future<void> _syncToOther() async {
    // **空内容不发同步。** 空文本 + 「覆盖」会把目标设备的草稿清空 ——
    // 那是一个用户几乎不可能想要的破坏性结果，而它在界面上与"同步成功"
    // 长得一模一样。
    if (_text.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('编辑区是空的，没有可同步的内容')),
      );
      return;
    }

    final result = await SyncDialog.show(
      context,
      sourceDeviceId: widget.deviceId,
      // **传编辑区的当前文本，不读源草稿**（设计点 3）。
      text: _text.text,
    );
    if (result == null || !mounted) return;

    final verb = result.mode == SyncMode.overwrite ? '已覆盖到' : '已追加到';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$verb「${result.targetName}」的草稿')),
    );
  }
```

文件顶部加 import：

```dart
import '../dialogs/sync_dialog.dart';
```

- [ ] **Step 5：跑测试，确认全绿**

Run: `flutter test test/ui/sync_dialog_test.dart`
Expected: PASS（9 条）

一条常见红：`覆盖：目标草稿变成编辑区的内容` 若红在 `draftOnDisk('d2')` 还是旧值 —— 多半是 `settleDisk` 的轮数不够（`DraftStore.write` 是先写 `.tmp`、`chmod`、再 rename 三步）。先确认不是逻辑错，再考虑加轮数。

- [ ] **Step 6：跑一遍全仓**

Run: `flutter test`
Expected: PASS

- [ ] **Step 7：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 7b：像素又变了 —— 重新生成 golden**

工具栏上第三个新图标（`Icons.copy_all`）。这是编辑区工具栏最后一次变动，所以**这三张**之后到收尾都不用再动。

Run: `WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart --update-goldens`
Expected: PASS，`git status` 里那三张有改动。开图确认工具栏现在是「连接 / 断开 / 发送 / 命令库 / 导入文件 / 同步到另一台」六个图标。

- [ ] **Step 8：提交**

```bash
git add lib/ui/dialogs/sync_dialog.dart lib/ui/panels/editor_panel.dart test/ui/sync_dialog_test.dart test/ui/golden/editor_panel.png test/ui/golden/main_window_light.png test/ui/golden/main_window_dark.png
git commit -m "feat(ui): 同步到另一台（FR-E-17）

目标设备选择 + 覆盖/追加；写经 draftProvider.save 以免缓存过期；
空编辑区不发同步（覆盖会把目标草稿清空）。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 9：设置对话框（FR-G-01/02、FR-C-13）

**为什么做：** FR-G-01 列的九个设置项今天**一个都改不了** —— `AppSettings` 有全部字段、`SettingsStore` 会持久化（FR-G-02 已成立），但界面上没有入口。而 FR-C-13 明说建连超时是"可在设置中调整"，今天也不可调。

**这一版做九项里能落地的部分，逐项交代：**

| FR-G-01 的项 | 本任务 | 落点 |
|---|---|---|
| 命令执行超时（默认 10s） | ✅ | `commandTimeoutMs` 文本框 |
| 提示符静默去抖（默认 120ms） | ✅ | `promptDebounceMs` 文本框 |
| 全局默认提示符正则 | ✅ | `defaultPromptRegex` 文本框（要能编译） |
| 翻页匹配模式 | ✅ | `morePromptPatterns` 多行文本框（一行一条） |
| 日志开关与目录 | ✅ | `logEnabled` 开关 + `logDir` 文本框（空 = 用默认目录） |
| SSH 主机密钥校验开关 | ✅ | `verifySshHostKey` 开关 |
| 已知主机密钥的查看与逐条清除 | ✅ **在 Task 10** | 同一个对话框里加一段 |
| 主题 | ✅ | `theme` 下拉 |
| 编辑区与输出区的上下分割比例 | ✅ | `editorSplitRatio` 滑杆（0.15–0.85，与拖动时的 clamp 同界） |
| （FR-C-13 的建连超时） | ✅ | `connectTimeoutMs` 文本框 |
| `outputBufferLines` / `deviceListWidth` | ❌ **不做** | 见下 |

**为什么 `outputBufferLines` 与 `deviceListWidth` 不做：** 两者都**不在** FR-G-01 的清单里。`deviceListWidth` 有拖动分隔条这条路（真好用得多），`outputBufferLines` 有 `outputBufferProvider` 的"改了也要下次连接才生效"这条已知取舍 —— 摆进设置里只会让用户以为改完立刻生效。**这是有意的范围裁剪，不是遗漏。**

**Files:**
- Create: `lib/ui/dialogs/settings_dialog.dart`
- Modify: `lib/ui/main_window.dart`（AppBar 加「设置」）
- Test: `test/ui/settings_dialog_test.dart`（新建）
- Test: `test/ui/main_window_test.dart`（追加一条）

**保存语义：一个「保存」按钮，一次写入。** 对话框是模态的（`showDialog` 的 `barrierDismissible` 默认 true，但拖动分隔条在模态屏障后面发生不了），所以它 `initState` 时抓的那份快照不会与别处的改动打架。「取消」= 什么都不写。

- [ ] **Step 1：写失败的测试**

新建 `test/ui/settings_dialog_test.dart`：

```dart
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

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('保存'));
    await settleDisk(tester);
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
    expect(find.text('深色'), findsOneWidget);
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
        find.textContaining('命令执行超时必须是'),
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
```

- [ ] **Step 2：跑测试，确认它红**

Run: `flutter test test/ui/settings_dialog_test.dart`
Expected: FAIL —— `Target of URI doesn't exist: 'package:win_cli_tool/ui/dialogs/settings_dialog.dart'`。

- [ ] **Step 3：实现对话框**

新建 `lib/ui/dialogs/settings_dialog.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_settings.dart';
import '../../state/providers.dart';

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
```

- [ ] **Step 4：给主窗口加「设置」入口**

在 `lib/ui/main_window.dart` 的 `actions:` 里，**「添加设备」之前**插入：

```dart
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings),
                onPressed: () => SettingsDialog.show(context),
              ),
```

（放在 `＋` 前面，`＋` 就还是最右边那一个 —— 它的位置是用户在 5b-1 里已经记住的。）

文件顶部加 import：

```dart
import 'dialogs/settings_dialog.dart';
```

在 `test/ui/main_window_test.dart` 末尾追加：

```dart
  testWidgets('AppBar 的「设置」打开设置对话框（FR-G-01）', (tester) async {
    await pumpWindow(tester);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsWidgets, reason: '标题与 tooltip 都会命中');
    expect(
      find.byKey(const ValueKey('settings-command-timeout')),
      findsOneWidget,
    );
  });
```

- [ ] **Step 5：跑测试，确认全绿**

Run: `flutter test test/ui/settings_dialog_test.dart test/ui/main_window_test.dart`
Expected: PASS

- [ ] **Step 6：像素变了 —— 重新生成 golden**

主窗口的 AppBar 多了一个「设置」按钮，`main_window_light.png` / `main_window_dark.png` **一定**会不同。

Run: `WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart --update-goldens`
Expected: PASS，且 `git status` 里 `test/ui/golden/main_window_light.png` 与 `main_window_dark.png` 有改动。

**然后看一眼新图**（`DISPLAY=:11 xdg-open` 或直接读文件），确认多出来的是那个齿轮，而不是别的什么变了。**golden 的价值全在"人看过一眼"** —— 一条谁都没看过的 golden 只是把当前渲染结果固化了而已。

- [ ] **Step 7：跑一遍全仓**

Run: `flutter test`
Expected: PASS（`WCT_GOLDEN` 没设，golden 那几条仍然跳过）

- [ ] **Step 8：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 9：提交**

```bash
git add lib/ui/dialogs/settings_dialog.dart lib/ui/main_window.dart test/ui/settings_dialog_test.dart test/ui/main_window_test.dart test/ui/golden/main_window_light.png test/ui/golden/main_window_dark.png
git commit -m "feat(ui): 设置对话框（FR-G-01/02、FR-C-13）

九项里做了八项（已知主机密钥区在下一个任务里接上）；outputBufferLines 与
deviceListWidth 不在 FR-G-01 清单里，有意不做。golden 随之重新生成。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 10：设置里的已知主机密钥区（FR-G-01 + spec §13.5）

**为什么做：** `HostKeyStore.remove` 的文档把这件事说死了 —— 设备**真的**换过主机密钥时，`find` 会一直返回旧指纹，这台设备被**永久**拒绝连接；而 `SshSession` 的错误文案正是让用户"在设置中清除该主机的记录后重连"。**接口少了这个界面，那句话就是在教用户做一件做不到的事。**

**Files:**
- Create: `lib/ui/dialogs/known_hosts_section.dart`
- Modify: `lib/ui/dialogs/settings_dialog.dart`（把这一段接进去）
- Test: `test/ui/known_hosts_section_test.dart`（新建）

**三个写死的设计点：**

1. **不向下转型。** `AppStores.hostKeys` 的静态类型**就是** `FileHostKeyStore`（`late final FileHostKeyStore hostKeys = ...`），`all()` 直接从具体类型上调 —— spec §13.5 要求的是"别让设置界面去 downcast 具体类型"，这里不需要。
2. **`all()` 会抛。** 文件坏了就抛 `FormatException`（那是 `FileHostKeyStore` 的**有意设计**：丢一条已知主机密钥 = 让那台主机退回"首次连接"，而用户根本不会被告知记录丢过）。所以这一段**必须接住它并说出来**，不能让设置对话框整个炸掉。
3. **清除要确认。** 清掉一条记录之后，那台主机会退回"首次连接" —— 下一次连接会弹指纹确认。用户点错一下就走到了那里，值得一次确认。

- [ ] **Step 1：写失败的测试**

新建 `test/ui/known_hosts_section_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/ui/dialogs/known_hosts_section.dart';

import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_khs_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 预置盘上的 `known_hosts.json`。
  ///
  /// **用另一个 `AppStores` 实例是安全的**，因为 `FileHostKeyStore` **不持
  /// 实例缓存**（见它 `_readFromDisk` 的文档）。这一点正是那段文档要保的东西。
  Future<void> seed(List<KnownHost> hosts) async {
    final store = AppStores(paths: AppPaths(root)).hostKeys;
    for (final h in hosts) {
      await store.save(h);
    }
  }

  KnownHost host(String ip, {String type = 'ssh-ed25519', String fp = 'SHA256:aaa'}) =>
      KnownHost(host: ip, port: 22, keyType: type, fingerprint: fp);

  Future<void> pumpSection(WidgetTester tester) async {
    await pumpUi(
      tester,
      root: root,
      child: const SizedBox(height: 400, child: KnownHostsSection()),
    );
    await settleDisk(tester);
  }

  testWidgets('空的时候说清楚，不是一片空白', (tester) async {
    await pumpSection(tester);

    expect(find.textContaining('还没有任何已知主机密钥'), findsOneWidget);
  });

  testWidgets('列出一条记录的主机与算法（FR-G-01 的"查看"）', (tester) async {
    await seed([
      host('10.0.0.1', type: 'ssh-ed25519', fp: 'SHA256:abc123'),
    ]);

    await pumpSection(tester);

    expect(find.textContaining('10.0.0.1:22'), findsOneWidget);
    expect(find.textContaining('ssh-ed25519'), findsOneWidget);
    expect(find.textContaining('SHA256:abc123'), findsOneWidget);
  });

  testWidgets('同一主机的两种算法是两条（spec §13.5）', (tester) async {
    await seed([
      host('10.0.0.1', type: 'ssh-ed25519', fp: 'SHA256:ed'),
      host('10.0.0.1', type: 'rsa-sha2-256', fp: 'SHA256:rsa'),
    ]);

    await pumpSection(tester);

    expect(find.textContaining('SHA256:ed'), findsOneWidget);
    expect(find.textContaining('SHA256:rsa'), findsOneWidget);
    expect(find.textContaining('10.0.0.1:22'), findsNWidgets(2));
  });

  testWidgets('逐条清除：确认之后盘上那条没了（FR-G-01 的"逐条清除"）', (tester) async {
    await seed([
      host('10.0.0.1', fp: 'SHA256:ed'),
      host('10.0.0.2', type: 'rsa-sha2-256', fp: 'SHA256:rsa'),
    ]);
    await pumpSection(tester);

    // 第一条记录的清除按钮。
    await tester.tap(find.byKey(const ValueKey('known-host-remove-0')));
    await tester.pumpAndSettle();
    expect(find.text('清除这条已知主机密钥？'), findsOneWidget);

    await tester.tap(find.text('确认清除'));
    await settleDisk(tester);

    final left = await AppStores(paths: AppPaths(root)).hostKeys.all();
    expect(left, hasLength(1));
    expect(left.single.host, '10.0.0.2');
    expect(
      find.textContaining('SHA256:ed'),
      findsNothing,
      reason: '列表要跟着刷新',
    );
  });

  testWidgets('清除时点取消：盘上一条都不少', (tester) async {
    await seed([host('10.0.0.1')]);
    await pumpSection(tester);

    await tester.tap(find.byKey(const ValueKey('known-host-remove-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await settleDisk(tester);

    expect(await AppStores(paths: AppPaths(root)).hostKeys.all(), hasLength(1));
    expect(find.textContaining('SHA256:aaa'), findsOneWidget);
  });

  testWidgets('全部清除也要确认，且一次清光', (tester) async {
    await seed([host('10.0.0.1'), host('10.0.0.2')]);
    await pumpSection(tester);

    await tester.tap(find.byKey(const ValueKey('known-hosts-clear-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认清除'));
    await settleDisk(tester);

    expect(await AppStores(paths: AppPaths(root)).hostKeys.all(), isEmpty);
    expect(find.textContaining('还没有任何已知主机密钥'), findsOneWidget);
  });

  testWidgets('文件坏了：说出来，不把设置对话框炸掉', (tester) async {
    await File('${root.path}/known_hosts.json').writeAsString('{ not json');

    await pumpSection(tester);

    expect(find.textContaining('无法读取'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2：跑测试，确认它红**

Run: `flutter test test/ui/known_hosts_section_test.dart`
Expected: FAIL —— `Target of URI doesn't exist: 'package:win_cli_tool/ui/dialogs/known_hosts_section.dart'`。

- [ ] **Step 3：实现这一段**

新建 `lib/ui/dialogs/known_hosts_section.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connection/known_host.dart';
import '../../state/providers.dart';

/// 设置对话框里的「已知主机密钥」区（FR-G-01 的"查看与逐条清除"）。
///
/// **它独立于 `SettingsDialog` 的"保存"按钮。** 那一边是"改了一堆字段、
/// 一次写入"，这一边的每一个动作（清除一条）都是**立即、独立、不可撤销**
/// 的。把它们塞进同一个保存语义里，会造出"清了一条然后又点了取消"这种
/// 说不清的状态。
class KnownHostsSection extends ConsumerStatefulWidget {
  const KnownHostsSection({super.key});

  @override
  ConsumerState<KnownHostsSection> createState() => _KnownHostsSectionState();
}

class _KnownHostsSectionState extends ConsumerState<KnownHostsSection> {
  List<KnownHost>? _hosts;

  /// 读盘失败时的说明。**`all()` 会抛**（`FileHostKeyStore` 的有意设计：
  /// 丢一条已知主机密钥等于让那台主机静默退回"首次连接"）。接住它换一句
  /// 人话，不能让整个设置对话框跟着炸。
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      // `AppStores.hostKeys` 的静态类型就是 `FileHostKeyStore`，`all()` 直接
      // 从具体类型上调 —— 不涉及向下转型（spec §13.5 的要求）。
      final hosts = await ref.read(appStoresProvider).hostKeys.all();
      if (!mounted) return;
      setState(() {
        _hosts = hosts;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _hosts = const [];
        _error = '已知主机密钥文件无法读取：$error';
      });
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _remove(KnownHost target) async {
    final ok = await _confirm(
      '清除这条已知主机密钥？',
      '清掉之后，${target.host}:${target.port} 会退回"首次连接" —— '
          '下次连它会重新弹出指纹让你确认。',
    );
    if (!ok || !mounted) return;
    await ref
        .read(appStoresProvider)
        .hostKeys
        .remove(target.host, target.port, target.keyType);
    await _reload();
  }

  Future<void> _clearAll() async {
    final hosts = _hosts ?? const <KnownHost>[];
    final ok = await _confirm(
      '清除全部已知主机密钥？',
      '${hosts.length} 条记录都会被清掉，之后每一台主机都会重新弹指纹确认。',
    );
    if (!ok || !mounted) return;
    final store = ref.read(appStoresProvider).hostKeys;
    for (final h in hosts) {
      await store.remove(h.host, h.port, h.keyType);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('已知主机密钥', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (hosts != null && hosts.isNotEmpty)
              TextButton(
                key: const ValueKey('known-hosts-clear-all'),
                onPressed: _clearAll,
                child: const Text('全部清除'),
              ),
          ],
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        else if (hosts == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('读取中…'),
          )
        else if (hosts.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '还没有任何已知主机密钥。首次连接一台 SSH 设备并确认指纹之后，'
              '记录会出现在这里。',
              style: TextStyle(fontSize: 12),
            ),
          )
        else
          for (var i = 0; i < hosts.length; i++)
            ListTile(
              key: ValueKey('known-host-$i'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${hosts[i].host}:${hosts[i].port}  ${hosts[i].keyType}'),
              subtitle: Text(
                hosts[i].fingerprint,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              trailing: IconButton(
                key: ValueKey('known-host-remove-$i'),
                tooltip: '清除',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => _remove(hosts[i]),
              ),
            ),
      ],
    );
  }
}
```

- [ ] **Step 4：接进设置对话框**

在 `lib/ui/dialogs/settings_dialog.dart` 里，把 `_error != null` 那个 `if` 块的**前面**插入：

```dart
              const Divider(height: 24),
              // **在 `_error` 之前**：这一段的读写是即时的，与下面那个
              // 「保存」按钮无关（见它的文档）。
              const KnownHostsSection(),
```

文件顶部加 import：

```dart
import 'known_hosts_section.dart';
```

- [ ] **Step 5：跑测试，确认全绿**

Run: `flutter test test/ui/known_hosts_section_test.dart test/ui/settings_dialog_test.dart`
Expected: PASS

一条容易红的：`全部清除也要确认，且一次清光` 里的两条 `remove` 是**串行 await** 的 —— 若改成 `Future.wait` 并发，`FileHostKeyStore` 的"读-改-写"会互相覆盖（它每次真读盘，两个并发调用各读到同一份快照，后写的把先写的盖回去）。**保持串行。**

- [ ] **Step 6：跑一遍全仓**

Run: `flutter test`
Expected: PASS

- [ ] **Step 7：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 8：提交**

```bash
git add lib/ui/dialogs/known_hosts_section.dart lib/ui/dialogs/settings_dialog.dart test/ui/known_hosts_section_test.dart
git commit -m "feat(ui): 设置里的已知主机密钥区（FR-G-01、spec §13.5）

查看 + 逐条清除 + 全部清除，各带确认；文件坏了只这一段报错，
不把设置对话框炸掉。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 11：指纹确认对话框 + `onUnknownHostKey` 接线（FR-C-11 / NFR-S-03）

**为什么做 —— 这是这一版里唯一一条"安全功能整体不生效"的缺陷。**

`sessionFactoryProvider` 今天是这样造的（`lib/state/providers.dart`）：

```dart
return SessionFactory(
  hostKeyStore: stores.hostKeys,
  connectTimeout: Duration(milliseconds: settings.connectTimeoutMs),
  verifyHostKey: settings.verifySshHostKey,
);
```

`SessionFactory.onUnknownHostKey` 的默认值是 `null`，而 `SshSession` 的校验回调里那一行是：

```dart
final accept = await onUnknownHostKey?.call(candidate) ?? false;
```

于是**每一次首次连接都拿到 `false`** —— 没有主机密钥能被登记，任何一台新设备都连不上。而这正是 **NFR-S-03 + FR-C-11** 要求的那件事：默认开启校验、首次连接弹指纹给用户确认。今天它不是"校验太严"，是"整条路走不通"。

**Files:**
- Create: `lib/state/host_key_prompt.dart`
- Create: `lib/ui/dialogs/host_key_dialog.dart`
- Create: `lib/ui/widgets/host_key_prompt_host.dart`
- Modify: `lib/state/providers.dart`（`sessionFactoryProvider` 加一行）
- Modify: `lib/app.dart`（`home:` 包一层）
- Test: `test/ui/host_key_prompt_test.dart`（新建）

**三个写死的设计点：**

1. **排队，不是"只留一个"。** `connectAutoConnectDevicesAtStartup`（FR-C-14）会**同时**对多台设备发起连接，所以同一时刻可能来好几个询问。只留最后一个的话，前面那些的 `Future` **永远不会完成** —— 那几台设备的 SSH 握手就永久挂着。
2. **回答要认人。** `reply` 必须核对"你回答的是不是当前这一个"，否则一个**过期的对话框**（用户开着它、同时别处又来了新的询问）的答案会落到新的那个询问上 —— 用户对着 A 主机的指纹点了"接受"，实际被接受的是 B 主机。
3. **关掉界面 = 全部拒绝。** 容器销毁时把所有挂着的询问判为拒绝（`onDispose` 里完成 Completer）。默认必须是"拒绝"，不能是"接受"。

- [ ] **Step 1：写失败的测试**

新建 `test/ui/host_key_prompt_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/host_key_prompt.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/widgets/host_key_prompt_host.dart';

import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_hkprompt_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  KnownHost candidate(String ip, {String fp = 'SHA256:abc'}) => KnownHost(
    host: ip,
    port: 22,
    keyType: 'ssh-ed25519',
    fingerprint: fp,
  );

  ProviderContainer makeContainer({
    AppSettings settings = const AppSettings(),
  }) {
    final container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores(paths: AppPaths(root))),
        startupProvider.overrideWithValue(
          AppStartup(settings: settings, devices: const []),
        ),
        logsDirPath.overrideWithValue('${root.path}/logs'),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('HostKeyPromptNotifier', () {
    test('接受时 ask 的 Future 兑现 true（FR-C-11）', () async {
      final container = makeContainer();
      final notifier = container.read(hostKeyPromptProvider.notifier);

      final answer = notifier.ask(candidate('10.0.0.1'));
      final prompt = container.read(hostKeyPromptProvider);
      expect(prompt, isNotNull);
      expect(prompt!.host.fingerprint, 'SHA256:abc');

      notifier.reply(prompt, true);

      expect(await answer, isTrue);
      expect(
        container.read(hostKeyPromptProvider),
        isNull,
        reason: '回答完就该收起来',
      );
    });

    test('拒绝时兑现 false', () async {
      final container = makeContainer();
      final notifier = container.read(hostKeyPromptProvider.notifier);

      final answer = notifier.ask(candidate('10.0.0.1'));
      notifier.reply(container.read(hostKeyPromptProvider)!, false);

      expect(await answer, isFalse);
    });

    test('过期的回答不生效，也不会串到新的询问上（设计点 2）', () async {
      final container = makeContainer();
      final notifier = container.read(hostKeyPromptProvider.notifier);

      final first = notifier.ask(candidate('10.0.0.1', fp: 'SHA256:first'));
      final stale = container.read(hostKeyPromptProvider)!;

      // 第一个还没答，第二个就来了（FR-C-14 会并发连多台）。
      final second = notifier.ask(candidate('10.0.0.2', fp: 'SHA256:second'));

      notifier.reply(stale, true);
      expect(await first, isTrue, reason: '它答的是第一个');
      expect(
        container.read(hostKeyPromptProvider)!.host.fingerprint,
        'SHA256:second',
        reason: '答完第一个，第二个应当接上',
      );

      // **同一个过期对象再答一次**：它已经不是当前那个了。
      notifier.reply(stale, true);

      final current = container.read(hostKeyPromptProvider)!;
      expect(current.host.fingerprint, 'SHA256:second', reason: '不该被顶掉');
      notifier.reply(current, false);
      expect(await second, isFalse);
    });

    test('容器销毁时挂着的询问一律判拒绝（设计点 3）', () async {
      final container = makeContainer();
      final notifier = container.read(hostKeyPromptProvider.notifier);

      final answer = notifier.ask(candidate('10.0.0.1'));
      container.dispose();

      expect(
        await answer,
        isFalse,
        reason: '默认必须是拒绝 —— 没人回答时绝不能放行',
      );
    });
  });

  group('sessionFactoryProvider 的接线（NFR-S-03 的要害）', () {
    test('onUnknownHostKey 不是 null，且能把用户的选择带回去（FR-C-11）', () async {
      final container = makeContainer();
      final factory = container.read(sessionFactoryProvider);

      expect(
        factory.onUnknownHostKey,
        isNotNull,
        reason: '为 null 时 SshSession 一律拒绝 —— 任何新设备都连不上，'
            '而"确认后保存"这条 FR-C-11 从来没有发生过',
      );

      final pending = factory.onUnknownHostKey!(candidate('10.0.0.1'));
      final prompt = container.read(hostKeyPromptProvider)!;
      container.read(hostKeyPromptProvider.notifier).reply(prompt, true);

      expect(await pending, isTrue);
    });

    test('设置里关掉校验时，factory 的 verifyHostKey 跟着是 false（FR-C-11）', () {
      final container = makeContainer(
        settings: const AppSettings(verifySshHostKey: false),
      );

      expect(container.read(sessionFactoryProvider).verifyHostKey, isFalse);
    });

    test('设置里超时改了，factory 的 connectTimeout 跟着改（FR-C-13）', () {
      final container = makeContainer(
        settings: const AppSettings(connectTimeoutMs: 3000),
      );

      expect(
        container.read(sessionFactoryProvider).connectTimeout,
        const Duration(milliseconds: 3000),
      );
    });
  });

  group('HostKeyPromptHost', () {
    Future<void> pumpHost(
      WidgetTester tester, {
      AppSettings settings = const AppSettings(),
    }) => pumpUi(
      tester,
      root: root,
      settings: settings,
      child: const HostKeyPromptHost(child: SizedBox()),
    );

    testWidgets('询问时弹出对话框，指纹一字不差地摆出来（FR-C-11）', (tester) async {
      await pumpHost(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HostKeyPromptHost)),
      );

      final answer = container
          .read(hostKeyPromptProvider.notifier)
          .ask(candidate('10.0.0.1', fp: 'SHA256:Zx9/abc='));
      await tester.pumpAndSettle();

      expect(find.textContaining('10.0.0.1'), findsWidgets);
      expect(find.textContaining('ssh-ed25519'), findsOneWidget);
      expect(find.text('SHA256:Zx9/abc='), findsOneWidget);

      await tester.tap(find.text('接受并保存'));
      await tester.pumpAndSettle();

      expect(await answer, isTrue);
      expect(find.text('接受并保存'), findsNothing, reason: '答完要收起来');
    });

    testWidgets('点「拒绝」把 false 带回去', (tester) async {
      await pumpHost(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HostKeyPromptHost)),
      );

      final answer = container
          .read(hostKeyPromptProvider.notifier)
          .ask(candidate('10.0.0.1'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();

      expect(await answer, isFalse);
    });

    testWidgets('两个询问排队出现，不是只弹一个（设计点 1）', (tester) async {
      await pumpHost(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HostKeyPromptHost)),
      );
      final notifier = container.read(hostKeyPromptProvider.notifier);

      final first = notifier.ask(candidate('10.0.0.1', fp: 'SHA256:first'));
      final second = notifier.ask(candidate('10.0.0.2', fp: 'SHA256:second'));
      await tester.pumpAndSettle();

      expect(find.text('SHA256:first'), findsOneWidget);

      await tester.tap(find.text('接受并保存'));
      await tester.pumpAndSettle();

      expect(await first, isTrue);
      expect(find.text('SHA256:second'), findsOneWidget, reason: '第二个要接上');

      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(await second, isFalse);
    });
  });
}
```

- [ ] **Step 2：跑测试，确认它红**

Run: `flutter test test/ui/host_key_prompt_test.dart`
Expected: FAIL —— `Target of URI doesn't exist: 'package:win_cli_tool/state/host_key_prompt.dart'`。

- [ ] **Step 3：实现状态层**

新建 `lib/state/host_key_prompt.dart`：

```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/known_host.dart';

/// 一次"这台主机是首次连接，接不接受它的指纹"的询问（FR-C-11）。
///
/// 它同时是**回答的入口**（[complete]）与**等待的把手**（[answer]）——
/// `SshSession` 那边 `await` 的就是 [answer]。
class HostKeyPrompt {
  HostKeyPrompt(this.host);

  final KnownHost host;

  final _completer = Completer<bool>();

  /// 用户的回答。**容器销毁时会被判成 false**（见 [HostKeyPromptNotifier.build]）。
  Future<bool> get answer => _completer.future;

  void complete(bool accept) {
    if (!_completer.isCompleted) _completer.complete(accept);
  }
}

/// 待用户确认的主机密钥询问。
///
/// `state` 是**队头**（当前该显示的那一个），队列在 notifier 内部。
///
/// **为什么是队列而不是"只留最新一个"：** `connectAutoConnectDevicesAtStartup`
/// （FR-C-14）会同时给多台设备发起连接。只留最新的一个，前面那些的 `answer`
/// **永远不会完成**，那几台设备的 SSH 握手会永久挂着 —— 界面上一片"连接中"，
/// 而没有任何东西会把它推进下去。
class HostKeyPromptNotifier extends Notifier<HostKeyPrompt?> {
  final _queue = <HostKeyPrompt>[];

  @override
  HostKeyPrompt? build() {
    // **容器销毁 = 全部拒绝。** 不能只 drop 掉队列：那些 `answer` 还挂在
    // SSH 握手里，不完成就是泄漏一个永不结束的 Future。而"没人回答"这件事
    // 的默认答案**必须是拒绝** —— 与 `SshSession` 里
    // `onUnknownHostKey?.call(...) ?? false` 是同一个立场。
    ref.onDispose(() {
      for (final prompt in _queue) {
        prompt.complete(false);
      }
      _queue.clear();
    });
    return null;
  }

  /// 问用户。返回的 Future 在用户回答（或容器销毁）时兑现。
  Future<bool> ask(KnownHost host) {
    final prompt = HostKeyPrompt(host);
    _queue.add(prompt);
    if (state == null) state = prompt;
    return prompt.answer;
  }

  /// 回答。**只认当前队头那一个。**
  ///
  /// 身份校验是必须的：用户可能正开着 A 的对话框，而 B 的询问在此期间到达。
  /// 少了这一行，对 A 点下的"接受"会落到 B 上 —— 用户以为自己在批准 10.0.0.1
  /// 的指纹，被写进已知主机列表的却是 10.0.0.2 的那把密钥。
  void reply(HostKeyPrompt prompt, bool accept) {
    if (!identical(prompt, state)) return;
    _queue.remove(prompt);
    prompt.complete(accept);
    state = _queue.isEmpty ? null : _queue.first;
  }
}

final hostKeyPromptProvider =
    NotifierProvider<HostKeyPromptNotifier, HostKeyPrompt?>(
      HostKeyPromptNotifier.new,
    );
```

- [ ] **Step 4：实现对话框与宿主**

新建 `lib/ui/dialogs/host_key_dialog.dart`：

```dart
import 'package:flutter/material.dart';

import '../../connection/known_host.dart';

/// 首次连接一台 SSH 主机时的指纹确认（FR-C-11）。
///
/// **`barrierDismissible: false`。** 点空白关掉它也返回 false（安全侧），
/// 但那会让一次连接因为"手滑点到了旁边"而失败，而失败信息里没有"你刚才
/// 关掉了指纹确认"。让它必须明确选一个。
Future<bool> showHostKeyDialog(BuildContext context, KnownHost host) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('首次连接这台主机'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${host.host}:${host.port}'),
            const SizedBox(height: 4),
            Text('密钥算法：${host.keyType}'),
            const SizedBox(height: 12),
            const Text('指纹：', style: TextStyle(fontSize: 12)),
            SelectableText(
              host.fingerprint,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            const Text(
              '这是唯一一次核对它的机会。如果这个指纹与设备上实际的那把不符，'
              '说明中间有人在冒充它 —— 选「拒绝」。\n'
              '接受之后指纹会被记住，下次连接不再询问。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('拒绝'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('接受并保存'),
        ),
      ],
    ),
  );
  return accepted ?? false;
}
```

新建 `lib/ui/widgets/host_key_prompt_host.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/host_key_prompt.dart';
import '../dialogs/host_key_dialog.dart';

/// 把 [hostKeyPromptProvider] 的询问变成对话框的宿主。
///
/// 它包在 `MainWindow` **外面**（`app.dart` 的 `home:`），因为询问来自会话层
/// （`SessionFactory` 的 `onUnknownHostKey`），而那时界面可能还没有任何
/// 与设备相关的部件挂在树上。
class HostKeyPromptHost extends ConsumerStatefulWidget {
  const HostKeyPromptHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<HostKeyPromptHost> createState() => _HostKeyPromptHostState();
}

class _HostKeyPromptHostState extends ConsumerState<HostKeyPromptHost> {
  /// 已经有一个对话框开着了。**不能靠 `state != null` 判** —— 队列里还有
  /// 第二个的时候 `state` 也不为 null，而那时不该再开一个。
  var _showing = false;

  @override
  Widget build(BuildContext context) {
    ref.listen(hostKeyPromptProvider, (previous, next) {
      // `fireImmediately` 是为了"本部件挂载时就已经有一个在等"这种时序
      // （`ask` 发生在建连那一刻，可能早于本部件的第一帧）。
      if (next == null || _showing) return;
      _showing = true;
      // **不能在这个回调里直接 `showDialog`。** 监听回调发生在 provider
      // 刷新的过程中，此刻 `Navigator` 正在构建这一帧；在这里 push 一个路由
      // 会拿到 "setState() or markNeedsBuild() called during build"。
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final accepted = await showHostKeyDialog(context, next.host);
        _showing = false;
        if (!mounted) return;
        // **`next` 而不是"当前 state"** —— 用户回答的就是它。
        // `reply` 内部还会再核对一次身份（见它的文档）。
        ref.read(hostKeyPromptProvider.notifier).reply(next, accepted);
      });
    }, fireImmediately: true);

    return widget.child;
  }
}
```

- [ ] **Step 5：接线**

在 `lib/state/providers.dart` 的 `sessionFactoryProvider` 里，`verifyHostKey:` 那一行**之后**加：

```dart
      // FR-C-11 / NFR-S-03：**首次连接某主机时问用户。** 少了这一行，
      // `SessionFactory.onUnknownHostKey` 就是 null，而 `SshSession` 里那句
      // `await onUnknownHostKey?.call(candidate) ?? false` 于是恒为 false ——
      // 没有主机密钥能被登记，任何一台新设备都连不上。校验开着（默认）却
      // 谁也连不上，是这一版里最严重的一条。
      onUnknownHostKey: (host) =>
          ref.read(hostKeyPromptProvider.notifier).ask(host),
```

文件顶部加 import：

```dart
import 'host_key_prompt.dart';
```

在 `lib/app.dart` 里把

```dart
      home: const MainWindow(),
```

换成：

```dart
      // 指纹确认要能在**任何**界面之上弹出来（它由图外的事件触发），
      // 所以宿主包在 `MainWindow` 外面。
      home: const HostKeyPromptHost(child: MainWindow()),
```

文件顶部加 import：

```dart
import 'ui/widgets/host_key_prompt_host.dart';
```

- [ ] **Step 6：跑测试，确认全绿**

Run: `flutter test test/ui/host_key_prompt_test.dart`
Expected: PASS（10 条）

一条容易红的：`两个询问排队出现，不是只弹一个` 若在第二次 `pumpAndSettle` 后找不到 `SHA256:second` —— 检查 `reply` 里 `state = _queue.isEmpty ? null : _queue.first;` 那一行的**顺序**：它必须在 `prompt.complete(accept)` **之后**（先兑现旧的、再换新的），否则 `_showing` 的翻转与 `state` 的翻转会错开一帧，第二个对话框要等下一次 pump 才出来（`pumpAndSettle` 能兜住，但顺序写对更省事）。

- [ ] **Step 7：跑一遍全仓**

Run: `flutter test`
Expected: PASS

⚠ **`test/connection/session_factory_test.dart` 与 `ssh_session_test.dart` 不该受影响** —— 它们直接构造 `SessionFactory`，不经过 provider。若它们红了，说明改动落错了地方。

- [ ] **Step 8：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 9：提交**

```bash
git add lib/state/host_key_prompt.dart lib/state/providers.dart lib/ui/dialogs/host_key_dialog.dart lib/ui/widgets/host_key_prompt_host.dart lib/app.dart test/ui/host_key_prompt_test.dart
git commit -m "feat(ui): 指纹确认对话框 + onUnknownHostKey 接线（FR-C-11、NFR-S-03）

修的是"校验开着却谁也连不上"：onUnknownHostKey 一直是 null，
SshSession 的 `?? false` 于是把每一次首次连接都判成拒绝。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 12：FR-C-06 首次失败即变红，之后再退避（决策②）

**为什么做：** FR-C-06 要求连接失败时按钮变红，而 §5.4 的逐事件表里没有红 —— 今天红的唯一来路是"`autoReconnect` 为 false 时失败"（`connection_manager.dart:369`），而那个开关在设置里**没有对应项**（FR-G-01 里没有「自动重连」）。也就是说**红在默认配置下不可达**。用户拍板：**首次失败即变红，之后再退避**（退避期间是黄）。

**这个决策把 `failed` 的含义钉死了：** 它不再是"不再重试"，而是**"这一次尝试失败了"**。`DeviceConnectionState.failed` 的文档今天写着"**且不再自动重试**"，本次一并改掉 —— 留着旧文档，下一个人会照着它推理。

**Files:**
- Modify: `lib/connection/connection_manager.dart`（`_scheduleRetry` + `DeviceConnectionState.failed` 的文档）
- Test: `test/connection/connection_manager_test.dart`（改两处断言）

- [ ] **Step 1：改那条会红的既有断言，让它先红**

`test/connection/connection_manager_test.dart:195` 那一条：

```dart
      mgr.connect(); // 第 1 次尝试立即失败
      async.flushMicrotasks();
      expect(factory.created, 1);
      expect(mgr.state, DeviceConnectionState.reconnecting);
```

把最后一行换成：

```dart
      // FR-C-06（决策②）：**首次失败当场变红**，退避继续排。
      expect(
        mgr.state,
        DeviceConnectionState.failed,
        reason: '第一次就连不上时按钮必须是红的，不是黄的',
      );
```

`test/connection/connection_manager_test.dart:734` 那条状态流：

```dart
          DeviceConnectionState.reconnecting,
```

换成：

```dart
          // FR-C-06（决策②）：掉线时 `_attempt` 是 0（上次连接成功时归的零），
          // 所以先红；1s 后重连定时器醒来，`_attemptConnect` 看到 `_attempt == 1`，
          // 于是这一格是**黄**（重连中）而不是灰/红。
          DeviceConnectionState.failed,
          DeviceConnectionState.reconnecting,
```

Run: `flutter test test/connection/connection_manager_test.dart`
Expected: FAIL（两条）—— 实际是 `reconnecting`（第 195 行那条）／状态流对不上（第 734 行那条）。

- [ ] **Step 2：实现**

把 `lib/connection/connection_manager.dart` 的 `_scheduleRetry` 里

```dart
    _setState(DeviceConnectionState.reconnecting);
    _attempt++;
```

换成：

```dart
    // FR-C-06：**首次失败当场变红**，之后才走退避（决策②）。
    //
    // `_attempt` 在这里是"此前已经失败过几次"：它在连接成功时归零
    // （见 `_attemptConnect` 末尾），也在 `disconnect()` 里归零。所以
    // `_attempt == 0` 就是"刚连上过、或者这是第一次尝试" —— 这两种情况下
    // 用户看到红都是对的。之后的重试仍是黄（`_attemptConnect` 开头按
    // `_attempt` 是否为 0 选 `connecting` / `reconnecting`）。
    if (_attempt == 0) {
      _setState(DeviceConnectionState.failed);
    } else {
      _setState(DeviceConnectionState.reconnecting);
    }
    _attempt++;
```

- [ ] **Step 3：改掉那条过期的文档**

把 `DeviceConnectionState.failed` 的文档

```dart
  /// 连接失败且**不再自动重试**（`autoReconnect` 为 false 时）。
  ///
  /// 注意：用户主动断开**不是**这个状态 —— §5.4 要求那种情况按钮变灰，
  /// 也就是 [disconnected]。
  failed;
```

换成：

```dart
  /// 连接失败（FR-C-06）。**首次失败即进入本状态**，按钮变红。
  ///
  /// 红**不代表"不再重试"**：`autoReconnect` 打开时（默认）下一次尝试会在
  /// 退避时长之后自动发起，那时状态转为 [reconnecting]（黄）。`autoReconnect`
  /// 关闭时则一直停在这里。
  ///
  /// 用户主动断开**不是**这个状态 —— §5.4 要求那种情况按钮变灰，也就是
  /// [disconnected]。
  failed;
```

同时把文件头那段

```dart
/// 注意"红"：§5.4 的逐事件表里**没有**红（只有黄/黄/绿/灰），红来自
/// FR-C-06 的"连接失败"。`failed` 何时可达目前尚未定论，见 spec §13.17-3。
```

换成：

```dart
/// 注意"红"：§5.4 的逐事件表里**没有**红（只有黄/黄/绿/灰），红来自
/// FR-C-06 的"连接失败"。**它何时可达已定**（2026-09-26 拍板）：首次失败
/// 即变红，之后的重试期间是黄 —— 见 [DeviceConnectionState.failed]。
```

- [ ] **Step 4：跑测试，确认全绿**

Run: `flutter test test/connection/connection_manager_test.dart`
Expected: PASS

⚠ 若除了这两条还有别的红，**先读那条断言想说什么**再动手。`autoReconnect: false` 的两条（561/569 附近）断言的是 `failed`，与本次改动**同向**，本来就该绿。

- [ ] **Step 5：跑一遍全仓**

Run: `flutter test`
Expected: PASS

会受影响的还有 `test/state/` 与 `test/e2e/` 里断言状态序列的地方 —— 若有，按"首次失败是 failed、之后是 reconnecting"改，**别改回 reconnecting**。

- [ ] **Step 6：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 7：提交**

```bash
git add lib/connection/connection_manager.dart test/connection/connection_manager_test.dart
git commit -m "feat(conn): FR-C-06 首次失败即变红，之后再退避（决策②）

failed 的含义随之从"不再重试"改成"这一次失败了"，文档同步更正。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 13：断线文案不再谎称「未发送」（决策③）

**为什么做：** `QueueDropped.count` 是 `_queue.length + (_current != null ? 1 : 0)` —— **在途的那条也计入**（`command_dispatcher.dart:208`，`connection_manager_test.dart:534` 有一条断言专门守着"1 条排队 + 1 条在途 = 2"）。它在途，所以"未发送"是**假的**：那条命令**已经写到设备上了**，只是输出永远收不到。用户读到"2 条未发送"，会以为两条都没生效；实际有一条可能已经改了设备配置。

**只改文案，不动事件**（决策③）：`QueueDropped(count)` 的载荷与语义一个字不动。

**Files:**
- Modify: `lib/state/session_controller.dart:254`
- Modify: `lib/state/session_controller.dart`（`_onDispatchEvent` 的 QueueDropped 分支）
- Modify: `lib/ui/panels/editor_panel.dart:179`
- Test: `test/state/session_controller_test.dart`（追加）
- Test: `test/ui/editor_panel_test.dart`（追加）

- [ ] **Step 1：写失败的测试**

在 `test/state/session_controller_test.dart` 末尾（`main` 的右花括号之前）追加：

```dart
  test('断线标记说的是「未完成」，不是「未发送」（FR-C-10 的文案）', () async {
    final c = make();
    addTearDown(c.dispose);
    await c.connect();

    // 两条：第一条在途、第二条排队 —— 丢弃数是 2，而其中只有 1 条是真的
    // 没发出去。文案必须对这两条都成立。
    c.enqueue(const ['show version', 'show clock']);
    await settle();
    factory.sessions.single.drop();
    await settle();

    final text = buffer.lines
        .map((line) => line.map((s) => s.text).join())
        .join('\n');
    expect(text, contains('2 条命令未完成'));
    expect(
      text,
      isNot(contains('未发送')),
      reason: '在途的那条已经写到设备上了，说它"未发送"是假的',
    );
  });
```

在 `test/ui/editor_panel_test.dart` 末尾追加：

```dart
  testWidgets('断线后编辑区工具栏的进度文案不再是「未发送」', (tester) async {
    final factory = FakeSessionFactory();
    await pumpEditor(tester, factory: factory);
    await tester.tap(find.byTooltip('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'show version\nshow clock');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    // 第一条在途、第二条排队。
    factory.sessions.first.drop();
    await tester.pump();

    expect(find.text('断线，2 条命令未完成'), findsOneWidget);

    // **把重连定时器走完。** 不走的话用例会红在
    // `A Timer is still pending even after the widget tree was disposed` ——
    // 那是拆卸期的假象，断言其实已经过了（见 `drainQueue` 的注释）。
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });
```

Run: `flutter test test/state/session_controller_test.dart test/ui/editor_panel_test.dart`
Expected: FAIL —— 状态层那条红在 `contains('2 条命令未完成')`（现在是「未发送」）；编辑区那条红在**找不到** `断线，2 条命令未完成`。**后者红的原因不是文案，是那条分支根本走不到** —— 见 Step 3。

- [ ] **Step 2：改状态层的文案**

`lib/state/session_controller.dart:254`：

```dart
      _markWarn('--- 连接断开，${event.count} 条未发送的命令已丢弃 ---');
```

换成：

```dart
      // **不说"未发送"。** `QueueDropped.count` 是"排队数 + 在途数"
      // （`command_dispatcher.dart` 的 `onDisconnected`）—— 在途那条**已经写到
      // 设备上了**，只是输出永远收不到。说它"未发送"会让用户以为设备没被改过。
      _markWarn('--- 连接断开，${event.count} 条命令未完成并已丢弃 ---');
```

- [ ] **Step 3：让编辑区那条文案真的能显示出来**

`lib/state/session_controller.dart` 的 `_onDispatchEvent` 里，QueueDropped 那一支今天**提前 return** 了，所以 `lastDispatchEvent` 从不变成本事件 —— 编辑区 `_progress` 里那条 `if (event is QueueDropped)` 是**不可达的代码**。改文案之前先让它可达：

```dart
    if (event is QueueDropped) {
      _setStatus(_status.copyWith(droppedCommands: event.count));
      _markWarn('--- 连接断开，${event.count} 条命令未完成并已丢弃 ---');
      // **原来这里直接 return，于是 `lastDispatchEvent` 从不变成本事件，
      // 编辑区那条 `if (event is QueueDropped)` 永远走不到**（它的文案再改
      // 也没人看得见）。落一次，让工具栏也能显示"断线，N 条命令未完成"。
      //
      // **事件本身没动**（决策③）：`QueueDropped(count)` 的载荷与语义一个字
      // 不改，这里只是把这个事件也记进"最近一次派发事件"。
      _setStatus(_status.copyWith(lastDispatchEvent: event));
      return;
    }
```

- [ ] **Step 4：改编辑区的文案**

`lib/ui/panels/editor_panel.dart:179`：

```dart
    if (event is QueueDropped) return '断线，${event.count} 条未发送的命令已丢弃';
```

换成：

```dart
    // 与 `SessionController` 那句输出区标记同一个口径：**不说"未发送"**
    // —— `count` 含在途的那一条，它已经写到设备上了。
    if (event is QueueDropped) return '断线，${event.count} 条命令未完成';
```

- [ ] **Step 5：跑测试，确认全绿**

Run: `flutter test test/state/session_controller_test.dart test/ui/editor_panel_test.dart`
Expected: PASS

- [ ] **Step 6：跑一遍全仓**

Run: `flutter test`
Expected: PASS

- [ ] **Step 7：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 8：提交**

```bash
git add lib/state/session_controller.dart lib/ui/panels/editor_panel.dart test/state/session_controller_test.dart test/ui/editor_panel_test.dart
git commit -m "fix(ui): 断线告警不再说「未发送」（决策③）

QueueDropped.count 含在途那一条，它已经写到设备上了。事件载荷不变，
只改文案；顺带把编辑区那条不可达的 QueueDropped 分支接上。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 14：spec §13.21 的两笔顺手项

**为什么做：** 两笔 5b-1 记下、留给 5b-2 的欠账，都不大，但都是"代码与注释互相矛盾"的形状 —— 那种东西留着，下一个人会照着注释推理。

**Files:**
- Modify: `lib/connection/telnet_session.dart:47-57`
- Modify: `lib/connection/session.dart`（`close()` 的文档）
- Test: `test/connection/telnet_session_test.dart`（追加 + 给夹具加计数）

- [ ] **Step 1：给测试夹具加一个"拨过号没有"的记录**

`test/connection/telnet_session_test.dart` 的 `_GatedConnector`：

```dart
class _GatedConnector implements Connector {
  _GatedConnector(this.result);

  final Future<Connection> result;

  @override
  Future<Connection> open(String host, int port, {Duration? timeout}) => result;
}
```

换成：

```dart
class _GatedConnector implements Connector {
  _GatedConnector(this.result);

  final Future<Connection> result;

  /// 被要求拨号的目标。**"有没有拨过号"是几条例外的唯一观测点** ——
  /// 只看 `close()` 的副作用分不出"拨了又关掉"与"压根没拨"。
  final opened = <String>[];

  @override
  Future<Connection> open(String host, int port, {Duration? timeout}) {
    opened.add(host);
    return result;
  }
}
```

- [ ] **Step 2：写失败的测试**

在 `test/connection/telnet_session_test.dart` 的 `main` 末尾追加：

```dart
  test('close() 之后再 connect() 必须直接返回，不能再拨号（§13.21-2）', () async {
    // 原实现把 `if (_closed)` 放在 `connector.open` **之后**：close() 之后
    // 再来一次 connect() 会照常向设备发起 TCP 连接，然后走完那道守卫正常
    // 返回 —— 一个已关闭的会话对外报"连上了"。`SshSession` 早就是对的
    // （入口在最顶上），这条是补上 Telnet 这一侧，与它对称。
    final gate = Completer<Connection>();
    final connector = _GatedConnector(gate.future);
    final session = TelnetSession(profile: _profile(1), connector: connector);

    // **`close()` 不 await。** 这条会话从没连上，`_dataBytes` 没有监听者，
    // 它的 close() 会一直挂着（见 close() 里的注释）。而 `_closed` 在第一个
    // await 之前就已置真，所以下面那次 connect 看到的是"已关闭"。
    unawaited(session.close());
    await Future<void>.delayed(Duration.zero);

    await session.connect().timeout(const Duration(seconds: 2));

    expect(connector.opened, isEmpty, reason: '已关闭的会话绝不能再向设备发起连接');
  });
```

Run: `flutter test test/connection/telnet_session_test.dart`
Expected: FAIL —— 超时（`TimeoutException after 0:00:02`）。**这次超时正是缺陷的形状**：少了入口守卫，`connect()` 会挂在那个永远不会完成的 `gate.future` 上。

- [ ] **Step 3：把入口守卫挪到拨号之前**

`lib/connection/telnet_session.dart` 的 `connect()`：

```dart
  @override
  Future<void> connect() async {
    final conn =
        await connector.open(profile.host, profile.port, timeout: connectTimeout);
    // 建连期间可能已经被 close()（用户切设备、关窗口）。此时必须把刚拿到的
    // 连接关掉并直接返回，否则 socket 泄漏，且 _dataBytes 已关闭，后续
    // _onBytes 里的 add 会抛 "Cannot add event after closing"。
    if (_closed) {
      await conn.close();
      return;
    }
    _conn = conn;
```

换成：

```dart
  @override
  Future<void> connect() async {
    // **入口守卫（spec §13.21-2）。** 已经关闭的会话绝不能再拨号：少了它，
    // close() 之后再来一次 connect() 会照常向设备发起 TCP 连接，然后走下面
    // 那道守卫正常返回 —— 一个已关闭的会话对外报"连上了"。与 `SshSession`
    // 的入口守卫对称。
    if (_closed) return;

    final conn =
        await connector.open(profile.host, profile.port, timeout: connectTimeout);
    // **这一道仍然要留。** 上面那道管的是"调 connect 时已经关了"，这一道管的是
    // "**建连期间**被 close()"（用户切设备、关窗口）—— 两者是不同的时刻。
    // 此时必须把刚拿到的连接关掉并直接返回，否则 socket 泄漏，且 _dataBytes
    // 已关闭，后续 _onBytes 里的 add 会抛 "Cannot add event after closing"。
    if (_closed) {
      await conn.close();
      return;
    }
    _conn = conn;
```

- [ ] **Step 4：补 `Session.close()` 的契约（spec §13.21-4）**

`lib/connection/session.dart` 的

```dart
  /// 关闭会话。
  Future<void> close();
```

换成：

```dart
  /// 关闭会话。
  ///
  /// **`connect()` 失败之后，调用方仍然必须调它。** 两个实现都在 `connect()`
  /// 里分配了资源（`_dataBytes`/`_output` 两个 `StreamController`，Telnet 侧
  /// 还可能有一个已经拿到的连接），而"连不上"是最常见的路径之一 ——
  /// `ConnectionManager` 每次都靠 [close] 来收尾。契约原先没写这一条，
  /// 于是"connect 抛了，那就不用 close 了吧"看起来是合理的，而它会让
  /// 那些 `StreamController` 永远挂着（spec §13.21-4）。
  ///
  /// `close()` 是幂等的：已经关过的会话再关一次直接返回。
  Future<void> close();
```

- [ ] **Step 5：跑测试，确认全绿**

Run: `flutter test test/connection/telnet_session_test.dart test/connection/ssh_session_test.dart test/connection/connection_manager_test.dart`
Expected: PASS

⚠ 原来那条 `connect 等待期间被 close：连接被关闭且没有异常逃逸到 zone` **必须仍然是绿的** —— 它验的是"建连期间被 close"，走的正是**下面**那道守卫（调用顺序是先 `connect()` 再 `close()`，所以入口处 `_closed` 还是 false）。它若红了，说明入口守卫被错写成了唯一的一道。

- [ ] **Step 6：跑一遍全仓**

Run: `flutter test`
Expected: PASS

- [ ] **Step 7：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 8：提交**

```bash
git add lib/connection/telnet_session.dart lib/connection/session.dart test/connection/telnet_session_test.dart
git commit -m "fix(conn): Telnet 入口守卫挪到拨号之前，并补 close() 的契约（§13.21-2/4）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 15：收尾

**Files:**
- 不改代码。这一步是验收。

- [ ] **Step 1：全仓测试**

Run: `flutter test`
Expected: PASS。**记下通过数** —— 5b-1 收尾时是 510 通过 + 3 跳过。

- [ ] **Step 2：静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 3：NFR-M-01 的 grep**

Run: `grep -rn "print(" lib/ ; grep -rn "debugPrint(" lib/`
Expected: 无输出（5b-1 收尾时也是无输出）。

- [ ] **Step 4：golden 全量重生成并人工过目**

本计划的 Task 3（编辑区 +命令库）、Task 7（编辑区 +导入文件）、Task 8（编辑区 +同步到另一台）与 Task 9（主窗口 AppBar +设置）都改了像素，**每一步当时都已经重生成了**（Task 3 的 Step 9b、Task 7 的 Step 8b、Task 8 的 Step 7b、Task 9 的 Step 6）。这一步是最后一遍确认：**没有一张漏在中间**。若有哪张的 mtime 早于它对应的那次改动，说明那一步被跳过了 —— 补上。

Run: `WCT_GOLDEN=1 flutter test test/ui/main_window_golden_test.dart --update-goldens`
Expected: PASS，且 `git status` 显示 `test/ui/golden/` 下的改动。

**逐张开图确认**（这是这一步的全部价值）：

| 图 | 该看到什么 |
|---|---|
| `main_window_light.png` / `_dark.png` | AppBar 上是「设置」齿轮 + 「＋」，顺序为齿轮在左 |
| `editor_panel.png` | 工具栏上「连接 / 断开 / 发送」之后多出「命令库 / 导入文件 / 同步到另一台」三个图标 |
| `device_list_panel.png` | 与 5b-1 一致（本计划没动它） |
| `output_panel.png` | 与 5b-1 一致 |

**有一张对不上就先查清为什么，别直接提交。** golden 的全部价值在"人看过"。

- [ ] **Step 5：真机冒烟**

**⚠ 不要动 `~/.local/share/com.example.win_cli_tool/`** —— 那是用户的真实数据目录。用 `XDG_DATA_HOME` 把应用数据指到一个临时目录。

```bash
flutter build linux --release
rm -rf /tmp/wct-smoke-data && mkdir -p /tmp/wct-smoke-data
XDG_DATA_HOME=/tmp/wct-smoke-data DISPLAY=:11 \
  ./build/linux/x64/release/bundle/win_cli_tool &
sleep 12
DISPLAY=:11 xwininfo -root -tree | grep -i win_cli
```

从上面那条的输出里找到**子窗口**（形如 `0x3000002 "win_cli_tool"`，1280x720 —— 名字匹配的那个 10x10 的是没映射的 GTK group leader，别截它），然后：

```bash
DISPLAY=:11 import -window <那个 id> /tmp/wct_5b2_smoke.png
ls -la /tmp/wct_5b2_smoke.png
```

Expected：PNG 是 1280x720 的真图（不是 586 字节、2 色的空白图）。

**用 release 产物截图**，不要用 debug —— debug 的 `DEBUG` 角标斜带正好压住 AppBar 右上角那块像素，会把「＋」看成没有了（那不是产品缺陷，是角标的锅）。

**这一步证明了什么、没证明什么：**

- **证明了**：应用在这台机器上能起来、能渲染，主窗口的 AppBar 上有「设置」齿轮与「＋」，空设备列表下正文是「请先添加一台设备」。
- **没证明**：有设备时的界面。造一台设备要键盘输入，而这台机器**没有** `xdotool`/`xte` 之类的合成输入工具 —— 那部分由 golden 覆盖（上面那五张图就是它的样子）。
- **没证明**：未决项 14（"打字之后在 500ms 防抖窗口内关窗，重开还在不在"）。它同样需要键盘输入。**如实记成"本机无法用真机验证"**，不要写成"已验证"。

收尾：杀掉那个进程（`pkill -f 'bundle/win_cli_tool'`），删掉 `/tmp/wct-smoke-data`。

- [ ] **Step 6：把结果交给控制者，不要自己写计划**

**不要**编辑 `docs/superpowers/plans/` 下的任何文件 —— 计划是被评审的产物，验收记录由控制者追加。

把你手上这些**原始输出**交给控制者：

1. `flutter test` 的最后一行（通过数）；
2. `dart analyze lib/ test/` 的输出；
3. 那两条 grep 的结果；
4. `WCT_GOLDEN=1 ... --update-goldens` 的结果与 `git status` 里 golden 的改动清单；
5. 冒烟截图的路径与 `ls -la` 的输出，以及**你从图里看到了什么**（一句话）；
6. 未决项 14 的处置（"本机无法用真机验证"，以及为什么）。

控制者会把它写成「5b-2 收尾验收记录」追加到本计划末尾，并按惯例更新记忆。

---

## 自检

**1. Spec 覆盖**

| 需求 | 落在哪个任务 |
|---|---|
| FR-D-01 新增设备 | Task 6（`_addDevice` 接真对话框） |
| FR-D-02 保存/取消 | Task 4 |
| FR-D-03 协议/端口/默认端口 | Task 4 |
| FR-D-04 名称唯一 | Task 4 |
| FR-D-05 编辑已有设备 | Task 4、Task 6（右键「编辑」） |
| FR-D-11 登录后执行 | Task 4 |
| FR-D-12 启动时自动连接 | Task 4（5a 已实现消费端） |
| FR-C-05 断开 | Task 4（对话框内「断开」）、Task 6（右键「断开」） |
| FR-C-06 连接失败变红 | **Task 12** |
| FR-C-10 丢弃不重放 + 告警文案 | **Task 13** |
| FR-C-11 首次连接确认指纹 | **Task 11** |
| FR-C-13 建连超时可调 | Task 9 |
| FR-E-15/16 导入文件 | Task 7 |
| FR-E-17 同步到另一台 | Task 8 |
| FR-G-01 设置项 | Task 9（八项）+ Task 10（已知主机密钥区） |
| FR-G-02 设置持久化 | 5a 已实现；Task 9 的「取消」用例守着它没被写坏 |
| FR-G-03 行尾符 / 提示符正则 | Task 4 |
| FR-S-01…04 命令库 | Task 3 |
| NFR-S-01 凭据接口封装 | 5a 已实现（`AppStores.credentials`）；本计划不碰 |
| NFR-S-02 明文警告 | **Task 4** |
| NFR-S-03 主机密钥校验默认开启 | Task 11（`verifyHostKey` 的接线 5a 已有；本任务补上缺的那一半） |
| §13.7 `Snippet` 值相等 | Task 1 |
| §13.21-2 Telnet 入口守卫 | Task 14 |
| §13.21-4 `close()` 契约 | Task 14 |
| §5.4 按钮颜色 | 颜色映射 5b-1 已有（`status_dot.dart`）；本计划改的是**红何时可达**（Task 12） |
| §7.1 主窗口 | Task 6（右键）、Task 9（设置入口） |
| §7.3 设备列表右键四项 | Task 6 |

**没有任务覆盖、且是有意为之的：** 日志相关（用户已决定"保持现状、不再投入"）；`outputBufferLines` 与 `deviceListWidth` 进设置（不在 FR-G-01 清单里，理由写在 Task 9）；跳板机（已放弃）。

**2. 占位符扫描**

本计划里没有 "TBD" / "TODO" / "类似 Task N" / "加上适当的错误处理" 这类写法。每一个改代码的步骤都给了完整代码。有三处**刻意的"以现名为准"**，都不是占位符，是"计划的作者看不到那个文件的当前内容"：

- Task 4 Step 1 里 `pumpDialogHost` 依赖 `pumpUi` 的既有签名（已逐字核对）。
- Task 6 Step 1 里 `device_list_panel_test.dart` 的辅助函数名（`pumpPanel` / `openMenu`）—— 若实际名字不同，**只改名字，别改断言**。
- Task 6 Step 5 里 `main_window_test.dart` 的 `pumpWindow`（已核对存在）。

**3. 类型与命名一致性**

- `pumpDialogHost`（Task 4 定义）在 Task 7/8/9 里被使用，签名一致：`(tester, {required root, required buttonLabel, required open, devices, settings, factory, extra})`。
- `ImportMode`（Task 7）、`SyncMode`/`SyncResult`（Task 8）、`HostKeyPrompt`/`HostKeyPromptNotifier`（Task 11）各自只定义一次。
- `connectionParamsDiffer`（Task 5）在 Task 5 内定义并使用，没有别处引用。
- `KnownHostsSection`（Task 10 定义）在 Task 10 Step 4 被接进 `SettingsDialog`。
- 文本 API：`insertAtCursor` / `replaceAllText` / `appendText`（Task 2 定义）被 Task 3 与 Task 7 使用，名字一致。
- `_setText` 是 Task 2 的私有方法，Task 7/8 不直接调它（都走那三个公开方法）。
- `ValueKey` 命名前后一致：`device-*`（Task 4/5）、`settings-*`（Task 9）、`known-host*`（Task 10）、`import-path`（Task 7）、`sync-target`（Task 8）、`snippet-*`（Task 3）。

**四处誊抄时踩过的坑（都在写入本计划时改掉了，实施者照着抄就行）：**

- **Task 1 的测试用例里，比较的两个操作数必须是非 const 构造的。** 这是本计划里最危险的一处：初稿写成 `const a = Snippet(同样参数); const b = Snippet(同样参数);`，而 Dart 会把参数相同的 const 字面量**规范化成同一个实例**，`Object.==` 按身份答 true —— 四条用例在**完全没实现** `==` 的情况下全绿，等于零守备。Task 1 的 Step 1 现在一律用 `Snippet.fromJson(...)` 造副本，并额外断言 `identical(a, b)` 是 false 把前提钉住。**这是 Task 1 实施者实测报上来的，不是推理出来的。**
- **Task 7 的测试文件要 `import 'package:flutter_riverpod/misc.dart';`** —— `readerOf` 的返回类型是 `List<Override>`，而 `Override` 不在 `flutter_riverpod.dart` 的主入口里（3.4.3 实测；`ui_harness.dart` 开头那段注释就是为这件事写的）。少这一行，红的是 `non_type_as_type_argument`。
- **Task 8 的 `syncAs` 里不能有 `tester.enterText`** —— `sync-target` 是 `DropdownButtonFormField`，不是输入框；`enterText` 找不到 `EditableText` 会直接抛。选目标只能"点开、再点那一项"。
- **`DropdownButtonFormField.initialValue` 是本版 Flutter 的正确参数名**（`value` 已废弃）。且 `setState` 之后显示会跟着变 —— `dropdown.dart:2004` 的 `didUpdateWidget` 里有 `if (oldWidget.initialValue != widget.initialValue) setValue(...)`。Task 8/9 的三处下拉都靠这一条。
- **双击区域里不能包着别的按钮（Task 3）。** `DoubleTapGestureRecognizer` 在第一次按下时会 `gestureArena.hold(pointer)`（`gestures/multitap.dart:330`），把手势竞技场按到双击超时（300ms）为止。所以 `GestureDetector(onDoubleTap:)` 里**但凡裹着一个 `IconButton`**（初稿是把它当 `ListTile.trailing`），那个按钮的单击就要等满 300ms 才生效，双击它还会顺带触发插入。初稿在测试里表现为"点了编辑/删除，对话框 0 个"—— 而 `pumpAndSettle()` 在 ~100ms 后就没帧可等了，hold 还没释放，于是永远等不到。修法是把按钮挪出 `GestureDetector` 的子树（`Row(Expanded(双击区), 按钮, 按钮)`）。**这是 Task 3 实施者实测报上来的。**
- **改编辑区工具栏的 Task 一次要重生成三张 golden**，不是一张：`main_window_light.png` 与 `main_window_dark.png` 里也含着那条工具栏（实测三张各差 226 像素）。Task 3/7/8 的 `git add` 清单都已按这个改过 —— 漏掉的那两张会以"改了但没进提交"的形式留在工作区，然后被下一次 `--update-goldens` 悄悄吞掉。
- **断言要问"组件在不在"，不是"里面某句文案在不在"（Task 3）。** 初稿用 `find.text('还没有命令片段')` 来证明抽屉关上了，而被测设备**有**片段，那句话在它的抽屉里根本不会渲染 —— 这条断言恒真，抽屉关没关都绿。正确的问法是 `find.byType(SnippetDrawer)`。和上面 Task 1 那条是同一类病：**断言在测空气。**
- **`findsOneWidget` 撞上"同一句话说了两遍"（Task 4）。** 「NFR-S-02 的警告就在对话框里」初稿写的是 `find.textContaining('明文')`，而设计里**有意**在两个地方点了「明文」：那条警告，和密码框的标签「密码（明文保存）」。实测（本机 3.44.4，用一个只含这两样东西的 scratch 用例跑出来的）：`Found 2 widgets with text containing 明文`，`findsOneWidget` 直接红。**断言用宽泛的短语去数一个"有意重复出现"的词，是这一类红的来源。**
- **构造函数里没写出来的字段会走默认值，编辑对话框于是变成"静默清字段"（Task 4）。** `DeviceProfile` 除了对话框要编辑的那十来项，还有 `jumpHostIds`（默认 `const []`）。`_submit` 里那份 `DeviceProfile(...)` 初稿没写它 —— 于是编辑任何一台设备都会把盘上那条跳板机链抹成空，没有任何提示。`snippets` 那一行本来就带着注释说"不让 update 把它抹掉"，`jumpHostIds` 是同一个坑漏掉的一个。**写编辑类对话框时，把模型的字段表对着构造函数数一遍。**
- **长对话框在默认窗口里点不到靠下的控件；等 SnackBar 不能靠推帧（Task 4）。** 这两条各让 2 条和 1 条用例红在**对话框之外**（`tap` 空点、SnackBar 没等到），而代码是对的 —— 也就是说**红的位置会指向错误的方向**。修法分别是 `useTallSurface` 与 `pumpUntilSnackBar`（都在 `ui_harness.dart`），细节见前面「测对话框之前必须先知道的两件事」。Task 5/6/7/9 的用例照用。
- **让会话保持连接到用例结束的用例，收尾要 `drainCommandTimeout(tester)`（Task 5）。** 同样红在断言之外：`flutter_test` 在用例体跑完后断言 `!timersPending`，而连接时排进队列的 `postLoginCommands` 起了一个 10s 命令超时定时器，`FakeSession` 不吐提示符所以它一直挂着。**同一个文件里"会断开的用例绿、不断开的用例红"就是它的指纹** —— 代码和断言都是对的。见地基第 3 条。Task 6 的「连接」菜单用例尤其要当心。

**一条通用教训（值得单独记着）：** 「分析器干净」这条验收门比它看起来严 —— `unnecessary_null_comparison`（warning）与 `unrelated_type_equality_checks`（**info**）都会让 `dart analyze` 打印 `1 issue found` 而不是 `No issues found!`。写断言时对**静态类型已知**的比较（非空对象与 `null`、无关类型之间）要格外小心。

**4. 与既有代码的口径核对（本计划的作者逐条读过源码）**

| 计划里写的 | 出处 |
|---|---|
| `_attempt == 0` = 首次失败 | `connection_manager.dart`（成功时归零、`disconnect()` 里归零） |
| 掉线后 1s 重连时状态是 `reconnecting` 而非 `connecting` | `_attemptConnect` 开头按 `_attempt` 选，掉线时已自增到 1 |
| `QueueDropped.count` 含在途那条 | `command_dispatcher.dart:208`；`connection_manager_test.dart:534` 断言 `[2]` |
| `QueueAborted.dropped` **不含**在途那条 → 它的「未发送」是对的，不改 | `command_dispatcher.dart:185-198` |
| `DuplicateDeviceNameError.message` 是可直接展示的中文 | 那个类的文档 |
| `AppSettings.copyWith(logDir: null)` 能真的清掉 | `_unset` 哨兵 |
| `FileHostKeyStore` 不持实例缓存 → 测试里可以用第二个实例预置 | 它 `_readFromDisk` 的文档 |
| `AppStores.hostKeys` 的静态类型是 `FileHostKeyStore` → 不需要向下转型 | `app_stores.dart` |
| `EditorPanel._toolbar` 的 `Spacer` 在按钮之后 | `editor_panel.dart:363`（**Task 2 已落地，行号从 303 移到了 363**；按内容 grep，别信旧行号） |
| 手势竞技场会被双击识别器 hold 住 | `gestures/multitap.dart:330` `_registerFirstTap` 里的 `gestureArena.hold(tracker.pointer)` |
| 没有 `endDrawer` 时 `openEndDrawer()` 是静默无操作 | `scaffold.dart:2310` = `_endDrawerKey.currentState?.open();`（`?.` 不是 `!`） |
| 编辑区 `_loadDraft` 经 `draftProvider` 读 → 写也必须经它 | `editor_panel.dart` 的 `_loadDraft` |

---

## 执行交接

计划已写完，保存于 `docs/superpowers/plans/2026-09-26-ui-dialogs-and-snippets.md`。

**按用户已下达的 `按1执行`：走 Subagent-Driven Development** —— 每个任务一个全新的实施者子代理，任务之间由控制者评审，**任务之间不停下来问**。允许的停止只有三种：无法解决的 BLOCKED、真正挡住进展的歧义、全部任务完成。

给每一个实施者子代理的**固定约束**（逐字，不可省）：

- **不要跑 `dart format`**；
- 不要读 `/tmp/wct-plan2-check`、不要读 `/tmp/wct-plan4-findings.md`；
- 不要改 `git config user.email`、不要 push、不要配置 remote、不要改写历史（no rebase/amend/reset）；
- **不要编辑 `docs/superpowers/plans/` 下的任何文件**（计划是被评审的产物，由控制者拼接）；
- 用 `flutter test`，**绝不用 `dart test`**；
- **绝不并发跑两个 `flutter test`**（spec §13.23：锁竞争曾经造成 13 分钟卡死）；
- 按显式路径 `git add`，**绝不用 `git add -A`**；
- 提交信息末尾加 `Co-Authored-By: Claude Code <noreply@anthropic.com>`；
- **子代理的报告没有用户授权**：若某段代码看起来是错的，**停下来报告**，不要就地打补丁、也不要把断言改弱。

**执行顺序**：严格按依赖图，**从 Task 1 开始，一个都不跳过**：1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15。

⚠ **15 个任务一个都没实现过。** 任务 1–3 只是"在写这份计划时最先落笔的三段"，不是"已经做完的三段"。落笔时逐条核对过它们的目标现状（`Snippet` 在 `device_profile.dart:26-50` 且确实没有 `==`；`editor_panel.dart` 确实没有 `insertAtCursor`/`replaceAllText`/`appendText`；`test/models/device_profile_test.dart:235` 的 `group('Snippet')` 里确实只有一条 JSON 往返用例），三处的"为什么做"都成立 —— 也就是说 **Task 1/2/3 都还有活要干**。

**已知的验证欠账（不在本计划内，如实记着）**：5a 的 Tasks 1–6 的 diff 没有被独立复读过；5b-1 的每一个 diff 也没有独立评审。这本计划同样按用户 `停止测试，先完成剩余编码` 的指示执行 —— **只跑实施者，不跑独立评审**。
