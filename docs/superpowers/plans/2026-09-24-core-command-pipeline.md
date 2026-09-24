# 核心命令链路 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建成一个纯 Dart 的核心库：通过 Telnet 连接网络设备，把一串命令**逐条串行下发**，用「提示符识别 + 静默去抖」判定每条命令何时执行完，并自动处理分页提示。

**Architecture:** 自下而上四层。`Connector` 负责"建立一条到 host:port 的双向字节流"（为计划 2 的跳板机预留注入点）；`TelnetProtocol` 是无 IO 的纯状态机，负责 IAC 协商与序列剥离；`TelnetSession` 把前两者组装成一个产出 `Stream<String>` 的会话；`CommandDispatcher` 消费这个流，配合 `PromptDetector` 与 `MorePager` 驱动命令队列。**所有核心逻辑都不依赖 Flutter**，可用 `flutter test` 快速验证。

**Tech Stack:** Flutter 3.44.4 / Dart 3.12.2、`dart:io`、`dart:async`、`dart:convert`、`flutter_test`（测试框架）、`fake_async` 1.3.3（时间控制）

**对应 spec：** [`docs/superpowers/specs/2026-09-24-win-cli-tool-requirements.md`](../specs/2026-09-24-win-cli-tool-requirements.md)

**本计划覆盖的需求条目：** FR-D-01~03（设备参数）、FR-E-08（空行跳过）、FR-E-09（行尾符）、FR-E-10（串行下发）、FR-E-11（完成判定，即 §5.2）、FR-E-12（超时放行）、FR-E-13（中止队列）、FR-C-10（断线丢弃队列）、§5.2（提示符判定）、§5.3（翻页处理）

---

## 环境前提（已核实）

| 项 | 状态 |
|---|---|
| Flutter | 3.44.4 stable，Dart 3.12.2 |
| `enable-linux-desktop` | `true`，可直接跑桌面应用 |
| `enable-windows-desktop` | `(Not set)` —— **不影响本计划**，见下 |
| Linux toolchain | ✓ 可用 |
| `fake_async` | 1.3.3（要求 sdk `^3.3.0`，兼容） |
| `flutter create` 生成的 `flutter_lints` | `^6.0.0` |

**已实测确认的两条环境事实**（避免执行时踩坑）：

1. `flutter create --platforms=windows,linux .` 在 Linux 主机上**无需**先执行 `flutter config --enable-windows-desktop`，即可生成完整的 `windows/` 平台目录。
2. `flutter create` **不会**覆盖已存在的 `.gitignore`，本仓库手写的那份（含 `.superpowers/`）是安全的。

**重要约束：** 目录名 `win-cli-tool` 含连字符，**不是合法的 Dart 包名**，因此 `flutter create` 必须显式传 `--project-name win_cli_tool`。

**平台约束：** 开发在 Linux 上进行，但 `flutter build windows` **必须在 Windows 主机上执行**。Linux 上只能构建并运行 Linux 产物用于验证。这一约束会影响计划 6（打包与 CI）的设计。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `pubspec.yaml` | 依赖声明 |
| `lib/models/device_profile.dart` | `DeviceProtocol` / `JumpHost` / `Snippet` / `DeviceProfile` 数据模型与 JSON 编解码 |
| `lib/models/app_settings.dart` | `AppSettings` 全局设置模型与 JSON 编解码 |
| `lib/connection/connector.dart` | `Connection` / `Connector` 抽象 + `DirectConnector` 直连实现 |
| `lib/connection/session.dart` | `Session` 抽象接口 |
| `lib/connection/telnet_protocol.dart` | Telnet IAC 协商纯状态机（无 IO） |
| `lib/connection/telnet_session.dart` | `TelnetSession`，基于 `Connector` 的会话实现 |
| `lib/render/ansi.dart` | `stripAnsi()`：剥离 ANSI 控制序列（计划 3 会在此文件上扩展出 SGR 解析） |
| `lib/command/prompt_detector.dart` | 判定缓冲区末尾是否为设备提示符 |
| `lib/command/more_pager.dart` | 判定缓冲区末尾是否为翻页提示 |
| `lib/command/command_dispatcher.dart` | 命令队列 + 串行状态机 + 超时 + 中止 + 断线处理 |
| `test/fixtures/fake_device_server.dart` | 假设备服务器：可配置提示符、分页、挂起、协商 |
| `test/e2e/dispatch_e2e_test.dart` | 端到端：真 TCP + 假设备 + 完整下发链路 |

设计要点：`Connector` 是计划 2（跳板机）的注入点；`DeviceProfile` 一次定义完整字段，避免后续计划反复改模型；`lib/render/ansi.dart` 一开始只有 `stripAnsi`，因为提示符判定必须能穿透 ANSI 颜色码。

---

## Task 1: 项目骨架

**Files:**
- Create: `pubspec.yaml`、`lib/`、`test/`、`windows/`、`linux/`（由 `flutter create` 生成）
- Modify: `pubspec.yaml`（加依赖）
- Delete: `test/widget_test.dart`（默认模板，会编译失败）

- [ ] **Step 1: 生成 Flutter 项目骨架**

必须在项目根目录执行。两个要点：

- **必须传 `--project-name`**：目录名 `win-cli-tool` 含连字符，不是合法的 Dart 包名，不传这个参数 `flutter create` 会直接报错。
- **不需要先执行 `flutter config --enable-windows-desktop`**：已实测确认，在 Linux 主机上直接指定 `--platforms=windows,linux` 就能生成完整的 `windows/` 平台目录（含 `CMakeLists.txt` 与 `runner/`）。

```bash
cd /home/lwliu/Projects/win-cli-tool
flutter create --project-name win_cli_tool --org com.example --platforms=windows,linux .
```

Expected：输出 `All done!`，并生成 `lib/main.dart`、`test/widget_test.dart`、`pubspec.yaml`、`windows/`、`linux/`。

> **注意（影响计划 6 打包）**：生成的 `windows/` 只是工程脚手架，**在 Linux 上无法构建 Windows 产物** —— `flutter build windows` 必须在 Windows 主机上执行。Linux 主机上只能构建 Linux 产物，用于日常开发验证。

- [ ] **Step 2: 确认 .gitignore 未被改动**

`flutter create` **不会**覆盖已存在的 `.gitignore`（已实测：预先放入自定义内容后执行 `flutter create`，文件内容原样保留）。这一步只是确认。

```bash
git status --short .gitignore
git diff --stat .gitignore
```

Expected：两条命令都无输出 —— `.gitignore` 未被修改。若确有改动，用 `git checkout .gitignore` 还原。

- [ ] **Step 3: 删除默认测试文件**

默认的 `test/widget_test.dart` 引用模板里的计数器 App，与我们后续的改动不兼容，会让 `flutter test` 失败。

```bash
rm -f test/widget_test.dart
```

- [ ] **Step 4: 声明依赖**

编辑 `pubspec.yaml`，在 `dev_dependencies` 下**新增** `fake_async`，其余条目保持 `flutter create` 生成的原样（`flutter_lints` 的版本号随 Flutter 版本而变，不要照抄）：

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0   # ← 保留文件里已有的版本号，不要改
  fake_async: ^1.3.3      # ← 新增这一行
```

**为什么用 `flutter_test` 而不是 `package:test`：** `flutter_test` 已导出完整的测试框架（`test` / `group` / `expect` / `setUp`），而且它与 `package:test` 对 `test_api` 的版本约束容易冲突。纯 Dart 测试也能在 `flutter test` 下正常跑。

**为什么显式声明 `fake_async`：** 它是 `flutter_test` 的传递依赖，但直接 import 的包必须显式声明。

- [ ] **Step 5: 拉取依赖并验证**

```bash
flutter pub get
flutter analyze
```

Expected：`pub get` 成功；`flutter analyze` 输出 `No issues found!`（`lib/main.dart` 是模板代码，可以保留）。

- [ ] **Step 6: 建立目录结构**

```bash
mkdir -p lib/models lib/connection lib/render lib/command
mkdir -p test/fixtures test/models test/connection test/command test/render test/e2e
```

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "chore: 初始化 Flutter 项目骨架

- 生成 windows/linux 桌面平台工程
- 依赖：flutter_test + fake_async
- 建立 models/connection/render/command 目录结构

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 2: 数据模型

**Files:**
- Create: `lib/models/device_profile.dart`
- Create: `lib/models/app_settings.dart`
- Test: `test/models/device_profile_test.dart`
- Test: `test/models/app_settings_test.dart`
- Delete: `lib/models/.gitkeep`、`test/models/.gitkeep`（已被真实文件取代）

一次定义完整字段，避免后续计划（跳板机、持久化、界面）反复修改模型。JSON 编解码也放在这里，因为它是模型契约的一部分；计划 4 只负责文件 IO 与迁移。

**可空字段的 `copyWith` 必须用哨兵，不能用 `x ?? this.x`。** 对 `password`、`privateKeyPath`、`promptRegex`、`logDir` 这四个字段来说，**null 本身就是一个有语义的值**（不启用密码认证 / 不启用密钥认证 / 用全局默认提示符正则 / 用默认日志目录），而不是「调用方没传这个参数」。用 `?? this.x` 会把用户「清空」的操作静默地变成「保持原值」，且返回的是一个完全合法的对象，不报任何错。后果直接落在后两个计划的 FR 上：

- **FR-D-05**「编辑已有设备的任意字段」：用户清掉密码改用密钥认证 → 旧密码仍在明文配置里（NFR-S-01 已确认 V1 凭据明文存储），且界面上没有任何地方还能看到它。
- **FR-G-03**：用户取消勾选「设备级提示符正则」以回落全局默认 → 旧正则仍在生效，实际提示符判定行为与界面显示不一致，故障点离原因隔了两层。
- **FR-G-01** `logDir`、以及 `privateKeyPath`：同样一旦设过就再也回不到默认。

哨兵写法给出三种状态：不传 → 保留、显式传 `null` → 清空、传值 → 覆盖。

- [ ] **Step 1: 写失败的测试**

创建 `test/models/device_profile_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/device_profile.dart';

void main() {
  group('DeviceProtocol', () {
    test('默认端口：ssh 为 22，telnet 为 23', () {
      expect(DeviceProtocol.ssh.defaultPort, 22);
      expect(DeviceProtocol.telnet.defaultPort, 23);
    });

    test('未知协议名抛出 FormatException', () {
      expect(() => DeviceProtocol.fromName('ftp'), throwsFormatException);
    });
  });

  group('DeviceProfile', () {
    test('未指定的字段使用规范默认值', () {
      const p = DeviceProfile(
        id: 'd1',
        name: '核心交换机',
        protocol: DeviceProtocol.telnet,
        host: '10.0.0.1',
        port: 23,
        username: 'admin',
      );

      expect(p.lineEnding, '\n');
      expect(p.promptRegex, isNull);
      expect(p.jumpHostIds, isEmpty);
      expect(p.postLoginCommands, isEmpty);
      expect(p.autoConnect, isFalse);
      expect(p.snippets, isEmpty);
      expect(p.password, isNull);
      expect(p.privateKeyPath, isNull);
    });

    test('JSON 往返后所有字段保持一致', () {
      const original = DeviceProfile(
        id: 'd1',
        name: '核心交换机',
        protocol: DeviceProtocol.ssh,
        host: '10.1.1.1',
        port: 22,
        username: 'admin',
        password: 'secret',
        privateKeyPath: '/home/u/.ssh/id_rsa',
        jumpHostIds: ['j1', 'j2'],
        lineEnding: '\r\n',
        promptRegex: r'[>#]\s*$',
        postLoginCommands: ['enable', 'terminal length 0'],
        autoConnect: true,
        snippets: [
          Snippet(id: 's1', name: '保存配置', content: 'save\nY'),
        ],
      );

      final restored = DeviceProfile.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.protocol, DeviceProtocol.ssh);
      expect(restored.host, original.host);
      expect(restored.port, original.port);
      expect(restored.username, original.username);
      expect(restored.password, original.password);
      expect(restored.privateKeyPath, original.privateKeyPath);
      expect(restored.jumpHostIds, ['j1', 'j2']);
      expect(restored.lineEnding, '\r\n');
      expect(restored.promptRegex, r'[>#]\s*$');
      expect(restored.postLoginCommands, ['enable', 'terminal length 0']);
      expect(restored.autoConnect, isTrue);
      expect(restored.snippets, hasLength(1));
      expect(restored.snippets.first.name, '保存配置');
      expect(restored.snippets.first.content, 'save\nY');
    });

    test('copyWith 只改指定字段', () {
      const p = DeviceProfile(
        id: 'd1',
        name: 'A',
        protocol: DeviceProtocol.telnet,
        host: '10.0.0.1',
        port: 23,
        username: 'admin',
      );

      final q = p.copyWith(name: 'B', port: 2323);

      expect(q.name, 'B');
      expect(q.port, 2323);
      expect(q.host, '10.0.0.1');
      expect(q.id, 'd1');
    });

    test('copyWith 不传参时保留原值（原值为 null 也保留）', () {
      const p = DeviceProfile(
        id: 'd1',
        name: 'A',
        protocol: DeviceProtocol.ssh,
        host: '10.0.0.1',
        port: 22,
        username: 'admin',
        password: 'pw',
        promptRegex: r'[>#]\s*$',
      );

      final q = p.copyWith(name: 'B');

      expect(q.password, 'pw');
      expect(q.promptRegex, r'[>#]\s*$');
    });

    test('copyWith 能把可空字段显式清回 null', () {
      const p = DeviceProfile(
        id: 'd1',
        name: 'A',
        protocol: DeviceProtocol.ssh,
        host: '10.0.0.1',
        port: 22,
        username: 'admin',
        password: 'pw',
        privateKeyPath: '/home/u/.ssh/id_rsa',
        promptRegex: r'[>#]\s*$',
      );

      final q = p.copyWith(
        password: null,
        privateKeyPath: null,
        promptRegex: null,
      );

      expect(q.password, isNull);
      expect(q.privateKeyPath, isNull);
      expect(q.promptRegex, isNull);
      // 未指定的字段不受影响
      expect(q.name, 'A');
      expect(q.host, '10.0.0.1');
      expect(q.port, 22);
      expect(q.id, 'd1');
    });

    test('copyWith 能把可空字段从 null 设为新值', () {
      // 哨兵机制有三个分支：保留、清空、设新值。前两个由上面两个用例覆盖，
      // 这个覆盖第三个 —— 若只在保留/清空上正确而设新值有 bug，用户改的密码
      // 会被静默丢弃，且因为每次保存都丢掉，用户再编辑也救不回来。
      const p = DeviceProfile(
        id: 'd1',
        name: 'A',
        protocol: DeviceProtocol.ssh,
        host: '10.0.0.1',
        port: 22,
        username: 'admin',
      );

      final q = p.copyWith(password: 'new-pw', promptRegex: r'>>>\s*$');

      expect(q.password, 'new-pw');
      expect(q.promptRegex, r'>>>\s*$');
    });

    test('JSON 只有必填字段时，可选项回落到默认值（v1 配置迁移形状）', () {
      final restored = DeviceProfile.fromJson(const <String, Object?>{
        'id': 'd1',
        'name': '核心交换机',
        'protocol': 'telnet',
        'host': '10.0.0.1',
        'port': 23,
        'username': 'admin',
      });

      expect(restored.password, isNull);
      expect(restored.privateKeyPath, isNull);
      expect(restored.jumpHostIds, isEmpty);
      expect(restored.lineEnding, '\n');
      expect(restored.promptRegex, isNull);
      expect(restored.postLoginCommands, isEmpty);
      expect(restored.autoConnect, isFalse);
      expect(restored.snippets, isEmpty);
    });
  });

  group('JumpHost', () {
    test('JSON 往返', () {
      const j = JumpHost(
        id: 'j1',
        name: '堡垒机-A',
        host: '10.0.0.254',
        port: 22,
        username: 'ops',
        password: 'pw',
        privateKeyPath: '/home/ops/.ssh/id_ed25519',
      );

      final restored = JumpHost.fromJson(j.toJson());

      expect(restored.id, 'j1');
      expect(restored.name, '堡垒机-A');
      expect(restored.host, '10.0.0.254');
      expect(restored.port, 22);
      expect(restored.username, 'ops');
      expect(restored.password, 'pw');
      expect(restored.privateKeyPath, '/home/ops/.ssh/id_ed25519');
    });

    test('copyWith 保留与清空可空字段', () {
      const j = JumpHost(
        id: 'j1',
        name: '堡垒机-A',
        host: '10.0.0.254',
        port: 22,
        username: 'ops',
        password: 'pw',
        privateKeyPath: '/home/ops/.ssh/id_ed25519',
      );

      // 不传 → 保留
      final kept = j.copyWith(username: 'ops2');
      expect(kept.password, 'pw');
      expect(kept.privateKeyPath, '/home/ops/.ssh/id_ed25519');
      expect(kept.username, 'ops2');

      // 显式传 null → 清空
      final cleared = j.copyWith(password: null, privateKeyPath: null);
      expect(cleared.password, isNull);
      expect(cleared.privateKeyPath, isNull);
      expect(cleared.username, 'ops');

      // 设新值
      final updated = j.copyWith(password: 'new-pw');
      expect(updated.password, 'new-pw');
      expect(updated.privateKeyPath, '/home/ops/.ssh/id_ed25519');
    });
  });

  group('Snippet', () {
    test('JSON 往返后所有字段保持一致（含 id）', () {
      const s = Snippet(id: 's1', name: '保存配置', content: 'save\nY');

      final restored = Snippet.fromJson(s.toJson());

      expect(restored.id, 's1');
      expect(restored.name, '保存配置');
      expect(restored.content, 'save\nY');
    });
  });
}
```

- [ ] **Step 2: 写 AppSettings 的失败测试**

创建 `test/models/app_settings_test.dart`。**为什么单独测它**：`AppSettings` 的 JSON 编解码在计划 4 里要承担 `settings.json` 的读写与迁移，字段错一个就会静默丢配置。它的每个字段都带默认值回落逻辑，是这套模型里最容易写错的一块，必须有测试钉住。

```dart
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
```

- [ ] **Step 3: 运行测试确认失败**

```bash
flutter test test/models/
```

Expected：FAIL，两份测试都报 `Error when reading 'lib/models/...': No such file or directory` —— 实现文件还不存在。

- [ ] **Step 4: 实现模型**

创建 `lib/models/device_profile.dart`：

```dart
/// 设备登录协议。
enum DeviceProtocol {
  ssh,
  telnet;

  /// JSON 中的字符串转枚举。未知名称直接抛错，避免静默降级成错误的协议。
  static DeviceProtocol fromName(String name) => DeviceProtocol.values.firstWhere(
        (p) => p.name == name,
        orElse: () => throw FormatException('未知的设备协议: $name'),
      );

  /// 该协议的默认端口。
  int get defaultPort => this == DeviceProtocol.ssh ? 22 : 23;
}

/// 「调用方没传这个参数」的哨兵，用来区分它与「调用方显式传了 null」。
///
/// [DeviceProfile.password]、[DeviceProfile.privateKeyPath] 与
/// [DeviceProfile.promptRegex] 的 null 都是有语义的值（不启用密码认证 /
/// 不启用密钥认证 / 用全局默认提示符正则），不能被 `?? this.x` 吞掉：
/// 否则用户清空密码改用密钥认证后，旧密码仍留在明文配置里，且界面上
/// 再没有任何地方能看到它。
const Object _unset = Object();

/// 一条可复用的命令片段，归属于单台设备。
class Snippet {
  const Snippet({required this.id, required this.name, required this.content});

  final String id;
  final String name;
  final String content;

  Snippet copyWith({String? name, String? content}) => Snippet(
        id: id,
        name: name ?? this.name,
        content: content ?? this.content,
      );

  factory Snippet.fromJson(Map<String, Object?> json) => Snippet(
        id: json['id']! as String,
        name: json['name']! as String,
        content: json['content']! as String,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'content': content,
      };
}

/// 一台 SSH 跳板机（堡垒机）。全局共享，设备通过 id 引用。
class JumpHost {
  const JumpHost({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKeyPath,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPath;

  JumpHost copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    Object? password = _unset,
    Object? privateKeyPath = _unset,
  }) =>
      JumpHost(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password:
            identical(password, _unset) ? this.password : password as String?,
        privateKeyPath: identical(privateKeyPath, _unset)
            ? this.privateKeyPath
            : privateKeyPath as String?,
      );

  factory JumpHost.fromJson(Map<String, Object?> json) => JumpHost(
        id: json['id']! as String,
        name: json['name']! as String,
        host: json['host']! as String,
        port: json['port']! as int,
        username: json['username']! as String,
        password: json['password'] as String?,
        privateKeyPath: json['privateKeyPath'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'privateKeyPath': privateKeyPath,
      };
}

/// 一台被管理的网络设备。
class DeviceProfile {
  const DeviceProfile({
    required this.id,
    required this.name,
    required this.protocol,
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKeyPath,
    this.jumpHostIds = const [],
    this.lineEnding = '\n',
    this.promptRegex,
    this.postLoginCommands = const [],
    this.autoConnect = false,
    this.snippets = const [],
  });

  final String id;
  final String name;
  final DeviceProtocol protocol;
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPath;

  /// 跳板机链，有序。空表示直连。
  final List<String> jumpHostIds;

  /// 命令行尾符，默认 '\n'，部分老设备需要 '\r\n'。
  final String lineEnding;

  /// 该设备专用的提示符正则；null 表示用全局默认值。
  final String? promptRegex;

  /// 登录成功（含每次重连成功）后自动依次下发的命令。
  final List<String> postLoginCommands;

  final bool autoConnect;
  final List<Snippet> snippets;

  DeviceProfile copyWith({
    String? name,
    DeviceProtocol? protocol,
    String? host,
    int? port,
    String? username,
    Object? password = _unset,
    Object? privateKeyPath = _unset,
    List<String>? jumpHostIds,
    String? lineEnding,
    Object? promptRegex = _unset,
    List<String>? postLoginCommands,
    bool? autoConnect,
    List<Snippet>? snippets,
  }) =>
      DeviceProfile(
        id: id,
        name: name ?? this.name,
        protocol: protocol ?? this.protocol,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password:
            identical(password, _unset) ? this.password : password as String?,
        privateKeyPath: identical(privateKeyPath, _unset)
            ? this.privateKeyPath
            : privateKeyPath as String?,
        jumpHostIds: jumpHostIds ?? this.jumpHostIds,
        lineEnding: lineEnding ?? this.lineEnding,
        promptRegex: identical(promptRegex, _unset)
            ? this.promptRegex
            : promptRegex as String?,
        postLoginCommands: postLoginCommands ?? this.postLoginCommands,
        autoConnect: autoConnect ?? this.autoConnect,
        snippets: snippets ?? this.snippets,
      );

  factory DeviceProfile.fromJson(Map<String, Object?> json) => DeviceProfile(
        id: json['id']! as String,
        name: json['name']! as String,
        protocol: DeviceProtocol.fromName(json['protocol']! as String),
        host: json['host']! as String,
        port: json['port']! as int,
        username: json['username']! as String,
        password: json['password'] as String?,
        privateKeyPath: json['privateKeyPath'] as String?,
        jumpHostIds: (json['jumpHostIds'] as List<Object?>? ?? const [])
            .cast<String>(),
        lineEnding: json['lineEnding'] as String? ?? '\n',
        promptRegex: json['promptRegex'] as String?,
        postLoginCommands:
            (json['postLoginCommands'] as List<Object?>? ?? const [])
                .cast<String>(),
        autoConnect: json['autoConnect'] as bool? ?? false,
        snippets: (json['snippets'] as List<Object?>? ?? const [])
            .map((e) => Snippet.fromJson((e! as Map).cast<String, Object?>()))
            .toList(growable: false),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'privateKeyPath': privateKeyPath,
        'jumpHostIds': jumpHostIds,
        'lineEnding': lineEnding,
        'promptRegex': promptRegex,
        'postLoginCommands': postLoginCommands,
        'autoConnect': autoConnect,
        'snippets': snippets.map((s) => s.toJson()).toList(growable: false),
      };
}
```

创建 `lib/models/app_settings.dart`：

```dart
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
      };
}
```

- [ ] **Step 5: 运行测试确认通过**

```bash
flutter test test/models/
```

Expected：PASS，`All tests passed!`（两份测试文件合计 19 个用例全绿：`device_profile_test.dart` 12 个 + `app_settings_test.dart` 7 个）。

- [ ] **Step 6: 顺手清掉已被真实文件取代的 .gitkeep**

Task 1 用 `.gitkeep` 占位是因为当时目录是空的。现在 `lib/models/` 与 `test/models/` 都有真实文件了，占位文件已冗余：

```bash
git rm -q lib/models/.gitkeep test/models/.gitkeep
```

其余 8 个目录（`lib/connection`、`lib/render`、`lib/command`、`test/*`）暂时还是空的，**保留**它们的 `.gitkeep`，留到各自任务填入真实文件时再删。

- [ ] **Step 7: 提交**

```bash
git add lib/models test/models
git commit -m "feat: 添加设备与设置数据模型

- DeviceProtocol / Snippet / JumpHost / DeviceProfile，含 JSON 编解码
- AppSettings 含提示符正则、去抖、超时、翻页模式等全部设置项
- 移除已被真实文件取代的 .gitkeep 占位

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 3: Connector 抽象与直连实现

**Files:**
- Create: `lib/connection/connector.dart`
- Test: `test/connection/connector_test.dart`

这一层是计划 2（SSH 跳板机）的注入点：SSH 与 Telnet 都建在它之上，因此代理逻辑只需写一遍。本任务只实现直连。

- [ ] **Step 1: 写失败的测试**

创建 `test/connection/connector_test.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connector.dart';

void main() {
  group('DirectConnector', () {
    late ServerSocket server;
    late int port;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
    });

    tearDown(() async {
      await server.close();
    });

    test('建立连接后可以收发数据', () async {
      final serverGot = Completer<String>();
      server.listen((socket) {
        socket.listen((data) {
          if (!serverGot.isCompleted) {
            serverGot.complete(utf8.decode(data));
          }
        });
      });

      const connector = DirectConnector();
      final conn = await connector.open('127.0.0.1', port);
      conn.write(utf8.encode('hello'));
      await conn.flush();
      await conn.close();

      await expectLater(serverGot.future, completion('hello'));
    });

    test('input 流能收到服务端发来的数据', () async {
      server.listen((socket) {
        socket.add(utf8.encode('from-server'));
      });

      const connector = DirectConnector();
      final conn = await connector.open('127.0.0.1', port);

      final received = await conn.input
          .transform(const Utf8Decoder(allowMalformed: true))
          .firstWhere((s) => s.contains('from-server'));

      expect(received, contains('from-server'));
      await conn.close();
    });

    test('端口无人监听时抛 SocketException', () async {
      // 先关闭 server 以释放端口
      final freePort = server.port;
      await server.close();

      const connector = DirectConnector();
      await expectLater(
        connector.open('127.0.0.1', freePort),
        throwsA(isA<SocketException>()),
      );
    });

    test('连接超时抛出 SocketException 或 TimeoutException', () async {
      // 192.0.2.0/24 是 RFC 5737 保留的测试网段，不可路由，连接会一直挂起。
      // dart:io 在不同平台上报超时用的异常类型不完全一致，两种都接受。
      const connector = DirectConnector();
      await expectLater(
        connector.open(
          '192.0.2.1',
          80,
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(anyOf(isA<SocketException>(), isA<TimeoutException>())),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/connection/connector_test.dart
```

Expected：FAIL，`Error when reading 'package:win_cli_tool/connection/connector.dart': No such file or directory`。

- [ ] **Step 3: 实现 Connector**

创建 `lib/connection/connector.dart`：

```dart
import 'dart:async';
import 'dart:io';

/// 一条已建立的双向字节流。
///
/// 刻意保持极简：只有"读、写、关"三件事。SSH 与 Telnet 都建在它之上，
/// 因此代理/跳板机的实现只需写一遍。
abstract class Connection {
  /// 对端发来的原始字节。
  Stream<List<int>> get input;

  /// 写入字节。不保证立即发出，必要时调用 [flush]。
  void write(List<int> data);

  /// 把缓冲区中的数据推出去。
  Future<void> flush();

  /// 关闭连接。可重复调用。
  Future<void> close();
}

/// 建立到 `host:port` 的连接。
abstract class Connector {
  Future<Connection> open(String host, int port, {Duration? timeout});
}

/// 直连实现。
class DirectConnector implements Connector {
  const DirectConnector();

  @override
  Future<Connection> open(String host, int port, {Duration? timeout}) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    // 交互式会话禁用 Nagle：命令都是短包，攒包会引入几十毫秒的额外延迟。
    socket.setOption(SocketOption.tcpNoDelay, true);
    return _SocketConnection(socket);
  }
}

class _SocketConnection implements Connection {
  _SocketConnection(this._socket);

  final Socket _socket;
  var _closed = false;

  // 显式 cast 不能省：Socket 实际是 Stream<Uint8List>，而本接口承诺的是
  // Stream<List<int>>。两者在静态类型上兼容（Uint8List 是 List<int> 的子类型），
  // 但 Stream.transform 会按**运行时**类型去校验 transformer —— 不 cast 的话
  // 消费方写 .transform(utf8.decoder) 能通过编译却在运行时抛
  // "type 'Utf8Decoder' is not a subtype of type 'StreamTransformer<Uint8List, String>'"。
  // cast 之后声明类型与运行时类型一致，抽象才是可信的。
  @override
  Stream<List<int>> get input => _socket.cast<List<int>>();

  @override
  void write(List<int> data) {
    if (_closed) return;
    _socket.add(data);
  }

  @override
  Future<void> flush() async {
    if (_closed) return;
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _socket.close();
    _socket.destroy();
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
flutter test test/connection/connector_test.dart
```

Expected：PASS，4 个测试全绿。

- [ ] **Step 5: 提交**

```bash
git add lib/connection/connector.dart test/connection/connector_test.dart
git commit -m "feat: 添加 Connector 抽象与直连实现

Connector 是 SSH 与 Telnet 共用的连接建立层，也是后续跳板机实现
（计划 2）的注入点。直连实现禁用 Nagle 以降低交互延迟。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 4: 假设备服务器

**Files:**
- Create: `test/fixtures/fake_device_server.dart`
- Test: `test/fixtures/fake_device_server_test.dart`

后续所有测试都依赖它，所以先把它做扎实。它是一个真的 TCP 服务器，行为像一台网络设备：接受连接、可选地做 Telnet 协商、回显命令、输出响应、给出提示符。

- [ ] **Step 1: 写失败的测试**

创建 `test/fixtures/fake_device_server_test.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fake_device_server.dart';

void main() {
  group('FakeDeviceServer', () {
    test('连接后立即收到横幅与提示符', () async {
      final device = await FakeDeviceServer.start(prompt: '[CoreSW]');
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      final received = await socket
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .firstWhere((s) => s.contains('[CoreSW]'));

      expect(received, contains('Fake Device'));
      expect(received, contains('[CoreSW]'));
    });

    test('收到命令后回显、输出响应、再给出提示符', () async {
      final device = await FakeDeviceServer.start(
        prompt: '[CoreSW]',
        responseFor: {'show ver': ['Version 8.1', 'Uptime 3 days']},
      );
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      final chunks = <String>[];
      final done = Completer<void>();
      socket.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
        chunks.add(s);
        // 横幅里也有提示符，所以等到第二次出现提示符才算命令执行完
        if (chunks.join().split('[CoreSW]').length > 2 && !done.isCompleted) {
          done.complete();
        }
      });

      socket.add(utf8.encode('show ver\r\n'));
      await done.future;

      final all = chunks.join();
      expect(all, contains('show ver'));
      expect(all, contains('Version 8.1'));
      expect(all, contains('Uptime 3 days'));
      expect(device.receivedCommands, ['show ver']);
    });

    test('开启协商时先发出 Telnet IAC 序列', () async {
      final device = await FakeDeviceServer.start(negotiate: true);
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      final first = await socket.first;
      expect(first.take(3).toList(), [255, 251, 1]);
    });

    test('关闭协商时不发 IAC 序列', () async {
      final device = await FakeDeviceServer.start(negotiate: false);
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      final first = await socket.first;
      expect(first.first, isNot(255));
    });

    test('hangCommands 中的命令不回提示符', () async {
      final device = await FakeDeviceServer.start(
        prompt: '[CoreSW]',
        hangCommands: {'reboot'},
      );
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      var text = '';
      socket.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
        text += s;
      });

      socket.add(utf8.encode('reboot\r\n'));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // 只回显了命令，没有第二个提示符
      expect(text, contains('reboot'));
      expect('[CoreSW]'.allMatches(text).length, 1);
    });

    test('分页：输出若干行后插入翻页提示，收到空格才继续', () async {
      final device = await FakeDeviceServer.start(
        prompt: '[CoreSW]',
        pagerEvery: 2,
        responseFor: {
          'display cur': ['line1', 'line2', 'line3', 'line4'],
        },
      );
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      var text = '';
      final sub = socket.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(
        (s) {
          text += s;
        },
      );
      addTearDown(sub.cancel);

      socket.add(utf8.encode('display cur\r\n'));

      // 等到第一页与翻页提示出现
      await _waitUntil(() => text.contains('---- More ----'));
      expect(text, contains('line1'));
      expect(text, contains('line2'));
      expect(text, isNot(contains('line3')));

      // 回送空格继续
      socket.add(utf8.encode(' '));
      await _waitUntil(() => text.split('[CoreSW]').length > 2);

      expect(text, contains('line3'));
      expect(text, contains('line4'));
    });
  });
}

/// 轮询等待条件成立，超时则抛错。
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/fixtures/fake_device_server_test.dart
```

Expected：FAIL，`Error when reading 'fake_device_server.dart': No such file or directory`。

- [ ] **Step 3: 实现假设备服务器**

创建 `test/fixtures/fake_device_server.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一个最小的假网络设备，用于测试。
///
/// 行为：接受 TCP 连接 →（可选）发一轮 Telnet 协商 → 发横幅与提示符 →
/// 收到命令后回显、输出响应、再发提示符。
class FakeDeviceServer {
  FakeDeviceServer._(
    this._server,
    this._prompt,
    this._banner,
    this._negotiate,
    this._pagerEvery,
    this._responseFor,
    this._hangCommands,
  );

  final ServerSocket _server;
  final String _prompt;
  final String _banner;
  final bool _negotiate;

  /// 每输出这么多行插入一次翻页提示；0 表示不分页。
  final int _pagerEvery;

  /// 命令 → 响应行。
  final Map<String, List<String>> _responseFor;

  /// 这些命令只回显、不回提示符，用于测试超时。
  final Set<String> _hangCommands;

  /// 服务端收到过的命令，按顺序。
  final List<String> receivedCommands = [];

  final _clients = <_FakeClient>[];
  StreamSubscription<Socket>? _serverSub;

  int get port => _server.port;

  static Future<FakeDeviceServer> start({
    String prompt = '[CoreSW]',
    String banner = 'Fake Device v1.0',
    bool negotiate = false,
    int pagerEvery = 0,
    Map<String, List<String>> responseFor = const {},
    Set<String> hangCommands = const {},
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final device = FakeDeviceServer._(
      server,
      prompt,
      banner,
      negotiate,
      pagerEvery,
      responseFor,
      hangCommands,
    );
    device._serverSub = server.listen(device._onClient);
    return device;
  }

  Future<void> stop() async {
    for (final c in List.of(_clients)) {
      await c.dispose();
    }
    _clients.clear();
    await _serverSub?.cancel();
    await _server.close();
  }

  void _onClient(Socket socket) {
    final client = _FakeClient(socket);
    _clients.add(client);

    if (_negotiate) {
      // IAC WILL ECHO, IAC WILL SGA, IAC DO SGA
      socket.add(const [255, 251, 1, 255, 251, 3, 255, 253, 3]);
    }
    socket.add(utf8.encode('$_banner\r\n$_prompt'));

    client.sub = socket.listen(
      (data) => _onData(client, data),
      onDone: () => _clients.remove(client),
      onError: (_) => _clients.remove(client),
    );
  }

  void _onData(_FakeClient client, List<int> raw) {
    final bytes = _stripIac(raw);
    for (final b in bytes) {
      if (client.pagerPending) {
        // 翻页等待中：任何输入都视为"继续"
        client.pagerPending = false;
        client.pagerContinuation?.complete();
        client.pagerContinuation = null;
        continue;
      }
      if (b == 0x0A) {
        // LF：若上一个字节是 CR，忽略
        if (client.lastWasCr) {
          client.lastWasCr = false;
          continue;
        }
        _finishLine(client);
      } else if (b == 0x0D) {
        client.lastWasCr = true;
        _finishLine(client);
      } else {
        client.lastWasCr = false;
        client.lineBuffer.writeCharCode(b);
      }
    }
  }

  void _finishLine(_FakeClient client) {
    final cmd = client.lineBuffer.toString();
    client.lineBuffer.clear();
    if (cmd.isEmpty) {
      client.socket.add(utf8.encode('\r\n$_prompt'));
      return;
    }
    receivedCommands.add(cmd);
    unawaited(_respond(client, cmd));
  }

  Future<void> _respond(_FakeClient client, String cmd) async {
    final out = StringBuffer('$cmd\r\n');

    if (_hangCommands.contains(cmd)) {
      // 只回显，不给提示符
      client.socket.add(utf8.encode(out.toString()));
      return;
    }

    final lines = _responseFor[cmd] ?? const <String>[];

    if (_pagerEvery <= 0 || lines.length <= _pagerEvery) {
      for (final l in lines) {
        out.write('$l\r\n');
      }
      out.write(_prompt);
      client.socket.add(utf8.encode(out.toString()));
      return;
    }

    // 分页：先发第一页，插入翻页提示，等客户端回送后再发剩下的
    for (var i = 0; i < _pagerEvery; i++) {
      out.write('${lines[i]}\r\n');
    }
    out.write('  ---- More ----');
    client.socket.add(utf8.encode(out.toString()));

    client.pagerPending = true;
    client.pagerContinuation = Completer<void>();
    await client.pagerContinuation!.future;

    final rest = StringBuffer();
    for (var i = _pagerEvery; i < lines.length; i++) {
      rest.write('${lines[i]}\r\n');
    }
    rest.write(_prompt);
    client.socket.add(utf8.encode(rest.toString()));
  }

  /// 剥掉客户端发来的 IAC 序列（协商回送），只保留用户数据。
  static List<int> _stripIac(List<int> raw) {
    final out = <int>[];
    var i = 0;
    while (i < raw.length) {
      if (raw[i] != 255) {
        out.add(raw[i]);
        i++;
        continue;
      }
      if (i + 1 >= raw.length) break;
      final verb = raw[i + 1];
      if (verb == 255) {
        // 转义的 0xFF
        out.add(255);
        i += 2;
      } else if (verb == 250) {
        // IAC SB ... IAC SE
        var j = i + 2;
        while (j + 1 < raw.length && !(raw[j] == 255 && raw[j + 1] == 240)) {
          j++;
        }
        i = j + 2;
      } else if (verb >= 251 && verb <= 254) {
        // IAC WILL/WONT/DO/DONT <option>
        i += 3;
      } else {
        // 其余两字节命令
        i += 2;
      }
    }
    return out;
  }
}

class _FakeClient {
  _FakeClient(this.socket);

  final Socket socket;
  final lineBuffer = StringBuffer();
  StreamSubscription<List<int>>? sub;
  var lastWasCr = false;
  var pagerPending = false;
  Completer<void>? pagerContinuation;

  Future<void> dispose() async {
    await sub?.cancel();
    socket.destroy();
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
flutter test test/fixtures/fake_device_server_test.dart
```

Expected：PASS，6 个测试全绿。

- [ ] **Step 5: 提交**

```bash
git add test/fixtures
git commit -m "test: 添加假网络设备服务器测试夹具

可配置提示符、响应内容、Telnet 协商、分页与命令挂起，
后续所有连接与命令下发测试都基于它。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 5: TelnetProtocol 协商状态机

**Files:**
- Create: `lib/connection/telnet_protocol.dart`
- Test: `test/connection/telnet_protocol_test.dart`

纯状态机，**无任何 IO**，因此可以精确测试半包、粘包、转义等边界。这是自研 Telnet 层的核心。

- [ ] **Step 1: 写失败的测试**

创建 `test/connection/telnet_protocol_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/telnet_protocol.dart';

void main() {
  const iac = TelnetProtocol.iac;
  const will = TelnetProtocol.will;
  const wont = TelnetProtocol.wont;
  const doVerb = TelnetProtocol.doVerb;
  const dont = TelnetProtocol.dont;
  const sb = TelnetProtocol.sb;
  const se = TelnetProtocol.se;
  const optEcho = TelnetProtocol.optEcho;
  const optSga = TelnetProtocol.optSuppressGoAhead;

  group('TelnetProtocol 数据与协商的分离', () {
    test('纯数据原样透传', () {
      final p = TelnetProtocol();
      final r = p.feed('hello'.codeUnits);

      expect(r.data, 'hello'.codeUnits);
      expect(r.response, isEmpty);
    });

    test('协商序列不进入用户数据', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, will, optEcho, ...'ok'.codeUnits]);

      expect(r.data, 'ok'.codeUnits);
    });

    test('转义的 0xFF 还原成一个字节', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, iac, 0x41]);

      expect(r.data, [255, 0x41]);
    });

    test('子协商内容被整体吞掉', () {
      final p = TelnetProtocol();
      final r = p.feed([
        iac, sb, 24, 1, iac, se, // IAC SB TTYPE SEND IAC SE
        ...'x'.codeUnits,
      ]);

      expect(r.data, 'x'.codeUnits);
    });
  });

  group('协商应答', () {
    test('对端 DO SGA 时我方回 WILL SGA', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, doVerb, optSga]);

      expect(r.response, [iac, will, optSga]);
      expect(r.data, isEmpty);
    });

    test('对端 DO 一个我们不支持的选项时回 WONT', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, doVerb, 24]); // TTYPE

      expect(r.response, [iac, wont, 24]);
    });

    test('对端 WILL ECHO 时我方回 DO ECHO', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, will, optEcho]);

      expect(r.response, [iac, doVerb, optEcho]);
    });

    test('对端 WILL 一个我们不支持的选项时回 DONT', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, will, 39]); // NEW-ENVIRON

      expect(r.response, [iac, dont, 39]);
    });

    test('对端 WONT / DONT 时不回应', () {
      final p = TelnetProtocol();
      expect(p.feed([iac, wont, optEcho]).response, isEmpty);
      expect(p.feed([iac, dont, optSga]).response, isEmpty);
    });
  });

  group('分帧边界', () {
    test('协商序列被切开在两个分片里也能正确解析', () {
      final p = TelnetProtocol();

      final r1 = p.feed([iac]);
      expect(r1.data, isEmpty);
      expect(r1.response, isEmpty);

      final r2 = p.feed([doVerb]);
      expect(r2.response, isEmpty);

      final r3 = p.feed([optSga]);
      expect(r3.response, [iac, will, optSga]);
    });

    test('数据被切成多片后拼接结果正确', () {
      final p = TelnetProtocol();
      final out = <int>[];
      out.addAll(p.feed('ab'.codeUnits).data);
      out.addAll(p.feed('cd'.codeUnits).data);
      out.addAll(p.feed('ef'.codeUnits).data);

      expect(out, 'abcdef'.codeUnits);
    });

    test('一次分片里包含多组协商与数据', () {
      final p = TelnetProtocol();
      final r = p.feed([
        iac, will, optEcho,
        ...'A'.codeUnits,
        iac, doVerb, optSga,
        ...'B'.codeUnits,
      ]);

      expect(r.data, 'AB'.codeUnits);
      expect(r.response, [
        iac, doVerb, optEcho,
        iac, will, optSga,
      ]);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/connection/telnet_protocol_test.dart
```

Expected：FAIL，`Error when reading 'package:win_cli_tool/connection/telnet_protocol.dart': No such file or directory`。

- [ ] **Step 3: 实现状态机**

创建 `lib/connection/telnet_protocol.dart`：

```dart
/// 一次 [TelnetProtocol.feed] 的解析结果。
class TelnetParseResult {
  const TelnetParseResult({required this.data, required this.response});

  /// 剥掉协商序列后的用户数据。
  final List<int> data;

  /// 需要回送给对端的协商字节。调用方应立即写出。
  final List<int> response;
}

/// Telnet IAC 协商的纯状态机。
///
/// 只处理与网络设备 CLI 相关的两个选项：ECHO（回显）与 SGA（抑制 GA，
/// 即逐字符模式）。其余选项一律拒绝，因为我们不需要它们，而拒绝是安全的
/// —— 设备会退回默认行为。
///
/// 刻意不做 TTYPE / NAWS 子协商：我们从不主动 WILL 这两个选项，因此设备
/// 不会向我们发起 `SB TTYPE SEND`。收到 SB 一律吞掉。
class TelnetProtocol {
  static const int iac = 255; // Interpret As Command
  static const int se = 240; // Subnegotiation End
  static const int sb = 250; // Subnegotiation Begin
  static const int will = 251;
  static const int wont = 252;
  static const int doVerb = 253;
  static const int dont = 254;

  static const int optEcho = 1;
  static const int optSuppressGoAhead = 3;

  _State _state = _State.data;
  int _pendingVerb = 0;
  final List<int> _data = [];
  final List<int> _response = [];

  /// 吃进一段字节，返回用户数据与需要回送的协商字节。
  TelnetParseResult feed(List<int> chunk) {
    _data.clear();
    _response.clear();
    for (final b in chunk) {
      _consume(b);
    }
    return TelnetParseResult(
      data: List<int>.of(_data),
      response: List<int>.of(_response),
    );
  }

  void _consume(int b) {
    switch (_state) {
      case _State.data:
        if (b == iac) {
          _state = _State.iac;
        } else {
          _data.add(b);
        }
      case _State.iac:
        if (b == iac) {
          // 转义的 0xFF：数据里真的有一个 0xFF
          _data.add(iac);
          _state = _State.data;
        } else if (b == will || b == wont || b == doVerb || b == dont) {
          _pendingVerb = b;
          _state = _State.negotiation;
        } else if (b == sb) {
          _state = _State.subnegotiation;
        } else {
          // 其余两字节命令（NOP / GA / DM 等），忽略
          _state = _State.data;
        }
      case _State.negotiation:
        _negotiate(b);
        _state = _State.data;
      case _State.subnegotiation:
        if (b == iac) {
          _state = _State.subnegotiationIac;
        }
      case _State.subnegotiationIac:
        if (b == se) {
          _state = _State.data;
        } else if (b == iac) {
          // 子协商里转义的 0xFF，继续留在子协商中
          _state = _State.subnegotiation;
        } else {
          _state = _State.subnegotiation;
        }
    }
  }

  void _negotiate(int option) {
    switch (_pendingVerb) {
      case doVerb:
        // 对端要我们启用某选项
        if (option == optSuppressGoAhead) {
          _respond(will, option);
        } else {
          _respond(wont, option);
        }
      case will:
        // 对端声明自己要启用某选项
        if (option == optEcho || option == optSuppressGoAhead) {
          _respond(doVerb, option);
        } else {
          _respond(dont, option);
        }
      case wont:
      case dont:
        // 对端拒绝或要求关闭，不需要回应
        break;
    }
  }

  void _respond(int verb, int option) {
    _response.addAll([iac, verb, option]);
  }
}

enum _State { data, iac, negotiation, subnegotiation, subnegotiationIac }
```

- [ ] **Step 4: 运行测试确认通过**

```bash
flutter test test/connection/telnet_protocol_test.dart
```

Expected：PASS，12 个测试全绿。

- [ ] **Step 5: 提交**

```bash
git add lib/connection/telnet_protocol.dart test/connection/telnet_protocol_test.dart
git commit -m "feat: 添加 Telnet IAC 协商状态机

纯状态机无 IO，可精确测试半包/粘包/转义等边界。
只支持 ECHO 与 SGA 两个选项，其余一律拒绝。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 6: Session 抽象与 TelnetSession

**Files:**
- Create: `lib/connection/session.dart`
- Create: `lib/connection/telnet_session.dart`
- Test: `test/connection/telnet_session_test.dart`

把 `Connector` 与 `TelnetProtocol` 组装成一个产出 `Stream<String>` 的会话。UTF-8 解码必须走流式解码器，否则中文回显会被分片切断成乱码。

- [ ] **Step 1: 写失败的测试**

创建 `test/connection/telnet_session_test.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connector.dart';
import 'package:win_cli_tool/connection/telnet_session.dart';
import 'package:win_cli_tool/models/device_profile.dart';

import '../fixtures/fake_device_server.dart';

DeviceProfile _profile(int port, {String name = '测试设备'}) => DeviceProfile(
      id: 'd1',
      name: name,
      protocol: DeviceProtocol.telnet,
      host: '127.0.0.1',
      port: port,
      username: 'admin',
    );

/// 建连时机可控的 Connector：`open` 返回调用方给的 Future。
class _GatedConnector implements Connector {
  _GatedConnector(this.result);

  final Future<Connection> result;

  @override
  Future<Connection> open(String host, int port, {Duration? timeout}) => result;
}

/// 一条记名式的假连接：能人为喂入字节，并记录是否被关闭。
class _FakeConnection implements Connection {
  final _input = StreamController<List<int>>();
  var closed = false;

  @override
  Stream<List<int>> get input => _input.stream;

  /// 喂入一段来自对端的字节。已关闭的连接直接忽略。
  void feed(List<int> bytes) {
    if (closed) return;
    _input.add(bytes);
  }

  @override
  void write(List<int> data) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    // 不 await：单订阅流在无人监听时，close() 的 Future 要等到有人订阅
    // 才会兑现（见下面那个 close-during-connect 的用例）。
    unawaited(_input.close());
  }
}

void main() {
  group('TelnetSession', () {
    test('连接后能收到横幅与提示符', () async {
      final device = await FakeDeviceServer.start(prompt: '[CoreSW]');
      addTearDown(device.stop);

      final session = TelnetSession(profile: _profile(device.port));
      addTearDown(session.close);

      final output = <String>[];
      session.output.listen(output.add);

      await session.connect();
      await _waitUntil(() => output.join().contains('[CoreSW]'));

      expect(output.join(), contains('Fake Device'));
    });

    test('write 的内容被设备收到', () async {
      final device = await FakeDeviceServer.start(prompt: '[CoreSW]');
      addTearDown(device.stop);

      final session = TelnetSession(profile: _profile(device.port));
      addTearDown(session.close);
      await session.connect();

      session.write('display version\n');
      await _waitUntil(() => device.receivedCommands.isNotEmpty);

      expect(device.receivedCommands, ['display version']);
    });

    test('会话能正确处理跨分片的中文 UTF-8 字符', () async {
      final device = await FakeDeviceServer.start(
        prompt: '[CoreSW]',
        responseFor: {
          'show': ['设备型号：华为 S5700'],
        },
      );
      addTearDown(device.stop);

      final session = TelnetSession(profile: _profile(device.port));
      addTearDown(session.close);

      final output = <String>[];
      session.output.listen(output.add);

      await session.connect();
      session.write('show\n');
      await _waitUntil(() => output.join().contains('华为 S5700'));

      expect(output.join(), contains('设备型号：华为 S5700'));
    });

    test('对端协商被自动应答，不进入输出流', () async {
      final device = await FakeDeviceServer.start(
        prompt: '[CoreSW]',
        negotiate: true,
      );
      addTearDown(device.stop);

      final session = TelnetSession(profile: _profile(device.port));
      addTearDown(session.close);

      final output = <String>[];
      session.output.listen(output.add);

      await session.connect();
      await _waitUntil(() => output.join().contains('[CoreSW]'));

      // 0xFF 不是合法 UTF-8，若协商字节没被剥离，解码时会变成替换字符 U+FFFD
      expect(output.join(), isNot(contains('�')));
      expect(output.join(), contains('Fake Device'));
    });

    test('服务端关闭连接时 done 完成', () async {
      final device = await FakeDeviceServer.start(prompt: '[CoreSW]');
      final session = TelnetSession(profile: _profile(device.port));
      addTearDown(session.close);
      await session.connect();

      var done = false;
      unawaited(session.done.then((_) => done = true));

      await device.stop();
      await _waitUntil(() => done);

      expect(done, isTrue);
    });

    test('端口无人监听时 connect 抛异常', () async {
      final device = await FakeDeviceServer.start();
      final port = device.port;
      await device.stop();

      final session = TelnetSession(profile: _profile(port));
      await expectLater(session.connect(), throwsA(isA<SocketException>()));
    });

    test('从未连接的会话上 close() 能完成（不挂起）', () async {
      final session = TelnetSession(profile: _profile(1));

      // 单订阅 StreamController 的 close() Future 要等到有监听者订阅才会兑现；
      // 从未连上的会话没有监听者，await 会永久挂起。加超时是为了让回归以
      // 「失败」而不是「卡死整个测试套件」的方式暴露出来。
      await session.close().timeout(const Duration(seconds: 2));
    });

    test('connect 抛异常后 close() 能完成（不挂起）', () async {
      final device = await FakeDeviceServer.start();
      final port = device.port;
      await device.stop();

      final session = TelnetSession(profile: _profile(port));
      await expectLater(session.connect(), throwsA(isA<SocketException>()));

      // 「连不上 → 清理」是最常见的调用路径。connect 抛异常时 _decodeSub 还没
      // 赋值，_dataBytes 也就从没被监听，close() 同样会永久挂起。
      await session.close().timeout(const Duration(seconds: 2));
    });

    test('connect 等待期间被 close：连接被关闭且没有异常逃逸到 zone', () async {
      final conn = _FakeConnection();
      final gate = Completer<Connection>();
      final session = TelnetSession(
        profile: _profile(1),
        connector: _GatedConnector(gate.future),
      );

      Object? zoneError;
      StackTrace? zoneStack;

      await runZonedGuarded(() async {
        // 建连还挂在 open 上时用户切了设备/关了窗口
        final connecting = session.connect();
        // 只发起、不等待 close()：_dataBytes 是单订阅流且此时还无人监听，
        // 它的 close() 直到有人订阅才会完成。真正要验的是 close() 的效果，
        // 不是它的 Future 何时兑现。
        unawaited(session.close());
        // 先把 close() 的拆除动作放干净（此时 _conn 还是 null，它什么也拆不掉，
        // 随后挂在 _dataBytes.close() 上），再让 connect() 醒来。
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        gate.complete(conn);
        await connecting;

        // 让刚建立的连接吐点字节：修复前 _dataBytes 已关闭，
        // 这里会从 _onBytes 抛出 "Cannot add event after closing"
        conn.feed(utf8.encode('banner'));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }, (e, s) {
        zoneError = e;
        zoneStack = s;
      });

      expect(
        zoneError,
        isNull,
        reason: '不该有异常逃逸到 zone，实际拿到：$zoneError\n$zoneStack',
      );
      expect(conn.closed, isTrue, reason: '建连期间被 close，刚建好的连接必须关掉');
    });
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/connection/telnet_session_test.dart
```

Expected：FAIL，`Error when reading 'package:win_cli_tool/connection/session.dart': No such file or directory`。

- [ ] **Step 3: 定义 Session 接口**

创建 `lib/connection/session.dart`：

```dart
/// 与一台设备的一条会话。
abstract class Session {
  /// 会话输出流。已完成 UTF-8 解码，且已剥离传输层的协商字节。
  Stream<String> get output;

  /// 会话意外断开时完成。主动调用 [close] 不会触发它。
  Future<void> get done;

  /// 建立连接。
  Future<void> connect();

  /// 写入一段文本。行尾符由调用方负责。
  void write(String text);

  /// 关闭会话。
  Future<void> close();
}
```

- [ ] **Step 4: 实现 TelnetSession**

创建 `lib/connection/telnet_session.dart`：

```dart
import 'dart:async';
import 'dart:convert';

import '../models/device_profile.dart';
import 'connector.dart';
import 'session.dart';
import 'telnet_protocol.dart';

/// 基于 Telnet 的会话实现。
class TelnetSession implements Session {
  TelnetSession({
    required this.profile,
    this.connector = const DirectConnector(),
    this.connectTimeout = const Duration(seconds: 15),
  });

  final DeviceProfile profile;

  /// 建连方式。默认直连；计划 2 会注入带跳板机的实现。
  final Connector connector;

  final Duration connectTimeout;

  final _protocol = TelnetProtocol();
  final _output = StreamController<String>.broadcast();
  final _dataBytes = StreamController<List<int>>();
  final _done = Completer<void>();

  Connection? _conn;
  StreamSubscription<List<int>>? _inputSub;
  StreamSubscription<String>? _decodeSub;
  var _closed = false;

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

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

    // 用流式解码器而非逐片 utf8.decode：多字节字符可能跨分片边界，
    // 逐片解码会把它切成乱码。
    _decodeSub = _dataBytes.stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_output.add);

    _inputSub = conn.input.listen(
      _onBytes,
      onError: _onDisconnected,
      onDone: _onDisconnected,
      cancelOnError: true,
    );
  }

  void _onBytes(List<int> chunk) {
    final result = _protocol.feed(chunk);
    if (result.response.isNotEmpty) {
      _conn?.write(result.response);
    }
    if (result.data.isNotEmpty) {
      _dataBytes.add(result.data);
    }
  }

  void _onDisconnected([Object? _]) {
    if (_closed) return;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void write(String text) {
    if (_closed) return;
    _conn?.write(utf8.encode(text));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _inputSub?.cancel();
    await _decodeSub?.cancel();
    await _conn?.close();
    // 这里不能 await：单订阅 StreamController 的 close() Future 要等到有
    // 监听者订阅才会完成，而「从未连上」或「connect 抛异常」的会话永远没有
    // 监听者，await 会永久挂起（切设备、连不上后清理、关窗口时卡死）。
    // 这两个只是内存对象，真正需要释放的资源是上面的 socket。
    unawaited(_dataBytes.close());
    unawaited(_output.close());
  }
}
```

- [ ] **Step 5: 运行测试确认通过**

```bash
flutter test test/connection/telnet_session_test.dart
```

Expected：PASS，9 个测试全绿。

- [ ] **Step 6: 提交**

```bash
git add lib/connection/session.dart lib/connection/telnet_session.dart test/connection/telnet_session_test.dart
git commit -m "feat: 添加 Session 接口与 Telnet 会话实现

TelnetSession 把 Connector 与 TelnetProtocol 组装成产出 Stream<String>
的会话。UTF-8 走流式解码器，避免多字节字符跨分片时出现乱码。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 7: 提示符判定与翻页检测

**Files:**
- Create: `lib/render/ansi.dart`
- Create: `lib/command/prompt_detector.dart`
- Create: `lib/command/more_pager.dart`
- Test: `test/command/prompt_detector_test.dart`
- Test: `test/command/more_pager_test.dart`

两个小判定器，都是纯函数式的，是命令串行下发的"眼睛"。`stripAnsi` 放这里是因为提示符判定必须能穿透 ANSI 颜色码 —— 否则 `\x1b[1m[CoreSW]\x1b[0m` 这种带颜色的提示符永远匹配不上。

- [ ] **Step 1: 写失败的测试**

创建 `test/render/ansi_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/render/ansi.dart';

void main() {
  group('stripAnsi', () {
    test('剥离 SGR 颜色序列', () {
      expect(stripAnsi('\x1b[1m[CoreSW]\x1b[0m'), '[CoreSW]');
    });

    test('剥离光标移动序列', () {
      expect(stripAnsi('\x1b[2K\x1b[1Ghello'), 'hello');
    });

    test('无转义序列时原样返回', () {
      expect(stripAnsi('plain text'), 'plain text');
    });

    test('保留中文与普通文本', () {
      expect(stripAnsi('\x1b[31m错误：接口 down\x1b[0m'), '错误：接口 down');
    });
  });
}
```

创建 `test/command/prompt_detector_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';

void main() {
  group('PromptDetector 默认正则', () {
    final d = PromptDetector();

    test('华为用户视图 <Huawei> 命中', () {
      expect(d.matches('<Huawei>'), isTrue);
    });

    test('华为系统视图 [Huawei] 命中', () {
      expect(d.matches('[Huawei]'), isTrue);
    });

    test('华为接口视图 [Huawei-GE0/0/1] 命中', () {
      expect(d.matches('[Huawei-GigabitEthernet0/0/1]'), isTrue);
    });

    test('Cisco 特权模式 Router# 命中', () {
      expect(d.matches('Router#'), isTrue);
    });

    test('Cisco 配置模式 Router(config)# 命中', () {
      expect(d.matches('Router(config)#'), isTrue);
    });

    test('提示符后带空格也命中', () {
      expect(d.matches('[CoreSW] '), isTrue);
    });

    test('匹配的是最后一个非空行', () {
      expect(d.matches('some output\r\nmore output\r\n[CoreSW]'), isTrue);
    });

    test('最后一行是普通内容时不命中', () {
      expect(d.matches('[CoreSW]\r\nInterface GE0/0/1 is UP'), isFalse);
    });

    test('以 ] 结尾的内容行会误判 —— 这是已知限制', () {
      // 记录该行为：静默去抖与"只看最后一非空行"是主要的缓解手段
      expect(d.matches('GigabitEthernet0/0/1 is up [OK]'), isTrue);
    });

    test('空缓冲区不命中', () {
      expect(d.matches(''), isFalse);
    });

    test('只有空白字符时不命中', () {
      expect(d.matches('\r\n   \r\n'), isFalse);
    });

    test('能穿透 ANSI 颜色码', () {
      expect(d.matches('\x1b[1m[CoreSW]\x1b[0m'), isTrue);
    });
  });

  group('PromptDetector 自定义正则', () {
    test('使用自定义正则', () {
      final d = PromptDetector(pattern: RegExp(r'>>>\s*$'));
      expect(d.matches('>>>'), isTrue);
      expect(d.matches('[CoreSW]'), isFalse);
    });
  });
}
```

创建 `test/command/more_pager_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/more_pager.dart';

void main() {
  group('MorePager', () {
    final p = MorePager();

    test('识别华为/H3C 的 ---- More ----', () {
      expect(p.matchesTail('line\r\n  ---- More ----'), isTrue);
    });

    test('识别 Cisco 的 --More--', () {
      expect(p.matchesTail('line\r\n--More--'), isTrue);
    });

    test('识别 <--- More --->', () {
      expect(p.matchesTail('<--- More --->'), isTrue);
    });

    test('翻页提示后带空格仍能识别', () {
      expect(p.matchesTail('line\r\n  ---- More ----   '), isTrue);
    });

    test('最后一行为空（已换行）时不命中', () {
      expect(p.matchesTail('line\r\n'), isFalse);
    });

    test('输出中段提到 More 但不在末尾时不命中', () {
      expect(p.matchesTail('---- More ----\r\nreal output'), isFalse);
    });

    test('空缓冲区不命中', () {
      expect(p.matchesTail(''), isFalse);
    });

    test('自定义模式', () {
      final custom = MorePager(patterns: ['<SPACE>']);
      expect(custom.matchesTail('line<SPACE>'), isTrue);
      expect(custom.matchesTail('line--More--'), isFalse);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/command/prompt_detector_test.dart test/command/more_pager_test.dart test/render/ansi_test.dart
```

Expected：FAIL，三个 import 目标都不存在。

- [ ] **Step 3: 实现 stripAnsi**

创建 `lib/render/ansi.dart`：

```dart
/// CSI 序列：ESC [ 参数 中间字节 终止字节。
/// 覆盖颜色（SGR）、光标移动、擦除等绝大多数控制序列。
final _csi = RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]');

/// OSC 序列：ESC ] ... BEL 或 ESC \。
final _osc = RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)');

/// 其余两字节转义序列，如 ESC ( B（选择字符集）。
final _twoByte = RegExp(r'\x1b[@-Z\\-_]');

/// 剥离所有 ANSI 控制序列，只留可读文本。
///
/// 提示符判定必须先做这一步：设备可能给提示符上色，带颜色的
/// `\x1b[1m[CoreSW]\x1b[0m` 直接用正则匹配末尾的 `]` 是匹配不上的。
String stripAnsi(String input) {
  if (!input.contains('\x1b')) return input;
  return input
      .replaceAll(_csi, '')
      .replaceAll(_osc, '')
      .replaceAll(_twoByte, '')
      // 单独出现的 \r 是终端覆盖写，行内清掉避免污染行尾判定
      .replaceAll('\r', '');
}
```

- [ ] **Step 4: 实现 PromptDetector**

创建 `lib/command/prompt_detector.dart`：

```dart
import '../render/ansi.dart';

/// 判定接收缓冲区末尾是否出现了设备提示符。
///
/// 判定规则（spec §5.2）：取缓冲区中**最后一个非空行**（去掉行尾空白后），
/// 用正则匹配它。只看最后一行是关键 —— 否则设备回显里任何以 `>` 或 `]`
/// 结尾的内容行都会造成误判。
///
/// 单靠本类无法完全消除误判（例如输出行 `... is up [OK]`）。真正的防线是
/// `CommandDispatcher` 的静默去抖：匹配到之后还要等数据停住才算数。
class PromptDetector {
  PromptDetector({RegExp? pattern}) : pattern = pattern ?? defaultPattern;

  /// 覆盖华为 VRP、Cisco IOS、H3C 等主流形态的默认正则。
  static final RegExp defaultPattern = RegExp(r'[>#\]]\s*$');

  final RegExp pattern;

  /// 缓冲区末尾是否为提示符。
  bool matches(String buffer) {
    final line = lastNonEmptyLine(buffer);
    if (line == null) return false;
    return pattern.hasMatch(line);
  }

  /// 取出缓冲区里最后一个非空行（已剥离 ANSI、已去掉首尾空白）。
  ///
  /// 返回 null 表示缓冲区里没有非空内容。
  static String? lastNonEmptyLine(String buffer) {
    final cleaned = stripAnsi(buffer);
    final lines = cleaned.split('\n');
    for (var i = lines.length - 1; i >= 0; i--) {
      final trimmed = lines[i].trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }
}
```

- [ ] **Step 5: 实现 MorePager**

创建 `lib/command/more_pager.dart`：

```dart
import '../render/ansi.dart';

/// 判定接收缓冲区末尾是否为设备的翻页提示。
///
/// 翻页提示通常**没有换行结尾** —— 设备会原地覆盖它。因此判定只看最后一
/// 行，且要求该行为非空。
class MorePager {
  MorePager({List<String>? patterns})
      : patterns = patterns ??
            const ['---- More ----', '--More--', '<--- More --->'];

  final List<String> patterns;

  /// 翻页时回送的内容。
  static const String continueKey = ' ';

  /// 缓冲区末尾是否为翻页提示。
  bool matchesTail(String buffer) {
    if (buffer.isEmpty) return false;
    final cleaned = stripAnsi(buffer);
    final idx = cleaned.lastIndexOf('\n');
    final tail = idx < 0 ? cleaned : cleaned.substring(idx + 1);
    final trimmed = tail.trim();
    if (trimmed.isEmpty) return false;
    return patterns.any((p) => trimmed.contains(p));
  }
}
```

- [ ] **Step 6: 运行测试确认通过**

```bash
flutter test test/command/prompt_detector_test.dart test/command/more_pager_test.dart test/render/ansi_test.dart
```

Expected：PASS，共 4 + 13 + 8 = 25 个测试全绿。

- [ ] **Step 7: 提交**

```bash
git add lib/render/ansi.dart lib/command/prompt_detector.dart lib/command/more_pager.dart test/command test/render
git commit -m "feat: 添加提示符判定、翻页检测与 ANSI 剥离

- stripAnsi：提示符判定必须能穿透颜色码
- PromptDetector：只看最后一个非空行，避免内容行造成误判
- MorePager：翻页提示没有换行结尾，故只看最后一行

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 8: CommandDispatcher

**Files:**
- Create: `lib/command/command_dispatcher.dart`
- Test: `test/command/command_dispatcher_test.dart`

整个工具的核心。命令队列 + 串行状态机：发一条 → 等提示符 → 发下一条；超时强制放行；翻页不计入队列；断线丢弃队列。

- [ ] **Step 1: 写失败的测试**

创建 `test/command/command_dispatcher_test.dart`：

```dart
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/command_dispatcher.dart';
import 'package:win_cli_tool/command/more_pager.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';

/// 测试脚手架：记录写出的内容，暴露事件流。
class _Harness {
  _Harness({String lineEnding = '\n', void Function(String)? write}) {
    dispatcher = CommandDispatcher(
      write: write ?? (data) => written.add(data),
      promptDetector: PromptDetector(),
      morePager: MorePager(),
      lineEnding: lineEnding,
      promptDebounce: const Duration(milliseconds: 120),
      commandTimeout: const Duration(seconds: 10),
    );
    dispatcher.events.listen(events.add);
  }

  late final CommandDispatcher dispatcher;
  final written = <String>[];
  final events = <DispatchEvent>[];

  List<CommandSent> get sent => events.whereType<CommandSent>().toList();
  List<CommandCompleted> get completed =>
      events.whereType<CommandCompleted>().toList();
}

void main() {
  group('入队与空行过滤', () {
    test('纯空行被过滤掉，不下发任何内容', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['', '   ', '\t', '']);
        async.flushMicrotasks();

        expect(h.written, isEmpty);
        expect(h.dispatcher.isBusy, isFalse);
      });
    });

    test('空行被跳过，非空行按序下发', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['sys', '', 'save']);
        async.flushMicrotasks();

        expect(h.written, ['sys\n']);
        expect(h.dispatcher.isBusy, isTrue);
      });
    });

    test('行尾符可配置为 \\r\\n', () {
      fakeAsync((async) {
        final h = _Harness(lineEnding: '\r\n');
        h.dispatcher.enqueue(['sys']);
        async.flushMicrotasks();

        expect(h.written, ['sys\r\n']);
      });
    });

    test('首尾空白被去掉后再下发', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['  sys  ']);
        async.flushMicrotasks();

        expect(h.written, ['sys\n']);
      });
    });
  });

  group('串行下发', () {
    test('未收到提示符前不下发第二条', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b', 'c']);
        async.flushMicrotasks();

        expect(h.written, ['a\n']);

        // 只来了回显，还没有提示符
        h.dispatcher.onOutput('a\r\n');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.written, ['a\n'], reason: '没有提示符就不该继续');

        // 提示符到达
        h.dispatcher.onOutput('[CoreSW]');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.written, ['a\n', 'b\n']);
      });
    });

    test('三条命令依次完成，事件顺序正确', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b', 'c']);
        async.flushMicrotasks();

        for (final cmd in ['a', 'b', 'c']) {
          h.dispatcher.onOutput('$cmd\r\n[CoreSW]');
          async.elapse(const Duration(milliseconds: 200));
        }

        expect(h.written, ['a\n', 'b\n', 'c\n']);
        expect(h.sent.map((e) => e.command).toList(), ['a', 'b', 'c']);
        expect(h.sent.map((e) => e.index).toList(), [1, 2, 3]);
        expect(h.sent.every((e) => e.total == 3), isTrue);
        expect(h.completed.map((e) => e.command).toList(), ['a', 'b', 'c']);
        expect(h.completed.every((e) => e.timedOut == false), isTrue);
        expect(h.events.whereType<QueueFinished>(), hasLength(1));
        expect(h.dispatcher.isBusy, isFalse);
      });
    });

    test('发送前重置缓冲，不会用上一条的提示符蒙混过关', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('a\r\n[CoreSW]');
        async.elapse(const Duration(milliseconds: 200));
        expect(h.written, ['a\n', 'b\n']);

        // 立刻推进去一个静默期，b 不应被判为完成
        async.elapse(const Duration(milliseconds: 200));
        expect(h.completed.map((e) => e.command).toList(), ['a']);
      });
    });
  });

  group('静默去抖', () {
    test('提示符出现但数据仍在流动时不判定完成', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('[CoreSW]');
        async.elapse(const Duration(milliseconds: 60)); // 不足去抖时长
        expect(h.written, ['a\n'], reason: '去抖未满，不该发下一条');

        h.dispatcher.onOutput('more data');
        async.elapse(const Duration(milliseconds: 60));
        expect(h.written, ['a\n'], reason: '新数据重置了去抖计时');

        async.elapse(const Duration(milliseconds: 200));
        // 缓冲区末尾是 "more data"，不匹配提示符 → 仍在等
        expect(h.written, ['a\n']);
      });
    });

    test('数据停住且末尾是提示符时判定完成', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('a\r\n[CoreSW]');
        async.elapse(const Duration(milliseconds: 119));
        expect(h.written, ['a\n']);

        async.elapse(const Duration(milliseconds: 2));
        expect(h.written, ['a\n', 'b\n']);
      });
    });

    test('内容行以 ] 结尾时会误判 —— 记录已知限制', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        // 这一行以 ] 结尾，且之后设备停顿超过去抖时长，
        // 于是被误判成提示符。spec §5.2 承认这是残留风险：
        // 静默去抖只能排除"数据仍在流动"的那部分误判。
        h.dispatcher.onOutput('GE0/0/1 is up [OK]');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.written, ['a\n', 'b\n']);
        expect(h.completed.single.command, 'a');
      });
    });

    test('内容行以 ] 结尾但随后仍有数据时不会误判', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        // 关键在于停顿不超过去抖窗口 —— 数据连续流动时不会误判
        h.dispatcher.onOutput('GE0/0/1 is up [OK');
        async.elapse(const Duration(milliseconds: 60));
        h.dispatcher.onOutput(']\r\n  still more output');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.written, ['a\n'], reason: '末尾不是提示符，应继续等待');
        expect(h.completed, isEmpty);
      });
    });
  });

  group('超时', () {
    test('超时后插入告警并强制放行下一条', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['hang', 'next']);
        async.flushMicrotasks();
        expect(h.written, ['hang\n']);

        h.dispatcher.onOutput('hang\r\n'); // 只回显，永不给提示符
        async.elapse(const Duration(seconds: 11));

        expect(h.written, ['hang\n', 'next\n']);
        expect(h.completed, hasLength(1));
        expect(h.completed.single.command, 'hang');
        expect(h.completed.single.timedOut, isTrue);
      });
    });

    test('write 同步抛异常时队列仍由超时兜底放行', () {
      fakeAsync((async) {
        final written = <String>[];
        var firstWrite = true;
        final h = _Harness(
          write: (data) {
            if (firstWrite) {
              firstWrite = false;
              // 模拟 StreamSink.add 落在已关闭的 controller 上这类同步抛出
              throw StateError('模拟 write 同步抛出');
            }
            written.add(data);
          },
        );

        expect(
          () => h.dispatcher.enqueue(['hang', 'next']),
          throwsA(isA<StateError>()),
        );
        async.flushMicrotasks();

        // 异常照常向外传播，但队列不能就此永久卡在"忙"状态：
        // 超时计时器必须已经起好，兜底强制放行。
        expect(h.dispatcher.isBusy, isTrue);

        async.elapse(const Duration(seconds: 11));

        expect(written, ['next\n'], reason: '超时后必须继续下发下一条');
        expect(h.completed, hasLength(1));
        expect(h.completed.single.command, 'hang');
        expect(h.completed.single.timedOut, isTrue);
      });
    });

    test('超时计时器在正常完成时被取消', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('a\r\n[CoreSW]');
        async.elapse(const Duration(milliseconds: 200));
        expect(h.completed.single.timedOut, isFalse);

        async.elapse(const Duration(seconds: 30));
        expect(h.completed, hasLength(1), reason: '不该有第二个完成事件');
      });
    });
  });

  group('翻页', () {
    test('识别翻页提示并回送空格', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();
        expect(h.written, ['display cur\n']);

        h.dispatcher.onOutput('line1\r\nline2\r\n  ---- More ----');
        async.flushMicrotasks();

        expect(h.written, ['display cur\n', ' ']);
        expect(h.events.whereType<PagerContinued>(), hasLength(1));
      });
    });

    test('翻页不推进队列，也不被当作命令完成', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('line1\r\n  ---- More ----');
        async.elapse(const Duration(milliseconds: 500));

        expect(h.completed, isEmpty);
        expect(h.written.last, ' ');
      });
    });

    test('翻页后继续输出，最终提示符到达才算完成', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('line1\r\n  ---- More ----');
        async.flushMicrotasks();
        h.dispatcher.onOutput('line2\r\n[CoreSW]');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.completed.single.command, 'display cur');
        expect(h.written, ['display cur\n', ' ', 'next\n']);
      });
    });

    test('以 > 结尾的翻页提示不会被误判为命令结束', () {
      fakeAsync((async) {
        // 对照组：`---- More ----` 不以 > 结尾，本来也匹配不上提示符正则，
        // 所以它在修复前后都不会被误判 —— 两边一比就能看出问题只在尾巴形态。
        final control = _Harness();
        control.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();
        control.dispatcher.onOutput('line1\r\n  ---- More ----');
        async.elapse(const Duration(milliseconds: 200));
        expect(control.completed, isEmpty);
        expect(control.written, ['display cur\n', ' ']);

        // 缺陷组：H3C 的 `<--- More --->` 以 > 结尾，能匹配提示符正则。
        // 去抖到点后若不显式排除翻页尾巴，命令会被判为完成，下一条命令
        // 就会被写进仍在翻页的设备，并被当作翻页键吃掉。
        final h = _Harness();
        h.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();
        h.dispatcher.onOutput('line1\r\n  <--- More --->');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.completed, isEmpty, reason: '翻页提示不是提示符，命令仍在途');
        expect(h.written, ['display cur\n', ' '], reason: '不该下发下一条命令');
        expect(h.dispatcher.isBusy, isTrue);
      });
    });
  });

  group('中止队列', () {
    test('中止后不再发送剩余命令', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b', 'c']);
        async.flushMicrotasks();
        expect(h.written, ['a\n']);

        h.dispatcher.abort();
        async.flushMicrotasks();

        expect(h.written, ['a\n'], reason: '中止后不该再写任何东西');
        expect(h.dispatcher.isBusy, isFalse);
        expect(h.events.whereType<QueueAborted>(), hasLength(1));
        expect(h.events.whereType<QueueAborted>().single.dropped, 2);
        expect(h.events.whereType<QueueFinished>(), isEmpty);
      });
    });

    test('中止后可以重新入队', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();
        h.dispatcher.abort();
        async.flushMicrotasks();

        h.dispatcher.enqueue(['x']);
        async.flushMicrotasks();

        expect(h.written, ['a\n', 'x\n']);
        expect(h.sent.last.index, 1);
        expect(h.sent.last.total, 1);
      });
    });

    test('空闲时中止不产生事件', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.abort();
        async.flushMicrotasks();

        expect(h.events, isEmpty);
      });
    });
  });

  group('断线', () {
    test('断线丢弃未发完的队列并告警', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b', 'c']);
        async.flushMicrotasks();
        expect(h.written, ['a\n']);

        h.dispatcher.onDisconnected();
        async.flushMicrotasks();

        expect(h.written, ['a\n'], reason: '断线后不应重放队列');
        expect(h.dispatcher.isBusy, isFalse);
        expect(h.events.whereType<QueueDropped>().single.count, 3);
      });
    });

    test('断线后超时计时器不再触发', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a']);
        async.flushMicrotasks();
        h.dispatcher.onDisconnected();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 30));
        expect(h.events.whereType<CommandCompleted>(), isEmpty);
      });
    });

    test('空闲时断线不产生丢弃事件', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.onDisconnected();
        async.flushMicrotasks();

        expect(h.events.whereType<QueueDropped>(), isEmpty);
      });
    });
  });

  group('缓冲区', () {
    test('缓冲区超限时丢弃最旧的数据', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        // 灌入远超缓冲上限的数据，末尾放提示符
        final flood = 'x' * 20000;
        h.dispatcher.onOutput(flood);
        async.elapse(const Duration(milliseconds: 200));
        expect(h.written, ['a\n'], reason: '缓冲区被冲掉了提示符，仍在等');

        h.dispatcher.onOutput('\r\n[CoreSW]');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.written, ['a\n', 'b\n']);
      });
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/command/command_dispatcher_test.dart
```

Expected：FAIL，`Error when reading 'package:win_cli_tool/command/command_dispatcher.dart': No such file or directory`。

- [ ] **Step 3: 实现 CommandDispatcher**

创建 `lib/command/command_dispatcher.dart`：

```dart
import 'dart:async';

import 'more_pager.dart';
import 'prompt_detector.dart';

/// 一次下发批次中发生的事件。
sealed class DispatchEvent {
  const DispatchEvent();
}

/// 一条命令已写出。
class CommandSent extends DispatchEvent {
  const CommandSent(this.command, this.index, this.total);

  final String command;

  /// 在本次批次中的序号，从 1 开始。
  final int index;
  final int total;
}

/// 一条命令已结束（正常完成或超时）。
class CommandCompleted extends DispatchEvent {
  const CommandCompleted(
    this.command, {
    required this.timedOut,
    required this.index,
    required this.total,
  });

  final String command;
  final bool timedOut;

  /// 在本次批次中的序号，从 1 开始。超时告警行要注明序号（spec §5.2）。
  final int index;
  final int total;
}

/// 识别到翻页提示并已回送继续键。
class PagerContinued extends DispatchEvent {
  const PagerContinued();
}

/// 一个批次全部执行完毕。
class QueueFinished extends DispatchEvent {
  const QueueFinished();
}

/// 用户主动中止了队列。[dropped] 是未发出的命令数。
class QueueAborted extends DispatchEvent {
  const QueueAborted(this.dropped);

  final int dropped;
}

/// 连接断开导致队列被丢弃。[count] 是丢弃的命令数。
class QueueDropped extends DispatchEvent {
  const QueueDropped(this.count);

  final int count;
}

/// 命令队列与串行下发状态机。
///
/// 核心不变式：**同一时刻只有一条命令在途**。发出一条后必须等到提示符
/// （且数据静默）或超时，才会发出下一条。这是网络设备 CLI 的硬性要求
/// —— 连着灌命令会让回显与命令错位。
class CommandDispatcher {
  CommandDispatcher({
    required this.write,
    required this.promptDetector,
    required this.morePager,
    this.lineEnding = '\n',
    this.promptDebounce = const Duration(milliseconds: 120),
    this.commandTimeout = const Duration(seconds: 10),
    this.bufferLimit = 8192,
  });

  /// 把一条命令写出去（不含行尾符，由本类补）。
  final void Function(String data) write;

  /// 提示符判定器。
  final PromptDetector promptDetector;

  /// 翻页判定器。
  final MorePager morePager;

  /// 命令行尾符。
  final String lineEnding;

  /// 静默去抖时长：命中提示符后还要等这么久没有新数据才算完成。
  final Duration promptDebounce;

  /// 单条命令的执行超时。
  final Duration commandTimeout;

  /// 接收缓冲区上限，超出丢弃最旧的数据。
  final int bufferLimit;

  final _events = StreamController<DispatchEvent>.broadcast();

  final _queue = <String>[];
  final _batch = <String>[];
  String? _current;
  var _currentIndex = 0;
  String _buffer = '';
  Timer? _debounce;
  Timer? _timeout;
  var _aborted = false;
  var _disposed = false;

  /// 事件流，供界面渲染进度与告警。
  Stream<DispatchEvent> get events => _events.stream;

  /// 是否有命令在途。
  bool get isBusy => _current != null;

  /// 当前批次的命令总数。
  int get total => _batch.length;

  /// 当前批次已发出的命令数。
  int get sentCount => _currentIndex;

  /// 把一批命令加入队列。
  ///
  /// 完全空白的行会被跳过（spec FR-E-08）—— 避免空回车污染回显。行首尾
  /// 空白会被去掉。若清洗后为空则什么都不做。
  ///
  /// 批次执行中调用会**追加**到当前批次，批次总数随之变大：先前报
  /// `3/8` 的进度事件，之后再报就是 `4/10`。因此 [CommandSent.total]
  /// / [CommandCompleted.total] 反映的是**事件发出那一刻**的批次规模，
  /// 不是最终规模。
  void enqueue(Iterable<String> commands) {
    if (_disposed) return;
    final cleaned = commands
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) return;

    if (isBusy) {
      // 批次执行中：追加到当前批次
      _queue.addAll(cleaned);
      _batch.addAll(cleaned);
      return;
    }

    _batch
      ..clear()
      ..addAll(cleaned);
    _queue
      ..clear()
      ..addAll(cleaned);
    _aborted = false;
    _emitNext();
  }

  /// 把设备输出喂进来。
  void onOutput(String chunk) {
    if (_disposed || !isBusy) return;

    _buffer += chunk;
    if (_buffer.length > bufferLimit) {
      _buffer = _buffer.substring(_buffer.length - bufferLimit);
    }

    if (morePager.matchesTail(_buffer)) {
      // 翻页（spec §5.3）：立即回送一个空格继续。翻页动作不计入命令队列，
      // 不产生队列进度变化，也**不重置命令超时** —— 一条命令翻十页仍然
      // 只受一个 10s 超时约束。
      //
      // 去抖计时照常重置：翻页提示本身就是"新数据到达"。
      // 此刻缓冲区末尾仍是翻页提示，_checkPrompt 必须显式排除它，
      // 否则 `<--- More --->` 这类以 `>` 结尾的提示会被误判成命令结束。
      write(MorePager.continueKey);
      _events.add(const PagerContinued());
      _restartDebounce();
      return;
    }

    _restartDebounce();
  }

  /// 用户主动中止。不再发送队列中剩余的命令；已发出的那条不做处理
  /// （spec FR-E-13），因此它不计入 [QueueAborted.dropped]。
  void abort() {
    if (_disposed) return;
    final dropped = _queue.length;
    final hadCurrent = _current != null;
    if (dropped == 0 && !hadCurrent) return;

    _aborted = true;
    _cancelTimers();
    _queue.clear();
    _batch.clear();
    _current = null;
    _currentIndex = 0;
    _events.add(QueueAborted(dropped));
  }

  /// 连接断开。未发出的命令一律丢弃，**不自动重放**（spec FR-C-10）：
  /// 网络设备上重放配置下发可能造成重复配置。
  ///
  /// 与 [abort] 不同，在途的那条命令**计入**丢弃数 —— 它的输出已经永远
  /// 收不到了，用户需要知道这条命令的结果是未知的。
  void onDisconnected() {
    if (_disposed) return;
    final dropped = _queue.length + (_current != null ? 1 : 0);
    _cancelTimers();
    _queue.clear();
    _batch.clear();
    _current = null;
    _currentIndex = 0;
    if (dropped > 0) {
      _events.add(QueueDropped(dropped));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelTimers();
    _queue.clear();
    _batch.clear();
    _current = null;
    _currentIndex = 0;
    await _events.close();
  }

  void _emitNext() {
    if (_aborted || _queue.isEmpty) {
      _finish();
      return;
    }
    final cmd = _queue.removeAt(0);
    _current = cmd;
    _currentIndex = _batch.length - _queue.length;
    // 清空缓冲区：否则上一条命令残留的提示符会让本条瞬间"完成"
    _buffer = '';
    // 先起超时再写出：若注入的 write 同步抛异常，队列仍有超时兜底，
    // 不会永久卡在"忙"状态（spec 要求超时必须强制放行下一条）。
    _restartTimeout();
    write('$cmd$lineEnding');
    _events.add(CommandSent(cmd, _currentIndex, _batch.length));
  }

  void _restartDebounce() {
    _debounce?.cancel();
    _debounce = Timer(promptDebounce, _checkPrompt);
  }

  void _restartTimeout() {
    _timeout?.cancel();
    _timeout = Timer(commandTimeout, () {
      if (_current == null) return;
      final cmd = _current!;
      final index = _currentIndex;
      final total = _batch.length;
      _current = null;
      _currentIndex = 0;
      _cancelTimers();
      _events.add(
        CommandCompleted(cmd, timedOut: true, index: index, total: total),
      );
      _emitNext();
    });
  }

  void _checkPrompt() {
    if (_current == null) return;
    // 翻页提示不能当成提示符。`<--- More --->` 以 `>` 结尾，本来就能匹配
    // 默认提示符正则；若在此判定完成，下一条命令会被发进仍在翻页的设备，
    // 被它当作翻页按键吃掉 —— 命令看似已下发，实际从未执行。
    if (morePager.matchesTail(_buffer)) return;
    if (!promptDetector.matches(_buffer)) {
      // 没有提示符就继续等，由超时计时器兜底
      return;
    }
    _completeCurrent(timedOut: false);
  }

  void _completeCurrent({required bool timedOut}) {
    final cmd = _current!;
    final index = _currentIndex;
    final total = _batch.length;
    _current = null;
    _currentIndex = 0;
    _cancelTimers();
    _events.add(
      CommandCompleted(cmd, timedOut: timedOut, index: index, total: total),
    );
    _emitNext();
  }

  void _finish() {
    _cancelTimers();
    _currentIndex = 0;
    if (_batch.isNotEmpty) {
      _batch.clear();
      _events.add(const QueueFinished());
    }
  }

  void _cancelTimers() {
    _debounce?.cancel();
    _debounce = null;
    _timeout?.cancel();
    _timeout = null;
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
flutter test test/command/command_dispatcher_test.dart
```

Expected：PASS，25 个测试全绿。

其中 `'内容行以 ] 结尾时会误判 —— 记录已知限制'` 断言的是**误判确实会发生**，这不是 bug 而是 spec §5.2 明确接受的残留风险（静默去抖只能排除"数据仍在流动"的那部分误判）。它的姊妹测试 `'内容行以 ] 结尾但随后仍有数据时不会误判'` 则证明去抖在数据连续流动时确实起作用。两条一起看，才算把这道边界钉住。

- [ ] **Step 5: 提交**

```bash
git add lib/command/command_dispatcher.dart test/command/command_dispatcher_test.dart
git commit -m "feat: 添加命令队列与串行下发状态机

核心不变式：同一时刻只有一条命令在途。含静默去抖、超时强制放行、
翻页不推进队列、中止队列、断线丢弃队列（不重放）。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Task 9: 端到端集成测试

**Files:**
- Create: `test/e2e/dispatch_e2e_test.dart`

前八个任务都是分层单测。这一条把真实 TCP、假设备、Telnet 会话、命令队列全部串起来，验证 spec §5.2 与 §5.3 在真实网络 IO 下成立 —— 这是本计划唯一的验收关。

- [ ] **Step 1: 写端到端测试**

创建 `test/e2e/dispatch_e2e_test.dart`：

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/command_dispatcher.dart';
import 'package:win_cli_tool/command/more_pager.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';
import 'package:win_cli_tool/connection/telnet_session.dart';
import 'package:win_cli_tool/models/device_profile.dart';

import '../fixtures/fake_device_server.dart';

/// 把会话与命令队列接起来，模拟界面层要做的接线。
class _Wired {
  _Wired(this.session) {
    dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: PromptDetector(),
      morePager: MorePager(),
      lineEnding: '\n',
      promptDebounce: const Duration(milliseconds: 120),
      commandTimeout: const Duration(seconds: 10),
    );
    _sub = session.output.listen(dispatcher.onOutput);
    // session.done 是 Future 不是 Stream，所以用 then 而非 listen
    session.done.then((_) => dispatcher.onDisconnected());
  }

  final TelnetSession session;
  late final CommandDispatcher dispatcher;
  StreamSubscription<String>? _sub;

  Future<void> dispose() async {
    await _sub?.cancel();
    await dispatcher.dispose();
    await session.close();
  }
}

DeviceProfile _profile(int port) => DeviceProfile(
      id: 'd1',
      name: '假设备',
      protocol: DeviceProtocol.telnet,
      host: '127.0.0.1',
      port: port,
      username: 'admin',
    );

void main() {
  test('三条命令在真实连接上按序、串行完成', () async {
    final device = await FakeDeviceServer.start(
      prompt: '[CoreSW]',
      responseFor: {
        'sys': ['Enter system view'],
        'interface GE0/0/1': ['Interface created'],
        'quit': ['Back to user view'],
      },
    );
    addTearDown(device.stop);

    final session = TelnetSession(profile: _profile(device.port));
    final wired = _Wired(session);
    addTearDown(wired.dispose);

    final output = <String>[];
    session.output.listen(output.add);

    await session.connect();

    wired.dispatcher.enqueue(['sys', 'interface GE0/0/1', 'quit']);
    await _waitUntil(() => !wired.dispatcher.isBusy);

    expect(device.receivedCommands, ['sys', 'interface GE0/0/1', 'quit']);

    final all = output.join();
    expect(all, contains('Enter system view'));
    expect(all, contains('Interface created'));
    expect(all, contains('Back to user view'));
  });

  test('空行被跳过，设备收不到空命令', () async {
    final device = await FakeDeviceServer.start(prompt: '[CoreSW]');
    addTearDown(device.stop);

    final session = TelnetSession(profile: _profile(device.port));
    final wired = _Wired(session);
    addTearDown(wired.dispose);
    await session.connect();

    wired.dispatcher.enqueue(['sys', '', '   ', 'save']);
    await _waitUntil(() => !wired.dispatcher.isBusy);

    expect(device.receivedCommands, ['sys', 'save']);
  });

  test('分页输出被自动翻页，最终完整到达', () async {
    final device = await FakeDeviceServer.start(
      prompt: '[CoreSW]',
      pagerEvery: 2,
      responseFor: {
        'display current-configuration': [
          'line1',
          'line2',
          'line3',
          'line4',
          'line5',
        ],
      },
    );
    addTearDown(device.stop);

    final session = TelnetSession(profile: _profile(device.port));
    final wired = _Wired(session);
    addTearDown(wired.dispose);

    final output = <String>[];
    session.output.listen(output.add);
    final pagerEvents = <DispatchEvent>[];
    wired.dispatcher.events.listen(pagerEvents.add);

    await session.connect();
    wired.dispatcher.enqueue(['display current-configuration', 'done-marker']);
    await _waitUntil(() => !wired.dispatcher.isBusy);

    final all = output.join();
    for (final l in ['line1', 'line2', 'line3', 'line4', 'line5']) {
      expect(all, contains(l), reason: '分页内容 $l 应当完整到达');
    }
    expect(pagerEvents.whereType<PagerContinued>(), isNotEmpty);
    expect(device.receivedCommands, ['display current-configuration', 'done-marker']);
  });

  test('命令不回应时超时，队列继续往下走', () async {
    final device = await FakeDeviceServer.start(
      prompt: '[CoreSW]',
      hangCommands: {'reboot'},
    );
    addTearDown(device.stop);

    final session = TelnetSession(profile: _profile(device.port));
    addTearDown(session.close);
    await session.connect();

    // 真实超时默认 10s，测试里等不起，所以单独构造一个短超时的调度器。
    // 这里不用 _Wired：本测试只关心调度器本身，且两个调度器同时消费
    // session.output 会让数据流互相干扰。
    final dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: PromptDetector(),
      morePager: MorePager(),
      commandTimeout: const Duration(milliseconds: 500),
      promptDebounce: const Duration(milliseconds: 100),
    );
    final sub = session.output.listen(dispatcher.onOutput);
    addTearDown(sub.cancel);
    addTearDown(dispatcher.dispose);

    final completions = <CommandCompleted>[];
    dispatcher.events.listen((e) {
      if (e is CommandCompleted) completions.add(e);
    });

    dispatcher.enqueue(['reboot', 'display version']);
    await _waitUntil(
      () => !dispatcher.isBusy,
      timeout: const Duration(seconds: 8),
    );

    expect(completions, hasLength(2));
    expect(completions.first.command, 'reboot');
    expect(completions.first.timedOut, isTrue);
    expect(completions.first.index, 1);
    expect(completions.first.total, 2);
    expect(completions.last.command, 'display version');
    expect(completions.last.timedOut, isFalse);
    expect(device.receivedCommands, contains('display version'));
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('设备断开时队列被丢弃且不重放', () async {
    // 'a' 永不返回提示符，队列因此必然停在半途：
    // 'a' 在途、'b' 与 'c' 还在排队。否则三条命令可能瞬间跑完，
    // 断开时已经没有东西可丢，测试会变成一道竞态。
    final device = await FakeDeviceServer.start(
      prompt: '[CoreSW]',
      hangCommands: {'a'},
    );
    final session = TelnetSession(profile: _profile(device.port));
    final wired = _Wired(session);
    addTearDown(wired.dispose);
    await session.connect();

    final dropped = <QueueDropped>[];
    wired.dispatcher.events.listen((e) {
      if (e is QueueDropped) dropped.add(e);
    });

    wired.dispatcher.enqueue(['a', 'b', 'c']);
    await _waitUntil(() => device.receivedCommands.contains('a'));
    expect(wired.dispatcher.isBusy, isTrue);

    await device.stop();
    await _waitUntil(() => dropped.isNotEmpty);

    // 在途的 'a' 加排队的 'b'、'c'，共 3 条
    expect(dropped.single.count, 3);
    expect(wired.dispatcher.isBusy, isFalse);
    // 断线后不得重放：设备侧只见过 'a'
    expect(device.receivedCommands, ['a']);
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
```

- [ ] **Step 2: 运行测试**

```bash
flutter test test/e2e/dispatch_e2e_test.dart
```

Expected：PASS，5 个测试全绿。

如果有失败，**优先怀疑假设备服务器**而不是调度器 —— 前八个任务的单测已经覆盖了调度器的逻辑，端到端失败通常是夹具的行为与真实设备不一致。

- [ ] **Step 3: 跑全量测试**

```bash
flutter test
flutter analyze
```

Expected：全部 PASS，`flutter analyze` 输出 `No issues found!`。

- [ ] **Step 4: 提交**

```bash
git add test/e2e
git commit -m "test: 添加端到端下发链路测试

真实 TCP + 假设备 + Telnet 会话 + 命令队列，验证串行下发、
空行跳过、自动翻页、超时放行、断线丢弃在真实 IO 下成立。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## 完成标准

本计划完成后，以下命令应当全绿：

```bash
flutter analyze && flutter test
```

届时具备的能力：

- 能把一串命令以**正确的节奏**下发到一台 Telnet 网络设备，不会串行错乱
- 提示符识别可穿透 ANSI 颜色码，并有静默去抖抵御内容行误判
- 分页输出自动翻页直到完整
- 命令不回应时超时放行，不会卡死整个队列
- 断线丢弃未发命令且不重放

**尚未具备**（属于后续计划）：SSH、跳板机、AnsiParser 的着色渲染、日志落盘、持久化、界面。

---

## 后续计划

| # | 计划 | 依赖 |
|---|---|---|
| 2 | SSH 与跳板机 | 本计划的 `Connector` / `Session`；新增 `SshSession`、`SshTunnelConnector`、`JumpHostPool` |
| 3 | 输出与日志 | 本计划的 `lib/render/ansi.dart`（在其上扩展 SGR 解析）、`CommandDispatcher` 的事件流 |
| 4 | 持久化 | 本计划的模型层；新增三个 Store 与 v1→v2 迁移 |
| 5 | 界面 | 以上全部 |
| 6 | 打包与 CI | 计划 5 |
