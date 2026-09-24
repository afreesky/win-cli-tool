# SSH 会话与重连 实现计划（计划 2）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让工具能通过 SSH 连上设备并维持长连接 —— 包含主机密钥校验、可读的失败原因、断线自动重连，以及一次可选的并发模型改造（见 Task 0）。

**Architecture:** 在计划 1 已有的 `Connector`/`Connection` 传输抽象与 `Session` 会话抽象之上，新增三块：① `ConnectionSocket` 把我们的 `Connection` 适配成 dartssh2 的 `SSHSocket`（这一步是计划 3 跳板机能够复用同一份 `SshSession` 的前提）；② `SshSession` 用 dartssh2 申请 PTY shell，把输出接进既有 `Session` 契约；③ `ConnectionManager` 持有会话生命周期、指数退避重连与每设备的 `CommandDispatcher`。主机密钥的持久化通过**注入的** `HostKeyStore` 接口完成，计划 2 自己不写文件（spec §13.5）。

**Tech Stack:** Flutter 3.44.4 / Dart 3.12.2、`dartssh2` 4.1.0（已确认可解析）、`clock`（`ConnectionManager` 的时间源，见 Task 6）、`flutter_test`、`fake_async`。

---

## 执行前必读

### 本计划的四条硬约束（来自 spec §13，违反即为缺陷）

| 约束 | 出处 | 在本计划中的落点 |
|---|---|---|
| 转发 `session.done` 前必须查 `_closed` 标志 | §13.14-5 | Task 4 的 `_onDisconnected` |
| 始终显式传 `onVerifyHostKey`，不得留 `null` | §13.14-1 | Task 4 的 `SSHClient(...)` 构造 |
| 错误分类看 `.reason`，不看顶层类型或消息 | §13.15 | Task 3 的 `classifyConnectionFailure` |
| `ConnectionSocket` 的 `_sink` 必须 `sync: true` | §13.18-1 | Task 1；Task 4 的 `SshSession.close()` 依赖它 |

### 已由探针实测确认的 API 事实（不要凭记忆改写）

- `SSHClient(socket, username:, identities:, onPasswordRequest:, onVerifyHostKey:, keepAliveInterval:)`，无 `connect()`；用 `await client.authenticated`。
- `client.shell(pty: SSHPtyConfig(type:, width:, height:))` → `SSHSession`，其 `stdout` 是 `Stream<Uint8List>`。
- **`session.stdout` 必须 `.cast<List<int>>()` 后才能 `.transform(Utf8Decoder())`** —— 与计划 1 `connector.dart` 记录的是同一个协变陷阱。
- `SSHSession.flush()` 不可用（会丢出未处理的异步错误并丢失写入内容）—— 这是**不要**给 `Session` 加 `flush()` 的理由之一。
- `session.close()` **不**完成 `session.done`；`client.close()` **会**完成 —— 见上表第 1 行。
- **`Session` 接口没有 `flush()` 成员**（只有 `Connection` 有）。调研时曾记作「`Session.flush()` 对 SSH 必须是空操作」，那是基于一个不存在的成员。**本计划不新增 `flush()`** —— 没有任何调用方需要它，而 `SshSession` 用的是 dartssh2 的 `write()`，它本身不缓冲，加一个空操作只是徒增接口面积（YAGNI）。若将来确实需要，届时再加，并在此处记录 dartssh2 的 `SSHSession.flush()` 不可用（会丢出未处理的异步错误并丢失写入内容）。
- 主机密钥被拒与算法协商失败抛出的异常**类型与 `toString` 完全相同**，只有 `.reason` 不同。
- `SSHKeyPair.fromPem(pem)` 返回 `List<SSHKeyPair>`；带口令时 `SSHKeyPair.fromPem(pem, passphrase)`。
- `SSHForwardChannel.close()` 会挂起 → 用 `destroy()`（计划 3 用，本计划不涉及）。

### 测试写法上的三条实测约束（详见 spec §13.16，违反会写出假测试/假失败）

- **拆除（cancel / close / dispose）相关断言用真实 `async`，不要用 `fakeAsync`** —— 它推不动那条 await 链，卡住时 `pendingTimers` 与 `microtaskCount` 都是 0，怎么 flush 都没用。
- **断言类型用 `expect(v, isA<T>())`，永不用 `expect(v.runtimeType, T)`** —— `Uint8List` 的 `runtimeType` 与类型字面量不 `==`，失败信息还长成 `Expected: Uint8List, Actual: Uint8List`。
- **时间用 `clock.now()`，不用 `DateTime.now()`** —— 否则 `fake_async` 里算出的时长恒为 0。

### 每个 Task 的固定节奏

1. 写失败测试 → 2. 运行并**看到它失败**（把失败输出贴进报告）→ 3. 写最小实现 → 4. 运行通过 → 5. `dart analyze` → 6. 提交。

**第 2 步不可跳过。** 计划 1 的教训：108 个全绿的测试里，有三个承载行为的测试其实什么都没约束（spec §13.9/§13.11/§13.12 的缺陷正是这样漏过去的）。测试只有在**先看到它红**之后才有证据价值。

---

## Task 0: 并发模型改造 — `Session` 之上的所有权收敛

**Files:**
- Modify: `lib/connection/connection_manager.dart`（本 Task 只创建骨架）

**为什么这个 Task 排在最前面：** 计划 2 要引入 `ConnectionManager`，它需要按设备持有会话、订阅输出、并在重连时替换整个会话对象。计划 1 的 `Session.output` 是 `broadcast`，任何订阅者都拿得到；但**谁负责在重连时把旧会话的订阅者迁移到新会话上**，必须在写 `SshSession` 之前定下来，否则会出现「重连成功了，但界面还在听那个已经死掉的旧会话」——表现为输出区在第一次断线后永久静止，而按钮是绿的。

**本 Task 的决定：所有权归 `ConnectionManager`，界面只订阅 `ConnectionManager`，永不直接订阅 `Session`。**

理由：设备的会话对象在重连时会被整个替换，而 `ConnectionManager` 是唯一知道「什么时候换了」的角色。若界面直接持有 `Session.output`，重连的语义就必须由每个订阅点各自重新实现一遍。

**落到类型上**：`SessionReady` 携带的是本次会话的 `CommandDispatcher`，**不是** `Session`。每次重连都会新建一个 dispatcher，界面正是在收到 `SessionReady` 时重新订阅 `dispatcher.events`（命令输出与 `QueueDropped` 都从那里来）—— 把交付点与"该重新订阅了"这件事绑在一起，界面就没有任何理由去碰 `Session`。若这里给的是 `Session`，界面很自然会写出 `event.session.output.listen(...)`，正好落进本节要避免的那个坑；而且它真正需要的 dispatcher 只能从 `mgr.dispatcher` 这个拆除后就变 `null` 的 getter 上取，等于把一条没说出口的时序约定藏起来。

输出（`ConnectionManager.output`）与状态（`state`）在构造时拿到，全程只订阅一次；`events` 与每个会话的 `dispatcher.events` 是仅有的两处订阅。

- [ ] **Step 1: 创建 `lib/connection/connection_manager.dart`，只放状态枚举与事件类型**

```dart
import '../command/command_dispatcher.dart';
import 'connection_failure.dart';

/// 一台设备的连接状态。与 spec §5.4 的按钮颜色一一对应。
///
/// 颜色映射（供计划 5 使用）：disconnected→灰、connecting→黄、
/// connected→绿、reconnecting→黄、failed→红。
///
/// 注意"红"：§5.4 的逐事件表里**没有**红（只有黄/黄/绿/灰），红来自
/// FR-C-06 的"连接失败"。`failed` 何时可达目前尚未定论，见 spec §13.17-3。
enum DeviceConnectionState {
  /// 未连接。与 [connecting]/[reconnecting] 同为"没有连接"，
  /// 但颜色不同：这两个是黄，本状态是灰。
  disconnected,
  connecting,
  connected,

  /// 重连中。与 [connecting] **颜色相同**（都是黄），区别只在输出区文案。
  reconnecting,

  /// 连接失败且**不再自动重试**（`autoReconnect` 为 false 时）。
  ///
  /// 注意：用户主动断开**不是**这个状态 —— §5.4 要求那种情况按钮变灰，
  /// 也就是 [disconnected]。
  failed;

  /// 该状态下设备按钮是否应显示为"有连接"。重连中算"没有连接"——
  /// 此时发给设备的命令会失败，界面必须让用户看出来。
  bool get isLive => this == DeviceConnectionState.connected;
}

/// [ConnectionManager] 对外发出的事件。每台设备一个 manager，各自一条流。
///
/// 声明为 `sealed`：界面（计划 5）对它的 switch 会被编译器要求穷尽，
/// 将来新增一种事件会成为**编译错误**，而不是某个分支悄悄不渲染。
sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// 状态迁移。界面据此更新按钮颜色与输出区提示。
final class ConnectionStateChanged extends ConnectionEvent {
  const ConnectionStateChanged(this.state);

  final DeviceConnectionState state;
}

/// 会话已就绪（首次连接或重连成功），可以下发命令了。
///
/// 携带的是本次会话的 [CommandDispatcher]：每次重连都会**新建**一个，
/// 所以界面必须在这里重新订阅 `dispatcher.events`（命令输出与
/// [QueueDropped] 都从那里来）。
///
/// **界面不得订阅 `Session.output`** —— 会话对象在重连时会被整个替换，
/// 直接订阅它会让输出区在第一次断线后永久静止而按钮是绿的。
/// 输出请订阅 `ConnectionManager.output`。
final class SessionReady extends ConnectionEvent {
  const SessionReady(this.dispatcher);

  final CommandDispatcher dispatcher;
}

/// 即将在 [delay] 之后发起第 [attempt] 次重连（从 1 开始）。
final class ReconnectScheduled extends ConnectionEvent {
  const ReconnectScheduled(this.attempt, this.delay);

  final int attempt;
  final Duration delay;
}

/// 重连成功。FR-C-09 要求输出区插入醒目分隔标记，[downtime] 即断线时长。
final class Reconnected extends ConnectionEvent {
  const Reconnected(this.downtime, this.attempt);

  /// 从断开到重连成功经过的时长（FR-C-09 的标记要显示它）。
  final Duration downtime;

  /// 是第几次重连尝试成功的（从 1 开始）。
  ///
  /// 计数在**连接成功**时归零，所以它只统计本次断线期间的重试次数。
  /// 首次就连接成功不发本事件（attempt 恒 > 0）。
  final int attempt;
}

/// 连接失败。[failure] 携带可读原因（FR-C-06）。
final class ConnectionFailed extends ConnectionEvent {
  const ConnectionFailed(this.failure);

  final ConnectionFailure failure;
}

/// 会话断开。
///
/// 被丢弃的命令数**不在**这里 —— 它在 [CommandDispatcher] 的 [QueueDropped]
/// 上（那是计划 1 已有的契约，界面直接订阅 `dispatcher.events` 取用）。
/// 一次断线只发**一个**本事件。
final class SessionLost extends ConnectionEvent {
  const SessionLost(this.failure);

  /// null 表示对端正常结束，或本次断开没有可分类的错误 ——
  /// 界面需要自备兜底文案。
  final ConnectionFailure? failure;
}
```

- [ ] **Step 2: 运行分析器确认无错**

Run: `dart analyze lib/connection/connection_manager.dart`
Expected: **3 条**错误，全部来自 `connection_failure.dart` 尚未创建（Task 3 才建它）：
`uri_does_not_exist` 一条，加上 `ConnectionFailure` 的两处 `undefined_class`（`ConnectionFailed` 与 `SessionLost` 的字段类型）。

```
error - connection_manager.dart:2:8 - Target of URI doesn't exist: 'connection_failure.dart'. - uri_does_not_exist
error - connection_manager.dart:88:9 - Undefined class 'ConnectionFailure'. - undefined_class
error - connection_manager.dart:101:9 - Undefined class 'ConnectionFailure'. - undefined_class
```

**不得出现 `unused_import`** —— 若出现，说明 `command_dispatcher.dart` 没被用到（`SessionReady` 的载荷就是它）。

- [ ] **Step 3: 提交**

```bash
git add lib/connection/connection_manager.dart
git commit -m "feat: 连接状态与事件的类型骨架"
```

> **注意**：本 Task 不写测试，因为它只定义类型、没有任何行为。真正的行为测试在 Task 6。这是本计划中**唯一**一个跳过"先红后绿"的 Task，理由是没有可断言的行为。

---

## Task 1: `ConnectionSocket` —— 把 `Connection` 适配成 `SSHSocket`

**Files:**
- Modify: `pubspec.yaml`（加 `dartssh2: ^4.1.0` 与 `clock: ^1.1.1`）
- Create: `lib/connection/connection_socket.dart`
- Test: `test/connection/connection_socket_test.dart`

**这一步的意义：** `SSHClient` 只接受 `SSHSocket`，而本项目的传输抽象是 `Connection`。有了这层适配，SSH 就能建在**任意** `Connection` 之上 —— 直连可以，跳板机隧道也可以。计划 3 正是靠它把第 N+1 跳建在第 N 跳上，且**不需要改动 `SshSession` 一行**。

- [ ] **Step 1: 加依赖**

```bash
flutter pub add dartssh2:^4.1.0 clock:^1.1.1
```

Expected: `Changed 7 dependencies!` —— 新增 `asn1lib` / `convert` / `dartssh2` / `pinenacl` / `pointycastle` / `typed_data`，外加一行
`clock 1.1.2 (from transitive dependency to direct dependency)`。

（`clock` 本来就在传递依赖里，这里只是提升为直接依赖 —— 但**必须**显式声明才能 `import 'package:clock/clock.dart'`。`collection` 与 `meta` 已在锁文件里，不会出现在新增列表里。）

随后给 `clock` 补一条注释。它在计划 2 里要等到 Task 6 才被 import，在那之前它是这个依赖块里**唯一没有本地证据支撑**的一项（`dartssh2` 有 `connection_socket.dart` 直接 import 它），最容易被 IDE 的"未使用依赖"提示或一次顺手清理删掉 —— 而后果要到 Task 6 才以编译错误的形式冒出来，离原因隔了四个 Task。`pubspec.yaml` 里补成：

```yaml
  dartssh2: ^4.1.0
  # 可被 fake_async 接管的时间源：ConnectionManager 用它计算 FR-C-09 的
  # 断线时长。用 DateTime.now() 的话，测试里 fakeAsync.elapse() 推进的是
  # 假时钟，而 DateTime.now() 是真实时间，断线时长恒为 0，无法断言。
  clock: ^1.1.1
```

- [ ] **Step 2: 写失败测试**

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_socket.dart';
import 'package:win_cli_tool/connection/connector.dart';

/// 可手动喂入字节、并记录写出的字节的假连接。
class _FakeConnection implements Connection {
  final _input = StreamController<List<int>>();
  final written = <int>[];

  /// `close()` 之后仍被写入的字节。真实的 `_SocketConnection` 会在这一步
  /// **静默丢弃**，所以必须记下来 —— 否则"写出去后立刻 close()"的丢包
  /// 是断言不到的（写丢了一个字节都不报错，正是它危险的地方）。
  final writeAfterClose = <int>[];
  var closed = false;
  var flushCalls = 0;

  @override
  Stream<List<int>> get input => _input.stream;

  void feed(List<int> bytes) {
    if (closed) return;
    _input.add(bytes);
  }

  void feedError(Object error) {
    if (closed) return;
    _input.addError(error);
  }

  Future<void> feedDone() => _input.close();

  @override
  void write(List<int> data) {
    if (closed) {
      writeAfterClose.addAll(data);
      return;
    }
    written.addAll(data);
  }

  @override
  Future<void> flush() async {
    flushCalls++;
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(_input.close());
  }
}

void main() {
  test('对端字节按原样从 socket.stream 出来', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    final got = <int>[];
    socket.stream.listen(got.addAll);

    conn.feed([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);

    // 只断言内容：got 是 List<int>，元素运行时类型在这里被丢掉了。
    // 类型由下一条用例专门守着。
    expect(got, [1, 2, 3]);
  });

  test('stream 的运行时元素类型必须是 Uint8List', () async {
    // SSHTransport 内部按 Uint8List 消费，若透传出 List<int> 会在运行时
    // 抛类型错误。这正是计划 1 记录过的协变陷阱的同一形态。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    Object? seen;
    socket.stream.listen((d) => seen = d);

    conn.feed([9]);
    await Future<void>.delayed(Duration.zero);

    // 必须断言"值本身是 Uint8List"，不能写 expect(d.runtimeType, Uint8List)：
    // Uint8List 的 runtimeType 与类型字面量并不 ==（实测 false），失败信息
    // 还是 "Expected: Uint8List, Actual: Uint8List"，极具误导性。
    expect(seen, isA<Uint8List>());
  });

  test('写进 sink 的字节落到 Connection.write', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    socket.sink.add([65, 66]);
    await Future<void>.delayed(Duration.zero);

    expect(conn.written, [65, 66]);
  });

  test('写出去后立刻 close()，字节仍须先落到 Connection（丢了就是优雅关闭被掐断）', () async {
    // 这条守的是 _sink 的同步性。若用默认的异步 controller，sink.add 要等
    // 一个 microtask 才调用 write，而 close() 的关闭标记是**同步**置上的 ——
    // 于是这一批字节被底层连接静默丢弃。
    //
    // 实测（真 sshd + 真 SSHClient，见 spec §13.18）：client.close() 在同一个
    // 同步块里先往 sink 写 CHANNEL_EOF / CHANNEL_CLOSE 再关闭传输层，异步
    // controller 下这两个报文全部丢失 —— TCP 连接照常关闭（socket FIN 会发），
    // 丢的是 SSH 协议层的优雅关闭。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    socket.sink.add([65]);
    unawaited(socket.close()); // 与上一行同一个同步块，中间不让出 microtask

    await Future<void>.delayed(Duration.zero);

    expect(
      conn.writeAfterClose,
      isEmpty,
      reason: 'close 之后才落到的写入会被真实连接静默丢弃',
    );
    expect(conn.written, [65]);
  });

  test('close() 关闭底层 Connection，并让 done 完成', () async {
    // SSHTransport.close() 走的正是这条 await socket.close() 路径，所以它必须
    // 真的把连接关掉 —— 否则 §5.4 的"断开"只停在界面上。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    await socket.close();

    expect(conn.closed, isTrue, reason: 'close() 必须真的关掉底层连接');
    await expectLater(socket.done, completes);
  });

  test('sink.close() 关闭底层 Connection（onDone 这条兜底路径）', () async {
    // dartssh2 目前从不调用 sink.close()，但 close() 是 StreamSink 契约里的
    // 合法操作。这条兜底若无声腐烂，第一个这么用的调用方会拿到一个关不掉的
    // 连接 —— 而它自己不会知道。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    await socket.sink.close();
    await Future<void>.delayed(Duration.zero);

    expect(conn.closed, isTrue);
  });

  test('destroy() 关闭底层 Connection', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    socket.destroy();
    await Future<void>.delayed(Duration.zero);

    expect(conn.closed, isTrue);
  });

  test('flush() 透传给底层 Connection', () async {
    // Connection.write 不保证立即发出，flush() 才是那个保证。适配器自己
    // 多了一层 sink，若不透传，"flush 过了"就成了一句空话。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    await socket.flush();

    expect(conn.flushCalls, 1);
  });

  test('对端结束传输时 socket.done 完成', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    var done = false;
    unawaited(socket.done.then((_) => done = true));

    await conn.feedDone();
    await Future<void>.delayed(Duration.zero);

    expect(done, isTrue);
  });

  test('对端报错时 socket.done 以错误完成（而非静默完成）', () async {
    // 静默完成会让上层把"连接被重置"看成一次正常结束，
    // FR-C-06 的可读原因就没了来源。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    Object? caught;
    unawaited(socket.done.catchError((Object e) {
      caught = e;
    }));

    conn.feedError(const SocketException('连接被重置'));
    await Future<void>.delayed(Duration.zero);

    expect(caught, isA<SocketException>());
  });

  test('dispose() 释放订阅：之后不再交付对端数据', () async {
    // dispose() 存在的全部意义就是摘掉订阅。摘不掉 = 旧会话的输出会继续
    // 流进已经换代的界面（计划 2 开头那个"输出区永久静止 / 按钮是绿的"
    // 就是这一族的故障）。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    final got = <int>[];
    socket.stream.listen(got.addAll);

    socket.dispose();
    conn.feed([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);

    expect(got, isEmpty);
  });

  test('dispose() 不关闭底层 Connection（关闭是 close()/destroy() 的职责）', () async {
    // Connection 是**借来的**，生命周期归调用方。Task 4 的 SshSession.close()
    // 正是先 client.close() 再 dispose()。若 dispose() 顺手关了连接，那个
    // 顺序就变成"先关两次"，而顺序反过来的调用方会拿到一个已死的连接。
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    socket.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(conn.closed, isFalse, reason: 'dispose() 只释放订阅，连接由调用方关闭');
  });
}
```

> 上面的 import 已含 `dart:io`（最后一条用例要用 `SocketException` 验证"错误不被静默吞掉"）。

- [ ] **Step 3: 运行测试确认失败**

Run: `flutter test test/connection/connection_socket_test.dart`
Expected: 编译失败，**0 个用例被执行**。`flutter test` 走的是 CFE 而不是解析器，实际措辞是 `Error when reading '<文件>': No such file or directory` 加一串 `Type '...' not found`，**不是** `Target of URI doesn't exist`（后者是 `dart analyze` 的用词）。判据是"编译没过、一个用例都没跑"，不是那句话本身。

- [ ] **Step 4: 实现**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'connector.dart';

/// 把本项目的 [Connection] 适配成 dartssh2 需要的 [SSHSocket]。
///
/// 存在的理由：`SSHClient` 只接受 `SSHSocket`，而本项目的传输抽象是
/// [Connection]。有了这层适配，SSH 就能建在**任意** [Connection] 之上 ——
/// 直连可以，跳板机隧道也可以（计划 3 正是靠它把第 N+1 跳建在第 N 跳上，
/// 且不必改动 SshSession）。
///
/// 契约上有两处需要调用方知道：`dispose()` **不**关闭底层 [Connection]；
/// `done` 的完成依赖对端真的结束 [Connection.input]。
class ConnectionSocket implements SSHSocket {
  ConnectionSocket(this._conn) {
    // SSHTransport 会**同时**监听 stream 与 done，而 Connection.input 是
    // 单订阅流：桥接必须只做一次。若在这里按需 listen 两次，第二次会抛
    // "Stream has already been listened to"。
    _sub = _conn.input.listen(
      (data) =>
          _stream.add(data is Uint8List ? data : Uint8List.fromList(data)),
      onError: (Object e, StackTrace st) {
        _stream.addError(e, st);
        if (!_done.isCompleted) _done.completeError(e, st);
      },
      onDone: () {
        unawaited(_stream.close());
        if (!_done.isCompleted) _done.complete();
      },
    );
    _sinkSub = _sink.stream.listen(
      _conn.write,
      // Connection.write 是同步的 void，身上没有错误通道；写出失败的唯一
      // 上报口是 done。所以这条 onError 目前不可达 —— 留着只为满足
      // StreamSink 的契约形态，别指望它兜住写入失败。
      onError: (Object _) {},
      // dartssh2 从不调用 sink.close()（只 sink.add），所以这条在计划 2 里
      // 也不可达。dispose() 里 _sinkSub.cancel() 排在 _sink.close() 之前，
      // 正是为了不走到这里 —— 否则 dispose() 会顺手把连接关掉。
      onDone: () => unawaited(_conn.close()),
    );
  }

  final Connection _conn;
  final _stream = StreamController<Uint8List>();

  /// `sync: true` **不能省**。默认的异步 controller 会把 `sink.add` 推迟一个
  /// microtask 才调用 [_conn.write]，而 `Connection.close()` 的关闭标记是
  /// **同步**置上的：同一个同步块里"写出去 + close()"的字节会被底层连接
  /// 静默丢弃，一个错误都不报。
  ///
  /// 实测（真 sshd + 真 SSHClient，见 spec §13.18）：`client.close()` 先在
  /// 同一同步块里往 sink 写 `CHANNEL_EOF` / `CHANNEL_CLOSE`，再关传输层 ——
  /// 异步 controller 下这两个报文全部丢掉，设备侧看到的是连接被粗暴掐断
  /// 而非优雅断开。裸 socket 不会这样，所以这层适配器把一个原本正确的
  /// 行为改坏了。
  ///
  /// 代价（实测，勿凭直觉改写，见 spec §13.18-1）：[_conn.write] 若同步抛错，
  /// **不会**从 `sink.add` 里抛出来 —— 实测 `try { sink.add(...) } catch` 什么
  /// 都捕不到，错误经 `_BufferingStreamSubscription._sendData` →
  /// `_RootZone.runUnaryGuarded` 仍然变成未捕获的 zone 错误，**落点与异步
  /// controller 完全相同**，只是上报时机从下一个 microtask 提前到同步。
  ///
  /// 另：`dispose()` 之后再 `sink.add` 会抛 `Bad state: Cannot add event after
  /// closing`，但这条不是 `sync: true` 带来的 —— 异步 controller 抛的是一模
  /// 一样的错误。
  final _sink = StreamController<List<int>>(sync: true);
  final _done = Completer<void>();
  late final StreamSubscription<List<int>> _sub;
  late final StreamSubscription<void> _sinkSub;

  @override
  Stream<Uint8List> get stream => _stream.stream;

  @override
  StreamSink<List<int>> get sink => _sink.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() => _conn.close();

  @override
  void destroy() => unawaited(_conn.close());

  @override
  Future<void> flush() => _conn.flush();

  /// 释放两个订阅。**不 await 两个 controller 的 close()** ——
  /// 单订阅 controller 的 close() Future 要等到有监听者取走 done 才完成，
  /// 无人监听时永久挂起（spec §13.11）。本方法返回 void 也正是这个缘故：
  /// void 让"await 一个可能永不完成的 future"根本写不出来。
  ///
  /// **不关闭 [Connection]** —— 连接是借来的，由调用方用 `close()` /
  /// `destroy()` 释放。计划 2 的 `SshSession.close()` 就是先 `client.close()`
  /// 再 `dispose()`。
  void dispose() {
    unawaited(_sub.cancel());
    unawaited(_sinkSub.cancel());
    unawaited(_sink.close());
    unawaited(_stream.close());
  }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `flutter test test/connection/connection_socket_test.dart`
Expected: 12 个用例全部 PASS

- [ ] **Step 6: 分析 + 提交**

```bash
dart analyze lib/connection/connection_socket.dart test/connection/connection_socket_test.dart
git add pubspec.yaml pubspec.lock lib/connection/connection_socket.dart test/connection/connection_socket_test.dart
git commit -m "feat: Connection -> SSHSocket 适配器"
```

---

## Task 2: `KnownHost` 与注入式 `HostKeyStore`

**Files:**
- Create: `lib/connection/known_host.dart`
- Test: `test/connection/known_host_test.dart`

**为什么要按 `keyType` 分别存储：** 同一台主机可以同时提供多把不同算法的主机密钥（`ssh-ed25519`、`rsa-sha2-256`……），每把的指纹都不同。若只按 `host:port` 存一条，那么设备换用另一种算法时会被判成「主机密钥变了」——**一个正常的算法协商会被报成疑似中间人攻击**。用户会因此学会忽略这个警告，而那正是最不该被训练成忽略的警告。

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/known_host.dart';

KnownHost _k({
  String host = '10.0.0.1',
  int port = 22,
  String keyType = 'ssh-ed25519',
  String fingerprint = 'SHA256:abc123',
}) => KnownHost(
  host: host,
  port: port,
  keyType: keyType,
  fingerprint: fingerprint,
);

void main() {
  test('往返 JSON 一致', () {
    final k = _k();

    final back = KnownHost.fromJson(k.toJson());

    expect(back.host, '10.0.0.1');
    expect(back.port, 22);
    expect(back.keyType, 'ssh-ed25519');
    expect(back.fingerprint, 'SHA256:abc123');
  });

  test('toJson 的键名是持久化格式，不得随手改名', () {
    // 计划 4 会把这些键写进磁盘。改名**在运行时不报错**（红的是本测试，
    // 这是刻意设计的），但已存的文件会读不出来 ——
    // 于是每台设备都被当成"首次连接"，FR-C-11 的确认形同虚设，而且**已经
    // 变过密钥的主机也会被重新 TOFU 接受**。所以钉死键名，而不只是钉住往返。
    expect(_k().toJson(), {
      'host': '10.0.0.1',
      'port': 22,
      'keyType': 'ssh-ed25519',
      'fingerprint': 'SHA256:abc123',
    });
  });

  test('identity 由 host/port/keyType 三者共同决定', () {
    // **三个轴必须逐个断言。** 只比 keyType 的话，测试名宣称覆盖了三者，
    // 而 host / port 两轴其实毫无保护：把 host 从 identity 里删掉，本测试
    // 照样绿，只有仓库那几条用例会红；而仓库的注释又写着"必须与
    // KnownHost.identity 逐字一致"，于是最自然的修法是把 _key 也照改 ——
    // 两边一起错，12 条全绿，仓库开始把两台设备混成一条记录。
    // 实测后果：存过 10.0.0.2 之后再连 10.0.0.1，会拿到 10.0.0.2 的指纹，
    // 比对失败 → 一台从未换过密钥的设备被报成"主机密钥变更"。
    // 断言的是**结构**（三个轴各自可区分），不是格式字符串。
    expect(_k(host: 'h1').identity, isNot(_k(host: 'h2').identity));
    expect(_k(port: 22).identity, isNot(_k(port: 2222).identity));
    expect(
      _k(keyType: 'ssh-ed25519').identity,
      isNot(_k(keyType: 'ssh-rsa').identity),
    );
  });

  test('同一主机同一算法重新保存会覆盖（identity 相同）', () {
    final a = _k(host: 'h', keyType: 'ssh-ed25519', fingerprint: 'SHA256:old');
    final b = _k(host: 'h', keyType: 'ssh-ed25519', fingerprint: 'SHA256:new');

    expect(a.identity, b.identity);
  });

  test('指纹为空串时拒绝构造', () {
    // 空指纹会让"指纹不匹配"永远为真，从而把对该主机 + 算法的每一次连接
    // 都判成主机密钥变更 —— 必须在这里挡住，而不是让它在比较时才发作。
    expect(() => _k(fingerprint: ''), throwsArgumentError);
  });

  test('算法名含冒号时拒绝构造（否则两组三元组会拼出同一个键）', () {
    // identity 是 '$host:$port:$keyType'，冒号是分隔符。算法名里再出现冒号，
    // 分隔就失去意义：实测 {host:'h:22', port:1, keyType:'2'} 与
    // {host:'h', port:22, keyType:'1:2'} 都拼成 'h:22:1:2'，两条记录塌成
    // 一条，find(h:22, 1, 2) 会返回另一台设备的指纹 → 又一类
    // "主机密钥变更"误报。dartssh2 的七个算法名都不含冒号，所以这条只在
    // 手改/损坏的文件里触发 —— 而 fromJson 正是一条不可信输入路径，
    // 与指纹那条守卫同一个理由。
    expect(() => _k(keyType: 'a:b'), throwsArgumentError);
  });

  test('从 JSON 进来也走同一道校验（spec §13.3 的 catch 宽度就建立在这上面）', () {
    // 计划 4 逐条目 try/catch 的宽度，来自这条实测结论：手改出来的空指纹
    // 抛的是 ArgumentError，而不是 §13.3 正文点名的 TypeError。若哪天校验
    // 搬了家或换了异常类型，§13.3 给计划 4 定的契约会**悄悄**失效 ——
    // 一个字都不会报错，只是某天一条坏记录掀掉整个文件。所以钉在这里。
    expect(
      () => KnownHost.fromJson({
        'host': '10.0.0.1',
        'port': 22,
        'keyType': 'ssh-ed25519',
        'fingerprint': '',
      }),
      throwsArgumentError,
    );
  });

  test('空仓库里 find 返回 null', () async {
    final store = InMemoryHostKeyStore();

    expect(await store.find('10.0.0.1', 22, 'ssh-ed25519'), isNull);
  });

  test('save 之后 find 能取回同一条（identity 与 find 的键必须一致）', () async {
    // 这条守的是一个**跨类不变式**：KnownHost.identity 拼出的键，
    // 必须和 InMemoryHostKeyStore.find 自己拼的键一模一样。两边一旦各改各的，
    // find 会永远返回 null —— 于是每次连接都被当成"首次连接"，不仅反复弹
    // 确认，更糟的是**已经变过密钥的主机也会被重新接受**。
    final store = InMemoryHostKeyStore();
    final k = _k();

    await store.save(k);

    final got = await store.find(k.host, k.port, k.keyType);
    expect(got, isNotNull);
    expect(got!.fingerprint, 'SHA256:abc123');
  });

  test('同一 identity 再次 save 是覆盖，不是追加', () async {
    final store = InMemoryHostKeyStore();

    await store.save(_k(fingerprint: 'SHA256:old'));
    await store.save(_k(fingerprint: 'SHA256:new'));

    expect(store.all, hasLength(1));
    expect((await store.find('10.0.0.1', 22, 'ssh-ed25519'))!.fingerprint,
        'SHA256:new');
  });

  test('同一主机不同算法各自成条，互不覆盖', () async {
    // 这正是按 keyType 分别存储的理由（见 spec §13.5）：只按 host:port 存的话，
    // 设备换一种算法协商就会被判成"主机密钥变了" ——
    // 一个正常的算法协商被报成疑似中间人攻击。
    final store = InMemoryHostKeyStore();

    await store.save(_k(keyType: 'ssh-ed25519', fingerprint: 'SHA256:x'));
    await store.save(_k(keyType: 'rsa-sha2-256', fingerprint: 'SHA256:y'));

    expect(store.all, hasLength(2));
    expect((await store.find('10.0.0.1', 22, 'rsa-sha2-256'))!.fingerprint,
        'SHA256:y');
  });

  test('all 是不可变快照，改不动仓库', () async {
    final store = InMemoryHostKeyStore();
    await store.save(_k());

    expect(() => store.all.add(_k(host: 'other')), throwsUnsupportedError);
    expect(store.all, hasLength(1));
  });

  test('remove 之后 find 回到 null（设备换过密钥后的唯一出路）', () async {
    // 计划 3 的错误文案要求用户"在设置中清除该主机的记录后重连"。
    // 接口若没有 remove，那句话就是在教用户做一件做不到的事 ——
    // 指纹一旦变化，这台设备会被**永久**拒绝，而且无处可清。
    final store = InMemoryHostKeyStore();
    await store.save(_k());

    await store.remove('10.0.0.1', 22, 'ssh-ed25519');

    expect(await store.find('10.0.0.1', 22, 'ssh-ed25519'), isNull);
    expect(store.all, isEmpty);
  });

  test('remove 只删指定算法，同一主机的其他算法不受影响', () async {
    // 与 save/find 同一条理由：删也必须精确到一把密钥。否则"清掉换过的那把"
    // 会顺手删掉同主机另一种算法的记录，用户下次连接会被重新问一遍。
    final store = InMemoryHostKeyStore();
    await store.save(_k(keyType: 'ssh-ed25519', fingerprint: 'SHA256:x'));
    await store.save(_k(keyType: 'rsa-sha2-256', fingerprint: 'SHA256:y'));

    await store.remove('10.0.0.1', 22, 'ssh-ed25519');

    expect((await store.find('10.0.0.1', 22, 'rsa-sha2-256'))!.fingerprint,
        'SHA256:y');
    expect(store.all, hasLength(1));
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/connection/known_host_test.dart`
Expected: 编译失败，**0 个用例被执行**（`flutter test` 走 CFE，措辞见 Task 1 Step 3：`Error when reading ...: No such file or directory` 加一串 `Type 'KnownHost' not found`，**不是** `Target of URI doesn't exist`）

- [ ] **Step 3: 实现**

```dart
/// 一条已确认的主机密钥记录（TOFU，首次使用即信任）。
///
/// 持久化由调用方负责 —— 计划 2 只定义模型，写盘留给计划 4 的 store，
/// 中间通过 [HostKeyStore] 接口注入（spec §13.5）。
class KnownHost {
  KnownHost({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  }) {
    if (fingerprint.isEmpty) {
      throw ArgumentError.value(
        fingerprint,
        'fingerprint',
        '指纹不能为空：空指纹会让"不匹配"恒为真，把每次连接都判成密钥变更',
      );
    }
    if (keyType.contains(':')) {
      throw ArgumentError.value(
        keyType,
        'keyType',
        '算法名不能含冒号：identity 用冒号拼接，含冒号的算法名会和另一组 '
            '(host, port, keyType) 拼出同一个键，两条记录塌成一条',
      );
    }
  }

  final String host;
  final int port;

  /// 主机密钥算法名，如 `ssh-ed25519` / `rsa-sha2-256`。
  final String keyType;

  /// 形如 `SHA256:<base64>`，dartssh2 直接给出，无需自己算。
  final String fingerprint;

  /// 记录的唯一标识。**必须包含 keyType** —— 同一主机同时提供多种算法时，
  /// 每把密钥的指纹都不同，只按 host:port 存会把正常的算法协商误报成
  /// 主机密钥变更（见 spec §13.5）。
  ///
  /// 前提：`keyType` 不含冒号（构造函数强制）。dartssh2 的算法名
  /// （`ssh-ed25519`、`rsa-sha2-256` 等七个）都不含，所以这个拼法无歧义 ——
  /// IPv6 字面量主机（`::1`）也安全，因为 `port` 一定是纯数字段。
  /// 含冒号的算法名会让两组三元组拼出同一个键，构造函数直接拒绝。
  String get identity => '$host:$port:$keyType';

  factory KnownHost.fromJson(Map<String, Object?> json) => KnownHost(
        host: json['host']! as String,
        port: json['port']! as int,
        keyType: json['keyType']! as String,
        fingerprint: json['fingerprint']! as String,
      );

  Map<String, Object?> toJson() => {
        'host': host,
        'port': port,
        'keyType': keyType,
        'fingerprint': fingerprint,
      };
}

/// 已知主机密钥的存储。**由外部注入**，计划 2 不提供文件实现。
///
/// spec §13.5：FR-C-11 要求"确认后保存"，但持久化边界属于计划 4。
/// 若计划 2 自己写文件，持久化就会漏成两处。
abstract class HostKeyStore {
  /// 查这条记录；没有则返回 null。
  Future<KnownHost?> find(String host, int port, String keyType);

  /// 保存（同一 [KnownHost.identity] 视为覆盖）。
  Future<void> save(KnownHost host);

  /// 删除这一条记录。
  ///
  /// **不是可选项。** 设备确实更换过主机密钥时，[find] 会一直返回旧指纹，
  /// 于是这台设备被**永久**拒绝连接；计划 3 的错误文案正是让用户
  /// "在设置中清除该主机的记录后重连"。接口少了这个方法，那句话就是在
  /// 教用户做一件做不到的事 —— 而"主机密钥变了"恰恰是唯一一个
  /// 用户绝不能学会忽略的警告。
  Future<void> remove(String host, int port, String keyType);
}

/// 内存实现，供测试与"不持久化"的场景使用。
class InMemoryHostKeyStore implements HostKeyStore {
  final _byIdentity = <String, KnownHost>{};

  /// 已保存记录的快照，供断言。
  List<KnownHost> get all => List.unmodifiable(_byIdentity.values);

  /// 仓库自己的查键。**必须与 [KnownHost.identity] 逐字一致** —— 两边各改
  /// 各的会让 [find] / [remove] 永远找不到记录，于是每次连接都被当成
  /// "首次连接"，已经变过密钥的主机也会被重新 TOFU 接受。测试里有一条
  /// 专门守这个跨类不变式。
  String _key(String host, int port, String keyType) => '$host:$port:$keyType';

  @override
  Future<KnownHost?> find(String host, int port, String keyType) async =>
      _byIdentity[_key(host, port, keyType)];

  @override
  Future<void> remove(String host, int port, String keyType) async {
    _byIdentity.remove(_key(host, port, keyType));
  }

  @override
  Future<void> save(KnownHost host) async {
    _byIdentity[host.identity] = host;
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/connection/known_host_test.dart`
Expected: 14 个用例全部 PASS

- [ ] **Step 5: 提交**

```bash
dart analyze lib/connection/known_host.dart test/connection/known_host_test.dart
git add lib/connection/known_host.dart test/connection/known_host_test.dart
git commit -m "feat: KnownHost 模型与注入式 HostKeyStore 接口"
```

---

## Task 3: `ConnectionFailure` —— FR-C-06 的可读失败原因

**Files:**
- Create: `lib/connection/connection_failure.dart`
- Test: `test/connection/connection_failure_test.dart`

**本 Task 的核心（spec §13.15）：** 主机密钥被拒与算法协商失败，抛出的异常**类型和 `toString` 完全一样**，只有 `.reason` 不同。分类逻辑若看类型或消息，两者会被归成一类 —— 而 §10.2 已决定 V1 不支持旧算法，于是**老设备连不上时用户会看到「认证失败」**，然后去反复检查一个根本没问题的口令。

- [ ] **Step 1: 写失败测试**

```dart
import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_failure.dart';

void main() {
  group('FR-C-06 的五种原因', () {
    test('连接超时（TimeoutException 形态）', () {
      final f = classifyConnectionFailure(
        TimeoutException('timed out'),
      );
      expect(f.kind, ConnectionFailureKind.timeout);
    });

    test('Socket.connect 到点（errno 110）→ timeout，不是 unreachable', () {
      // **这条才是 FR-C-13 的真身。** `Socket.connect(timeout:)` 到点后抛的是
      // SocketException（errno ETIMEDOUT = 110），**不是** TimeoutException ——
      // 实测过（连 192.0.2.1:22，黑洞地址）。上面那条 TimeoutException 用例
      // 喂的是生产路径不会抛的形态，它绿着的时候这一整条路径是错的：
      // 15s 超时被归成"主机不可达"，还把英文原文当中文说明交给用户。
      final f = classifyConnectionFailure(
        const SocketException(
          'Connection timed out',
          osError: OSError('Connection timed out', 110),
        ),
      );

      expect(f.kind, ConnectionFailureKind.timeout);
      expect(f.message, contains('超时'));
      expect(f.message, isNot(contains('timed out')));
    });

    test('Windows 的 WSAETIMEDOUT（10060）同样归 timeout', () {
      // 同一个错误的另一个 errno。只认 110 的话，本程序的主要目标平台
      // （Windows）上这条路又退回"主机不可达"。
      final f = classifyConnectionFailure(
        const SocketException(
          'Connection timed out',
          osError: OSError('Connection timed out', 10060),
        ),
      );

      expect(f.kind, ConnectionFailureKind.timeout);
    });

    test('主机不可达（SocketException，拒绝连接）', () {
      final f = classifyConnectionFailure(
        const SocketException('Connection refused'),
      );
      expect(f.kind, ConnectionFailureKind.unreachable);
    });

    test('不可达的文案保留操作系统给的原文', () {
      // 不能只断言 kind：把 `error.osError?.message` 换成 `error.message`，
      // 用户就失去了"是 DNS 解析不了、还是端口没人听"这唯一的自查线索。
      // 这里故意让两个 message 不同，好让断言只可能来自 osError。
      final f = classifyConnectionFailure(
        const SocketException(
          'SocketException: 拒绝连接',
          osError: OSError('Connection refused', 111),
        ),
      );

      expect(f.kind, ConnectionFailureKind.unreachable);
      expect(f.message, contains('Connection refused'));
    });

    test('认证失败（所有认证方式都试过了）', () {
      final f = classifyConnectionFailure(SSHAuthFailError('all failed'));
      expect(f.kind, ConnectionFailureKind.authFailed);
    });

    test('带口令的私钥 → 指向"去掉口令"，不要说成协议错误', () {
      // **这条只覆盖带口令的 OPENSSH 私钥**（`-----BEGIN OPENSSH PRIVATE
      // KEY-----`），实测里唯一抛 `SSHKeyDecryptError` 的形态。这里原先写的是
      // "任何设了口令的私钥都必然失败" —— 错的：带口令的 **PKCS#1**
      // （`Proc-Type: 4,ENCRYPTED`）抛的是 `ArgumentError`，本文件里没有
      // 哪一支接得住它，最终落在 `unknown`（见 spec §13.19-9）。
      //
      // 少了这个分支，它会掉进 `is SSHError` 兜底，变成
      // 「协议错误：SSHKeyDecryptError(Private key is encrypted, null)」
      // —— 一个英文类名加一个字面 null，方向还指到了协议上。
      final f = classifyConnectionFailure(
        SSHKeyDecryptError('Private key is encrypted', null),
      );

      expect(f.kind, ConnectionFailureKind.authFailed);
      expect(f.message, contains('私钥'));
      expect(f.message, contains('口令'));
      expect(f.message, isNot(contains('协议错误')));
      expect(f.message, isNot(contains('null')));
    });

    test('读不出私钥但不是口令问题 → 不能提口令', () {
      // 实测输入：`-----BEGIN RSA PRIVATE KEY-----\n\n-----END RSA PRIVATE KEY-----`
      // 抛 `SSHKeyDecodeError('Failed to decode private key')`。
      // **两种私钥错误必须分开。** 合成一支的话，一个私钥文件损坏的用户会被
      // 叫去"去掉口令"，而他的私钥根本没有口令 —— 与 §13.15 同一个
      // "把人指向错误方向"的坑，只是轻一些。`SSHKeyDecryptError` 是
      // `SSHKeyDecodeError` 的子类，所以顺序上必须先判子类。
      final f = classifyConnectionFailure(
        SSHKeyDecodeError('Failed to decode private key'),
      );

      expect(f.kind, ConnectionFailureKind.authFailed);
      expect(f.message, contains('私钥'));
      expect(f.message, contains('Failed to decode private key'));
      expect(f.message, isNot(contains('口令')));
      expect(f.message, isNot(contains('null')));
    });

    test('协议错误（握手失败）', () {
      final f = classifyConnectionFailure(
        SSHHandshakeError('Invalid version: HTTP/1.1 200 OK'),
      );
      expect(f.kind, ConnectionFailureKind.protocolError);
      // 同上：握手失败时，对端到底回了一句什么，是唯一能自查的东西。
      expect(f.message, contains('Invalid version'));
    });

    test('跳板机失败会指明是第几跳', () {
      final f = classifyConnectionFailure(
        const SocketException('Connection refused'),
        hop: const JumpHop(index: 1, name: '堡垒机-A'),
      );
      expect(f.kind, ConnectionFailureKind.jumpHostFailed);
      expect(f.message, contains('第 1 跳'));
      expect(f.message, contains('堡垒机-A'));
      // **内层原因必须还在。** 少了这一条，把 message 换成
      // `'第 ${hop.index} 跳 ${hop.name} 失败'`（丢掉 `：${inner.message}`）
      // 会让 26 条用例**全绿**（实测过）—— 用户只看到"第 1 跳 X 失败"，
      // 而不知道 X 到底为什么没连上，FR-J-05 要的正是这个原因。
      expect(f.message, contains('主机不可达'));
    });
  });

  group('§13.15：必须区分主机密钥与算法协商', () {
    test('主机密钥被用户拒绝 → hostKey', () {
      final f = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHHostkeyError('Hostkey verification failed'),
        ),
      );
      expect(f.kind, ConnectionFailureKind.hostKey);
    });

    test('算法协商失败 → protocolError，而不是 authFailed', () {
      // 这是 §10.2「V1 不支持旧算法」这个决定的实际表现形态。
      final f = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHInternalError(StateError('No matching key exchange algorithm')),
        ),
      );
      expect(f.kind, ConnectionFailureKind.protocolError);
      expect(f.kind, isNot(ConnectionFailureKind.authFailed));
    });

    test('两者必须分类不同 —— 这是本 Task 的回归测试', () {
      final hostkey = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHHostkeyError('Hostkey verification failed'),
        ),
      );
      final algo = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHInternalError(StateError('No matching key exchange algorithm')),
        ),
      );

      // 两者的异常类型与 toString 完全相同，唯一区别在 .reason。
      expect(hostkey.kind, isNot(algo.kind));
    });

    test('认不出的 reason 优雅降级为 protocolError 并附上原文', () {
      // **输入必须是真正认不出的 reason。** 这里原先是
      // `SSHInternalError(StateError('something new'))` —— 那是一个**认得出**的
      // reason，走的是上面那条 SSHInternalError 分支，根本碰不到兜底。于是
      // 把兜底改成 `throw` 之后这条测试照样绿（实测过），而兜底恰恰是本 Task
      // 点名要求的那条「优雅降级」。用一个非 hostkey、非 internal 的 SSHError
      // 才能真正走到兜底。
      final f = classifyConnectionFailure(
        SSHAuthAbortError('boom', SSHAuthFailError('weird')),
      );
      expect(f.kind, ConnectionFailureKind.protocolError);
      expect(f.message, contains('weird'));
    });

    test('reason 为 null 时同样降级，并附上 abort 自己的消息', () {
      final f = classifyConnectionFailure(SSHAuthAbortError('boom'));

      expect(f.kind, ConnectionFailureKind.protocolError);
      expect(f.message, contains('boom'));
    });
  });

  group('SSHSocketError 必须拆开按内层分类', () {
    test('拒绝连接 → unreachable，超时 → timeout（不拆开就分不出这两者）', () {
      // 守的是 `_classify` 里 `if (error is SSHSocketError) return
      // _classify(error.error);` 那一支。它此前零覆盖 —— 把它改成 `throw`，
      // 当时全文件 12 条用例照样全绿（实测过）。而这正是那句注释所声称的作用。
      expect(
        classifyConnectionFailure(
          SSHSocketError(const SocketException('Connection refused')),
        ).kind,
        ConnectionFailureKind.unreachable,
      );
      expect(
        classifyConnectionFailure(SSHSocketError(TimeoutException('timed out')))
            .kind,
        ConnectionFailureKind.timeout,
      );
    });

    test('内层已经是 ConnectionFailure 时，不再被包成 unknown', () {
      // 这一次递归不经过 `classifyConnectionFailure` 顶部的幂等判断，所以
      // `_classify` 顶部必须**自己再判一次**。少了那一行，内层会掉进
      // `unknown`，用户看到的是
      // 「连接失败：ConnectionFailure(authFailed): 无法读取私钥文件：路径不存在」
      // —— 双层面具，第一层还是英文。
      //
      // 这个形状今天在 `DirectConnector` 里够不到（它只抛
      // `SocketException`），但计划 3 的隧道/跳板机连接器完全可能产出它。
      const inner = ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法读取私钥文件：路径不存在',
      );

      final f = classifyConnectionFailure(SSHSocketError(inner));

      // 注意不能断言 `same(inner)`：`classifyConnectionFailure` 末尾会按
      // `inner.kind` / `inner.message` 重造一个，好把 **SSHSocketError 本身**
      // 记进 `cause`。要对的是面具有没有被摘掉。
      expect(f.kind, ConnectionFailureKind.authFailed);
      expect(f.message, '无法读取私钥文件：路径不存在');
      expect(f.message, isNot(contains('连接失败：')));
    });
  });

  group('message 必须非空、不漏 null，且带原始信息', () {
    test('每个 kind 的 message 都非空、且不含字面 null', () {
      // **必须覆盖全部七个 kind。** 这条此前只喂了 4 个输入，于是
      // hostKey / protocolError / jumpHostFailed 三类的文案零覆盖 ——
      // 把它们的 message 整个换成 'null' 也照样全绿。
      //
      // 注意这条**不能**叫"都是可读中文"：`unknown` 那一格按设计就是
      // 原始异常的 `$error`（英文、带 Dart 类名）。对一个没预料到的异常，
      // 细节编不出来，套一句中文也仍然要附原文，所以钉的是
      // "非空、不漏 null"，不是"每条都通顺" —— 见 `message` 的文档。
      final cases = <String, ConnectionFailure>{
        'timeout（Socket.connect 到点）': classifyConnectionFailure(
          const SocketException(
            'Connection timed out',
            osError: OSError('Connection timed out', 110),
          ),
        ),
        'authFailed': classifyConnectionFailure(SSHAuthFailError('a')),
        'hostKey': classifyConnectionFailure(
          SSHAuthAbortError(
            'Connection closed before authentication',
            SSHHostkeyError('Hostkey verification failed'),
          ),
        ),
        'unreachable': classifyConnectionFailure(
          const SocketException(
            'r',
            osError: OSError('Connection refused', 111),
          ),
        ),
        'protocolError': classifyConnectionFailure(SSHHandshakeError('h')),
        'jumpHostFailed': classifyConnectionFailure(
          const SocketException('r'),
          hop: const JumpHop(index: 1, name: '堡垒机-A'),
        ),
        'unknown': classifyConnectionFailure(ArgumentError('unexpected')),
      };

      // 七个 kind 一个都不能少 —— 少一个就说明这份清单又落后于枚举了。
      expect(
        cases.values.map((f) => f.kind).toSet(),
        ConnectionFailureKind.values.toSet(),
      );

      for (final entry in cases.entries) {
        expect(entry.value.message, isNotEmpty, reason: entry.key);
        expect(entry.value.message, isNot(contains('null')), reason: entry.key);
      }
    });

    test('cause 保留原始异常，供日志使用', () {
      final original = const SocketException('Connection refused');
      final f = classifyConnectionFailure(original);

      expect(f.cause, same(original));
    });

    test('非 SSHError 的意外异常不会漏出去', () {
      final f = classifyConnectionFailure(ArgumentError('unexpected'));
      expect(f.kind, ConnectionFailureKind.unknown);
      expect(f.message, isNotEmpty);
      // `unknown` 这一格按设计就是原始异常的 `$error` —— 认不出就不能编，
      // 只能把原文交给用户。把 `'连接失败：$error'` 换成一句没有 $error 的
      // 中文（比如只写 '连接失败'）实测全绿，那样连上报都没得报。
      expect(f.message, contains('unexpected'));
    });
  });

  group('文案必须把人指向正确的地方（§13.15 的理由整个就在文案上）', () {
    // 这个 group 守的**不是 kind，而是文案本身**，因为 FR-C-06 的交付物
    // 就是「在输出区给出可读的失败原因」。
    //
    // 实测过的两个漏洞形态，两者都让本文件全绿：
    //   1. 把主机密钥那条消息换成「认证失败：用户名、口令或私钥不正确」——
    //      kind 仍是 hostKey，当时 14 条用例照绿，而用户去反复检查一个根本
    //      没问题的口令。这正是 §13.15 存在的唯一理由。
    //   2. 把 `is SSHInternalError` 整支删掉 —— 兜底分支返回的 kind 一样，
    //      只有文案退化成「连接在认证完成前中断」，同样全绿。
    // 第 3 条是同一种坑的**镜像**，也实测过：把 authFailed 的文案换成主机密钥
    // 那条，全绿，而用户会跑去核对指纹、甚至怀疑遇到中间人。
    // 所以下面钉的是"文案把人指向哪里"，不是逐字文本。

    test('主机密钥的文案指向指纹，不指向口令', () {
      final f = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHHostkeyError('Hostkey verification failed'),
        ),
      );

      expect(f.message, contains('指纹'));
      // §13.15 那张表里，主机密钥这一格之所以能收尾，全靠最后这句可操作
      // 指引：设备确实换过密钥时用户得知道去哪儿清记录。删掉它实测全绿，
      // 用户就只剩一个"不一致"的死结论。
      expect(f.message, contains('清除'));
      expect(f.message, isNot(contains('口令')));
      expect(f.message, isNot(contains('密码')));
    });

    test('认证失败的文案指向口令/密钥，不指向指纹', () {
      // §13.15 的坑是双向的：把这两条文案对调，用户同样被指向错的方向 ——
      // 一个纯粹的口令问题被说成安全事件。
      final f = classifyConnectionFailure(SSHAuthFailError('all failed'));

      // 钉的是"指向凭据"这个方向，不是一个具体词：文案改写成「用户名或密码
      // 不正确」仍然是对的，不该因此变红（`isNot` 那些才是硬边界）。
      expect(
        f.message,
        anyOf(contains('口令'), contains('密码'), contains('私钥')),
      );
      expect(f.message, isNot(contains('指纹')));
    });

    test('算法协商失败的文案指向算法，同样不指向口令', () {
      // §13.15 表格的第 2 行：老设备只提供 ssh-rsa/SHA-1 等。
      // 它与第 1 行抛出的异常类型和 toString 完全一样。
      final f = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHInternalError(
            StateError('No matching key exchange algorithm'),
          ),
        ),
      );

      expect(f.kind, ConnectionFailureKind.protocolError);
      expect(f.message, contains('算法'));
      // 附原文这件事本身也要钉住：丢掉 `原始信息：${reason.error}` 会让
      // 用户拿不到"到底是哪个算法没协商上"这唯一的可上报细节（实测全绿）。
      expect(f.message, contains('No matching key exchange algorithm'));
      expect(f.message, isNot(contains('口令')));
      expect(f.message, isNot(contains('密码')));
    });

    test('SSHError 兜底归 protocolError，不归 unknown', () {
      // §13.15：catch 以 SSHError 为主，unknown 只留给**非** SSHError 的意外。
      // 删掉 `is SSHError` 那一支，SSHStateError 会掉进 unknown —— 于是
      // 「协议层出错」和「我们没预料到的东西」在报告里再也分不开。
      // SSHStateError 是活会话的终态错误（ssh_client.dart:969），不是假形态。
      final f = classifyConnectionFailure(SSHStateError('SSH connection closed'));

      expect(f.kind, ConnectionFailureKind.protocolError);
      // 同一条规矩：兜底文案也要带原文，否则活会话断开时用户只知道
      // "协议错误"，拿不到 `SSH connection closed` 这个真实原因。
      expect(f.message, contains('SSH connection closed'));
    });
  });

  group('幂等：调用点可以先分好类再抛', () {
    // `SshSession` 读私钥文件时比分类器更清楚上下文 —— 它知道失败发生在
    // "加载私钥"，而分类器只拿到一个裸的 `FileSystemException`，无从判断。
    // 所以允许调用点直接构造 ConnectionFailure 抛出，分类器原样返回。
    test('已经是 ConnectionFailure 的原样返回，不再包一层', () {
      // 少了这一支，那个对象会掉进 unknown，变成
      // 「连接失败：ConnectionFailure(authFailed): 无法读取私钥…」——
      // 用户看到两层面具，而且第一层是英文。
      const original = ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法读取私钥文件：路径不存在',
      );

      final f = classifyConnectionFailure(original);

      expect(f, same(original));
      expect(f.kind, ConnectionFailureKind.authFailed);
      expect(f.message, '无法读取私钥文件：路径不存在');
    });

    test('带 hop 时仍然加"第几跳"前缀（FR-J-05 优先于内层原因）', () {
      const original = ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法读取私钥文件：路径不存在',
      );

      final f = classifyConnectionFailure(
        original,
        hop: const JumpHop(index: 2, name: '堡垒机-B'),
      );

      expect(f.kind, ConnectionFailureKind.jumpHostFailed);
      expect(f.message, contains('第 2 跳'));
      expect(f.message, contains('堡垒机-B'));
      expect(f.message, contains('无法读取私钥文件'));
      // 这一条钉的是"面具没被套上"：万一内层被包成
      // 「连接失败：ConnectionFailure(authFailed): …」再套上跳板机前缀，
      // 用户看到的就是两层英文面具。
      //
      // **但它不是钉住幂等的那条 —— 两种幂等变异下它都照样绿**（实测过）：
      //   · 删 `classifyConnectionFailure` 顶部整块 → 红的是上面那条
      //     `same(original)`。这条用例仍被 `_classify` 的递归守卫兜住，
      //     内层是干净的。
      //   · 删 `_classify` 顶部那一行守卫 → 红的是另一组那条
      //     「内层已经是 ConnectionFailure 时，不再被包成 unknown」，
      //     红在它的 `f.kind` 断言上。这条用例被上面那个前置块拦住了。
      // 两道守卫各自被**别的**用例钉住；这条只钉"跳板机前缀之后内层原因
      // 还在"。别指望它替你抓幂等回归。
      expect(f.message, isNot(contains('连接失败：')));
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/connection/connection_failure_test.dart`
Expected: 编译失败，**0 个用例被执行**（CFE 措辞见 Task 1 Step 3：`Error when reading ...`，不是 `Target of URI doesn't exist`）

- [ ] **Step 3: 实现**

```dart
import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

/// 失败原因分类。FR-C-06 列举的五种原因都在这里（连接超时 / 认证失败 /
/// 主机不可达 / 协议错误 / 跳板机失败），[hostKey] 是 §13.15 额外要求单独
/// 区分出来的第六种，[unknown] 是兜底。
enum ConnectionFailureKind {
  /// 连接超时（FR-C-13，默认 15s）。
  ///
  /// **两个来源都要认。** `Socket.connect(timeout:)` 到点后抛的是
  /// `SocketException`（errno ETIMEDOUT）—— 那才是 FR-C-13 在真实网络上的
  /// 形态；`TimeoutException` 是另一个来源。只认后者的话，最常见的那条
  /// 失败路径会被归成 [unreachable]，还会把英文原文当成中文说明交给用户。
  /// 详见 `_classify` 里 `SocketException` 那一支。
  timeout,

  /// 认证失败：口令或密钥不对，或私钥根本读不出来
  /// （见 `_classify` 的 `SSHKeyDecodeError` 分支）。
  authFailed,

  /// 主机密钥未通过校验：指纹与已知记录不一致，或用户拒绝了首次确认。
  ///
  /// **与 [authFailed] 分开是必须的** —— 用户对这两者的处理完全不同：
  /// 前者要去确认指纹（或警惕中间人），后者才要去查口令。
  hostKey,

  /// 主机不可达：拒绝连接、DNS 解析失败、路由不可达。
  unreachable,

  /// 协议错误：版本协商失败、算法协商失败（含设备只提供已被淘汰的算法）。
  protocolError,

  /// 跳板机失败。message 中会指明是第几跳（FR-J-05）。
  jumpHostFailed,

  /// 未归类的异常。**永远不会把异常吞掉** —— 原始对象在 [ConnectionFailure.cause]。
  unknown,
}

/// 跳板机上下文。用于把失败定位到具体某一跳（FR-J-05）。
///
/// [index] 从 1 开始，与用户看到的「第 1 跳」一致。
class JumpHop {
  const JumpHop({required this.index, required this.name});

  final int index;
  final String name;
}

/// 一次可读的连接失败。
class ConnectionFailure implements Exception {
  const ConnectionFailure(this.kind, this.message, {this.cause});

  final ConnectionFailureKind kind;

  /// 可直接展示给用户的中文说明。
  ///
  /// **例外：[ConnectionFailureKind.unknown]。** 那一种按设计就是原始异常的
  /// `$error`（英文、带 Dart 类名）：对一个没预料到的异常，细节编不出来，
  /// 而 §13.19-1 要求"永远不吞掉异常"。原文同时也留在 [cause] 里。
  final String message;

  /// 原始异常对象。用于日志与排查，不展示给用户。
  final Object? cause;

  @override
  String toString() => 'ConnectionFailure(${kind.name}): $message';
}

/// `ETIMEDOUT` 的 errno。**Linux 是 110，Windows 是 10060（`WSAETIMEDOUT`）。**
///
/// 110 是在本机（Linux）连黑洞地址实测出来的（`Socket.connect(timeout:)` 到点后
/// 抛 `SocketException ... errno = 110`，**不是** `TimeoutException`），并与
/// `/usr/include/asm-generic/errno.h:93` 一致。10060 取自 Winsock 的文档值 ——
/// 本机是 Linux，无法实测；但 Windows 是本程序的主要目标平台，漏掉它恰好会让
/// 那一边的用户看不到「超时」。
///
/// **这个常数不叫 `_etimedoutPosix`，是故意的。** macOS/Darwin 的 `ETIMEDOUT`
/// 是 60（XNU 头文件值，**文档来源，本机无法实测**），叫 POSIX 会让人以为 110
/// 是所有 POSIX 系统的值。macOS 不在 NFR-P-01 的目标平台里（Windows + Linux），
/// 所以这里不认 60 —— 但**别把这条读成"POSIX 通用"**。
const int _etimedoutLinux = 110;
const int _etimedoutWindows = 10060;

/// 超时文案。**只写一份**：`TimeoutException` 与 `SocketException` 的 errno
/// 判定两条路径都要用它，复制两份就会有一天悄悄不一致 —— 同一种失败，
/// 用户看到两种说法。
///
/// 实测（2026-09-24，26 条用例）：拆成两份时，**只有一边的漂移是无声的**。
/// `SocketException` 那一边被「errno 110」那条用例的 `contains('超时')` 钉着，
/// 改它就会红；`TimeoutException` 那一边**没有任何用例断言它的文案**，
/// 改它 26 条全绿。所以这里提成常量不只是防重复，也是把那条**没被钉住**
/// 的路径收进同一个值里 —— 别看到一边有覆盖就以为两边都有。
const String _timeoutMessage = '连接超时：目标设备在超时时间内没有响应';

/// 把任意异常归类成 [ConnectionFailure]。
///
/// **判据是 `SSHAuthAbortError.reason`，不是顶层类型或消息文本** ——
/// 主机密钥被拒与算法协商失败抛出的异常类型与 toString 完全相同
/// （spec §13.15），只有 reason 不同。
ConnectionFailure classifyConnectionFailure(Object error, {JumpHop? hop}) {
  // **幂等。** 调用点可能比分类器更清楚上下文（例如 `SshSession` 读私钥
  // 文件时，它知道失败发生在"加载私钥"，而分类器只拿到一个裸
  // `FileSystemException`，无从判断）。那就允许它直接构造好
  // [ConnectionFailure] 再抛出来，这里原样返回 —— 不再包一层。
  // 少了这一支，那个对象会掉进 `unknown`，变成
  // 「连接失败：ConnectionFailure(authFailed): 无法读取私钥…」，
  // 用户看到两层面具，而且第一层是英文。
  if (error is ConnectionFailure) {
    if (hop == null) return error;
    // 跳板机的失败发生在哪一跳，仍然优先于内层原因（FR-J-05）。
    return ConnectionFailure(
      ConnectionFailureKind.jumpHostFailed,
      '第 ${hop.index} 跳 ${hop.name} 失败：${error.message}',
      cause: error,
    );
  }

  final inner = _classify(error);

  // 跳板机上下文优先：无论内层是什么原因，只要失败发生在某一跳上，
  // 用户首先要看到的是"哪一跳"，其次才是原因（FR-J-05）。
  if (hop != null) {
    return ConnectionFailure(
      ConnectionFailureKind.jumpHostFailed,
      '第 ${hop.index} 跳 ${hop.name} 失败：${inner.message}',
      cause: error,
    );
  }
  return ConnectionFailure(inner.kind, inner.message, cause: error);
}

ConnectionFailure _classify(Object error) {
  // **幂等要在这里再判一次。** 下面 `is SSHSocketError` 那一支会**递归**回
  // 本函数（`_classify(error.error)`），那次递归不经过
  // [classifyConnectionFailure] 顶部的幂等判断。少了这一处，
  // `SSHSocketError(ConnectionFailure(authFailed, …))` 会重新掉进 `unknown`，
  // 得到「连接失败：ConnectionFailure(authFailed): …」—— 正是幂等分支要
  // 避免的双层面具。今天 `DirectConnector` 只抛 `SocketException`，所以还
  // 够不到；但计划 3 的隧道/跳板机连接器就会产出这个形状（实测过）。
  if (error is ConnectionFailure) return error;

  if (error is TimeoutException) {
    // 这一支是**防御性**的，而且比原先写的更"死"。原先这里说 dartssh2 在
    // 握手/认证超时时抛 `SSHHandshakeError('Handshake timed out')` 与
    // `SSHAuthAbortError('Authentication timed out')` —— 但那两条只在 dartssh2
    // **自己设了超时定时器**时才成立，而 `handshakeTimeout` 与 `authTimeout`
    // 的默认值都是 null（ssh_client.dart:299-302），而 V1 的 `lib/` 里**没有
    // 任何一处**给 `SSHClient` 设过它们 —— 这两个名字在 `lib/` 下的命中
    // **无一在代码里**，全部落在这段注释自身（`grep -rn "handshakeTimeout\|authTimeout"`
    // `lib/`）。所以那两条路径今天都到不了。
    //
    // 真正撑起 FR-C-13 的只有下面 `SocketException` 那一支的 errno 判定 ——
    // 别把这一支的绿色读成"超时路径已验证"。
    //
    // **给将来动手的人：** 谁要是给 `SSHClient` 设了 `handshakeTimeout`，超时就会
    // 变成 `SSHHandshakeError('Handshake timed out')`，落进下面
    // `is SSHHandshakeError` 那一支 → 报成 `protocolError`，文案说"对端可能不是
    // SSH 服务" —— 那正是 §13.15 要防的"把超时说成协议问题"。设之前先在这里补一支。
    //
    // `reason` 为 null 的来源有两处：:1126（认证超时，需要上面那个定时器）与
    // :964 配 :321 的 `_handleTransportClosed(null)`（认证前对端干净地关掉 TCP）。
    // **后一种是今天唯一活的。** 两者都落到下面"认不出的 reason"那条兜底。
    return ConnectionFailure(
      ConnectionFailureKind.timeout,
      _timeoutMessage,
      cause: error,
    );
  }

  // 两条顺序纪律都在这个函数里，两条都是"排错了不报错、只静默失效"：
  //   1. 若将来要加 `is SSHAuthError`，它必须排在 `is SSHAuthAbortError` 与
  //      `is SSHAuthFailError` **两者之后**。只说"排在 Abort 之后"是不够的 ——
  //      排在两者**之间**同样会静默吞掉 Fail（它俩是各自独立的类，都
  //      implements SSHAuthError：ssh_errors.dart:40 是 Fail、:49 是 Abort，
  //      别按 40/49 的顺序记）。
  //   2. `is SSHError` 是**兜底**，必须始终排在最后。任何新的
  //      `is <某个 SSHError>` 分支排到它后面就是死代码：编译器不报错，
  //      测试也不会红。下面的 `SSHKeyDecodeError` 分支正是为此特意插在
  //      它前面的。
  if (error is SSHAuthAbortError) {
    final reason = error.reason;

    if (reason is SSHHostkeyError) {
      return ConnectionFailure(
        ConnectionFailureKind.hostKey,
        '主机密钥校验未通过：'
        '这把密钥与已保存的指纹不一致，或你拒绝了本次确认。'
        '若设备确实刚更换过密钥，请在设置中清除该主机的记录后重连。',
        cause: error,
      );
    }
    if (reason is SSHInternalError) {
      // 文案不能断言成因。dartssh2 对这个类的自述是"不该发生的错误，多半是
      // 库自身的缺陷"（ssh_errors.dart:14-15），算法协商失败只是它承载的
      // **其中**一种情况。若一口咬定"与该设备协商加密参数失败"，一个库缺陷
      // 就会被说成设备的算法问题 —— 用户跑去翻设备的 SSH 配置，而那正是
      // §13.15 要避免的"把人指向错误的方向"。所以两种成因并列，并始终附原文。
      return ConnectionFailure(
        ConnectionFailureKind.protocolError,
        '协议错误：SSH 协议层报错。两种常见原因：设备只提供已被淘汰的 SSH '
        '算法（ssh-rsa/SHA-1、aes-cbc、hmac-md5 等，V1 暂不支持），'
        '或本程序/对端实现自身的缺陷。原始信息：${reason.error}',
        cause: error,
      );
    }
    // 认不出的 reason：降级为协议错误，但**附上原文**，不吞掉。
    return ConnectionFailure(
      ConnectionFailureKind.protocolError,
      '协议错误：连接在认证完成前中断。原始信息：'
      '${reason ?? error.message}',
      cause: error,
    );
  }

  if (error is SSHAuthFailError) {
    return ConnectionFailure(
      ConnectionFailureKind.authFailed,
      '认证失败：用户名、口令或私钥不正确',
      cause: error,
    );
  }

  if (error is SSHHandshakeError) {
    return ConnectionFailure(
      ConnectionFailureKind.protocolError,
      '协议错误：SSH 握手失败。对端可能不是 SSH 服务，'
      '或使用了不兼容的版本。原始信息：${error.message}',
      cause: error,
    );
  }

  if (error is SSHSocketError) {
    // 底层 socket 的错误被包了一层，拆开才能区分"拒绝连接"与"超时"。
    return _classify(error.error);
  }

  if (error is SocketException) {
    // **FR-C-13 的 15s 超时走的是这里，不是 TimeoutException。**
    // `Socket.connect(timeout:)` 到点后抛 SocketException，errno 为
    // ETIMEDOUT —— 实测过（连 192.0.2.1:22 与 10.255.255.1:22 两个黑洞
    // 地址，两次都得到 `SocketException: Connection timed out ... errno = 110`，
    // 不是 TimeoutException）。不认这个 errno 的话，最常见的失败会被归成
    // "主机不可达"，并把英文「Connection timed out」当中文说明交给用户。
    final int? code = error.osError?.errorCode;
    if (code == _etimedoutLinux || code == _etimedoutWindows) {
      return ConnectionFailure(
        ConnectionFailureKind.timeout,
        _timeoutMessage,
        cause: error,
      );
    }
    return ConnectionFailure(
      ConnectionFailureKind.unreachable,
      '主机不可达：${error.osError?.message ?? error.message}',
      cause: error,
    );
  }

  if (error is SSHKeyDecryptError) {
    // 私钥带口令。**必须排在 `is SSHError` 之前**，也必须排在下面的
    // `SSHKeyDecodeError` 之前 —— 它是后者的子类，排到后面就到不了这里。
    // 单独一支的价值在于：只有这一支能给出**确定且可操作**的方向
    // （去掉口令即可），另一支只能说他文件读不出来。
    return ConnectionFailure(
      ConnectionFailureKind.authFailed,
      '私钥已加密，本版本暂不支持带口令的私钥。'
      '请改用不带口令的私钥，或等待后续版本支持。',
      cause: error,
    );
  }

  if (error is SSHKeyDecodeError) {
    // 读不出私钥，但**不是**口令问题（内容损坏、格式不认识等）。
    // 文案不能假定口令：对一个文件损坏的用户说"若私钥设了口令…"，
    // 就是让他去翻一个根本不存在的口令 —— 与 §13.15 同一个坑，
    // 只是轻一些（原文仍然附在后面）。
    return ConnectionFailure(
      ConnectionFailureKind.authFailed,
      '无法读取私钥：${error.message}',
      cause: error,
    );
  }

  if (error is SSHError) {
    return ConnectionFailure(
      ConnectionFailureKind.protocolError,
      '协议错误：$error',
      cause: error,
    );
  }

  return ConnectionFailure(
    ConnectionFailureKind.unknown,
    '连接失败：$error',
    cause: error,
  );
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/connection/connection_failure_test.dart`
Expected: 26 个用例全部 PASS

- [ ] **Step 5: 反证测试的非空性（本计划的强制步骤）**

逐条变异，**每条都必须让指定的用例变红**，改完逐字还原。若某条变异下全绿，
说明对应用例没有约束任何行为，必须重写。

| # | 变异 | 必须变红的用例 |
|---|---|---|
| 1 | 删掉 `if (reason is SSHHostkeyError)` 整支 | 「主机密钥被用户拒绝 → hostKey」与「两者必须分类不同」 |
| 2 | 删掉 `if (reason is SSHInternalError)` **整支**（不是只删 if 行） | 「算法协商失败的文案指向算法，同样不指向口令」 |
| 3 | 删掉 `if (error is SSHError)` 整支 | 「SSHError 兜底归 protocolError，不归 unknown」 |
| 4 | 把主机密钥那条消息整段换成 `'认证失败：用户名、口令或私钥不正确'` | 「主机密钥的文案指向指纹，不指向口令」 |
| 5 | 把算法那条消息整段换成上面同一句 | 「算法协商失败的文案指向算法，同样不指向口令」 |
| 6 | 删掉 `SocketException` 分支里的 errno 判定整块 | 「Socket.connect 到点（errno 110）→ timeout，不是 unreachable」与「Windows 的 WSAETIMEDOUT（10060）同样归 timeout」 |
| 7 | 把 errno 判定改成只认 `_etimedoutLinux` | 「Windows 的 WSAETIMEDOUT（10060）同样归 timeout」 |
| 8 | 把 `if (error is SSHKeyDecryptError)` 那一支**挪到** `if (error is SSHKeyDecodeError)` **之后**（子类排到父类后面） | 「带口令的私钥 → 指向"去掉口令"，不要说成协议错误」 |
| 9 | 把 `error.osError?.message ?? error.message` 改成 `error.message` | 「不可达的文案保留操作系统给的原文」 |
| 10 | 把 `authFailed` 那条消息整段换成主机密钥那一句 | 「认证失败的文案指向口令/密钥，不指向指纹」 |
| 11 | 把「每个 kind 的 message 都非空、且不含字面 null」清单里的 `hostKey` 一项删掉 | 同一条（`ConnectionFailureKind.values` 那条断言必须挡住） |
| 12 | 删掉 `classifyConnectionFailure` 开头 `if (error is ConnectionFailure)` **整块** | 「已经是 ConnectionFailure 的原样返回…」与「带 hop 时仍然加"第几跳"前缀…」 |
| 13 | 删掉 `if (error is SSHKeyDecryptError)` **整支** | 「带口令的私钥 → 指向"去掉口令"，不要说成协议错误」（它证明子类必须排在 `SSHKeyDecodeError` 之前） |
| 14 | 删掉 `if (error is SSHKeyDecodeError)` **整支** | 「读不出私钥但不是口令问题 → 不能提口令」 |
| 15 | 把带口令那条消息**两行都**换成 `'无法读取私钥。'` | 「带口令的私钥 → 指向"去掉口令"，不要说成协议错误」 |
| 16 | 删掉 `_classify` 开头那一**行** `if (error is ConnectionFailure) return error;`（只删这一行） | 「SSHSocketError 必须拆开按内层分类 > 内层已经是 ConnectionFailure 时，不再被包成 unknown」 |
| 17 | 把跳板机包装里的 `：${inner.message}` 去掉（只留「第 N 跳 X 失败」） | 「跳板机失败会指明是第几跳」 |
| 18 | 删掉算法那条消息末尾的 `原始信息：${reason.error}` | 「算法协商失败的文案指向算法，同样不指向口令」 |
| 19 | 删掉握手那条消息末尾的 `原始信息：${error.message}` | 「协议错误（握手失败）」 |
| 20 | 把 `'无法读取私钥：${error.message}'` 改成 `'无法读取私钥。'` | 「读不出私钥但不是口令问题 → 不能提口令」 |
| 21 | 把 `'连接失败：$error'` 改成 `'连接失败'` | 「非 SSHError 的意外异常不会漏出去」 |
| 22 | 把 `'协议错误：$error'` 改成 `'协议错误'` | 「SSHError 兜底归 protocolError，不归 unknown」 |
| 23 | 把主机密钥那条消息末尾的可操作指引换成一句没有指引的话 | 「主机密钥的文案指向指纹，不指向口令」 |
| 24 | 把 `_timeoutMessage` 的值改成**不含「超时」**的一句 | 「Socket.connect 到点（errno 110）→ timeout，不是 unreachable」 |

第 2、8 条要删**整支**：只删 `if (...) {` 一行会留下语法破损的残块，编译不过 ——
那不是有效的变异，会让人误以为"变红了"。第 8 条尤其要注意：把 `is SSHKeyDecodeError`
改成 `is Never` 之类的"半删"会让分支体里的 `error.message` 编译不过，那时的红是
**加载失败**而不是断言失败，同样不算数（这两种假绿都实测踩过）。判据只有一条：
看到的是 `Some tests failed` 且失败的是指定用例名。

第 10 条也有同样的编译陷阱，但形态不同：它的锚点 `'认证失败：用户名、口令或私钥不正确',`
**自带尾逗号**，而主机密钥那一句在源码里是多行拼接、末行同样以 `',` 结尾。整块照抄过去
就会写出 `。',` 紧跟着原来的 `,`，变成双逗号 —— 编译失败，而输出**照样**是
`Some tests failed`。替换时只换引号里的内容，尾逗号保留一个。

**第 15 条要整条消息一起换。** 只换第一行是**无效变异**：第二行
「请改用不带口令的私钥…」仍然含"口令"，而用例断言的正是 `contains('口令')`，
于是照样全绿（实测过）。那不是测试弱，是变异没把被测属性移除干净 ——
**看到全绿时，先怀疑变异，再怀疑测试。**

**第 12 条的红色来自哪一条断言，已经变了 —— 别照抄旧结论。** 在 `_classify`
顶部补上幂等判断**之前**，删掉顶部那一整块会红**两**条，其中「带 hop」那条靠的是
`isNot(contains('连接失败：'))`。补上之后**只红一条**：`已经是 ConnectionFailure
的原样返回` 里的 `expect(f, same(original))`（实测，1 红 0 假红）。

「带 hop」那条现在**全绿** —— `_classify` 自己那一行接住了内层、原样返回，
消息没有被包第二层。也就是说那条 `isNot(contains('连接失败：'))` 目前**没有哪个
单点变异能让它红**。它钉的是可观察契约（带 hop 时也不许出现双层面具），留着是对的，
但**别把它当成第 12 条的守卫**。教训：**改完实现要重跑这张表** —— 这一条的结论
就因为我修了实现而失效过一次。

**第 16 条只能删那一行，不能顺手把顶部那一整块也删了 —— 两块互不覆盖。** 它们管的是
不同时刻：`classifyConnectionFailure` 顶部那一块管**第一次**分类，`_classify` 顶部
那一行管 `is SSHSocketError` 递归回来的**第二次**。实测（16 条各自单点）：
删顶部整块（第 12 条）时只红 `已经是 ConnectionFailure 的原样返回`，递归那条用例**全绿**；
删 `_classify` 那一行（第 16 条）时只红递归那条，第 12 条的两条用例**全绿**。
两处各有一条用例、各红各的，所以**两条都要跑**。

**第 17—23 条是补上来的，它们此前**全部全绿**（实测，26/26 通过）。**
是被测的不是 `kind` 而是**文案里的某个片段**：跳板机前缀后面还跟着内层原因、四条
是被测的不是 `kind` 而是**文案里的某个片段**：跳板机前缀后面还跟着内层原因、四条
`原始信息/：${…}` 的原文、`unknown` 与 `SSHError` 兜底里的 `$error`、以及
主机密钥那句可操作的收尾。它们全都**只在「这个片段被删掉」时才红**，所以
**每一条都必须真的跑一遍** —— 这类片段的删除不会让任何 `kind` 改变，看代码是看不出来的。
可操作的收尾、以及超时文案本身。它们全都**只在「这个片段被删掉」时才红**，所以
**每一条都必须真的跑一遍** —— 这类片段的删除不会让任何 `kind` 改变，看代码是看不出来的。

**第 24 条不一样，别把它并进上面那一类。** `_timeoutMessage` 的**值**此前就被钉着
（「errno 110」那条用例断言 `contains('超时')`），把两处文案都改成不含"超时"的句子
**当时就会红**（实测，1 红）。无声的只是**两份副本之间的漂移**：改
`SocketException` 那一份会红，改 `TimeoutException` 那一份 26 条全绿。
所以第 24 条验的是"提成常量"这件事，不是"补一条断言"。


**第 24 条第一次做会踩一个坑，别以为自己测错了。** 把 `_timeoutMessage` 改成
`'连接超时。'` 是**无效变异**：它**仍然含「超时」**，而用例断言的正是
`contains('超时')`，于是照样全绿。这与第 15 条是同一个坑的第二次出现 ——
**改文案类变异时，先问一句「我改完这句，用例断言的那个字/词还在不在？」**
不在，才是有效变异。

**识别假红的通用办法：**看 `[E]` 那一行点名的是什么。点的是**用例名**才是断言失败；
点的是**文件路径**（`loading /…/connection_failure.dart [E]`）就是加载/编译失败，
那个红与用例无关，必须重做。同理，把变异目标文件当参数传给 `flutter test` 也会得到
这种加载红 —— 永远只跑 `flutter test test/connection/connection_failure_test.dart`。

第 4、5、10 条证明的是**文案**被钉住了，而不只是 `kind` —— FR-C-06 的交付物恰恰是文案。
这三条变异在改动前**全部全绿**（实测）：第 4、5 条是 §13.15 那条"用户会去检查一个
根本没问题的口令"的陷阱，第 10 条是它的**镜像**（"用户跑去核对指纹、甚至怀疑中间人"）。

第 6 条钉的是 FR-C-13 的真实形态。执行者**先自己确认这个前提，再照表变异**：
跑一次 `Socket.connect('192.0.2.1', 22, timeout: Duration(seconds: 2))` 并打印异常类型。
若抛的不是 `SocketException`（errno 110）——例如你的网络对该地址立刻返回"网络不可达"——
换一个黑洞地址重试；确实测不出来就跳过第 6、7 条并**明确说明**，不要默默按表执行。

第 11 条不是变异代码，而是删测试清单里的一项：它保证那份清单不会悄悄落后于
`ConnectionFailureKind` 的成员数。

- [ ] **Step 6: 提交**

```bash
dart analyze lib/connection/connection_failure.dart test/connection/connection_failure_test.dart
git add lib/connection/connection_failure.dart test/connection/connection_failure_test.dart
git commit -m "feat: FR-C-06 失败原因分类，区分主机密钥与算法协商"
```

---

## Task 4: `SshSession`

**Files:**
- Create: `lib/connection/ssh_session.dart`
- Test: `test/connection/ssh_session_test.dart`

**四个必须照做的点（写错任何一个都会静默出错）：**

1. `_closed` 必须在关 `client` **之前**置位 —— 否则 `client.close()` 完成的 `session.done` 会被当成一次意外断线，导致退出应用时每台设备触发一次自动重连（§13.14-5）。
2. `onVerifyHostKey` 必须**始终**显式传，即便校验被全局关闭（§13.14-1）。
3. `stdout` 必须 `.cast<List<int>>()` 后才能 `.transform(Utf8Decoder())`（协变陷阱）。
4. 加载私钥的失败必须**在 `_identities()` 里翻译成中文的 `ConnectionFailure`** ——
   见 spec §13.19-9：`fromPem` 的失败有**七种**实测形态（公钥文件、PKCS#8 加密、
   **明文 PKCS#8**、非 PEM/一行式/base64 损坏、损坏的 OPENSSH、**带口令的 PKCS#1**、
   以及 `File(...).readAsStringSync()` 的 `PathNotFoundException`），分类器
   **一种都认不出**，会把英文类名漏给用户。其中两条会把方向指错：`SSHPacketError`
   报成"协议错误"，`ArgumentError` 报成"连接失败"原文。

   **消息要能分开这几种，不能只写"私钥格式不支持"** —— 尤其要分开
   「你选的是公钥」（用户操作错了，改选就行）与「这个格式本版本不支持」
   （用户没做错，得换格式）。**并且翻译要覆盖 `_identities()` 里的全部异常**，
   不是照着 §13.19-9 那张表逐个 `catch`：那张表是实测输入列的，未必穷尽 ——
   判据是"调用点不许漏"，不是"覆盖表里这七种"。

   分类器对 `ConnectionFailure` 是幂等的（顶部 + `_classify` 顶部各判一次，
   见 spec §13.19-10），所以这里直接构造它抛出去即可。
   用例必须覆盖"路径写错"这条最可能的输入。

- [ ] **Step 1: 写失败测试**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_failure.dart';
import 'package:win_cli_tool/connection/connector.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/connection/ssh_session.dart';
import 'package:win_cli_tool/models/device_profile.dart';

DeviceProfile _profile({String? password = 'pw', String? keyPath}) =>
    DeviceProfile(
      id: 'd1',
      name: '核心交换机',
      protocol: DeviceProtocol.ssh,
      host: '10.0.0.1',
      port: 22,
      username: 'admin',
      password: password,
      privateKeyPath: keyPath,
    );

/// 建连必然失败的 Connector，用来测失败路径与清理。
class _FailingConnector implements Connector {
  _FailingConnector(this.error);

  final Object error;

  @override
  Future<Connection> open(String host, int port, {Duration? timeout}) async {
    throw error;
  }
}

/// 把一个必然失败的 future 抛出的 [ConnectionFailure] 取出来。
///
/// 不用 `throwsA`：这些用例要断言失败对象的**内容**（文案把人指向哪儿），
/// `throwsA(isA<ConnectionFailure>())` 拿不到对象。抛的若是别的异常，这里
/// 不接、直接冒出去 —— 用例随即变红，而那正是我们要的（说明翻译没生效，
/// 比如英文类名被漏给了用户）。
Future<ConnectionFailure> _failureOf(Future<void> future) async {
  try {
    await future;
  } on ConnectionFailure catch (failure) {
    return failure;
  }
  fail('本该抛出 ConnectionFailure，却正常返回了');
}

/// 把一段内容写进系统临时目录里的固定文件，返回路径。
String _writeTemp(String name, String content) {
  final file = File('${Directory.systemTemp.path}/wct_t4_$name');
  file.writeAsStringSync(content);
  return file.path;
}

void main() {
  test('从未连上的会话，close() 必须能返回（不能永久挂起）', () async {
    // 守的是 close() 的空路径：会话从没连上时 _client / _session / _socket /
    // _decodeSub 全是 null，任何一处写成非空断言都会在这里抛。而"连不上
    // 之后清理"正是退出应用必经的一步，抛在这里应用就退不掉。
    //
    // 注意这里**不是** spec §13.11 的挂起风险：_output 是广播 controller，
    // 无人监听时 close() 也会立刻完成（实测 ~4ms）。§13.11 说的是单订阅
    // controller —— 那是 ConnectionSocket 的 _stream / _sink。
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('boom')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    await expectLater(session.close(), completes);
  });

  test('connect() 抛异常后，close() 仍必须能返回', () async {
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('boom')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    await expectLater(session.connect(), throwsA(anything));
    await expectLater(session.close(), completes);
  });

  test('close() 可重复调用', () async {
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('boom')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    await session.close();
    await expectLater(session.close(), completes);
  });

  test('配置了主机密钥校验时，verify 回调必须被显式传入', () {
    // §13.14-1：onVerifyHostKey 为 null 时 dartssh2 直接放行任意主机密钥。
    // 用"校验关闭"的场景来测，因为那是最容易被写成"干脆不传"的路径。
    //
    // 这是一条**代理断言**：它只证明 _buildHostKeyCallback() 不返回 null，
    // **不**证明 connect() 真的把它的返回值传了下去 —— 后者要真 sshd 才看得见
    // （Task 7）。别把它读成"接线已验证"。
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('boom')),
      hostKeyStore: InMemoryHostKeyStore(),
      verifyHostKey: false,
    );

    // 校验关闭 ≠ 不传回调。关闭时必须传一个显式的恒真回调，
    // 让"校验被关掉了"这件事在代码里可见、可 grep、可评审。
    expect(session.debugHostKeyCallbackIsNull, isFalse);
  });

  // ---------------------------------------------------------------------
  // 以下四条守 `_identities()` 的翻译。**这是 Task 4 里唯一不需要假 SSH
  // 服务端就能测的真行为** —— 因为实现把加载私钥排在建连**之前**（见 Step 3
  // 的 connect()），所以一个必然失败的 connector 就足以证明"先失败的是私钥"。
  //
  // 每条用例喂的输入都在 2026-09-24 实测过，抛出的类型写在注释里。
  // 五条合起来覆盖 `_identities()` 的每一支：PathNotFound / UnsupportedError /
  // FormatException / SSHKeyDecryptError / 兜底。
  // **每一条分支都必须有对应用例** —— 少一条就有一支失去约束。
  // ---------------------------------------------------------------------

  test('私钥路径写错 → 中文 ConnectionFailure，且先于建连失败', () async {
    // §13.19-9 里最可能发生的输入。实测：`File(path).readAsStringSync()`
    // 抛 `PathNotFoundException`（`FileSystemException` 的子类），分类器
    // 认不出，用户会看到「连接失败：PathNotFoundException: Cannot open file…」。
    //
    // 这里故意用**必然失败**的 connector：实现若把建连排在加载私钥之前，
    // 抛出来的就会是 connector 那个异常，这条用例随即红 —— 所以它同时钉住了
    // "先加载私钥、再开 socket"。
    final session = SshSession(
      profile: _profile(keyPath: '/definitely/not/here/id_rsa'),
      connector: _FailingConnector(Exception('不该走到这里：私钥应当先失败')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    final failure = await _failureOf(session.connect());

    expect(failure.kind, ConnectionFailureKind.authFailed);
    expect(failure.message, contains('私钥'));
    expect(failure.message, contains('/definitely/not/here/id_rsa'));
    // 英文类名不能漏给用户。
    expect(failure.message, isNot(contains('PathNotFoundException')));
  });

  test('选中的是公钥文件 → 文案指向"公钥"，而不是"格式不支持"', () async {
    // §13.19-9 第 1 行。实测：`-----BEGIN PUBLIC KEY-----` 的文件抛
    // `UnsupportedError('Unsupported key type: PUBLIC KEY')`。
    // 这是**用户操作错了**（换一个文件就好），与"本版本不支持这个格式"
    // 是两回事 —— 混成一句，用户会去反复确认自己的私钥没问题。
    final session = SshSession(
      profile: _profile(
        keyPath: _writeTemp(
          'id_rsa.pub',
          '-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n',
        ),
      ),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    final failure = await _failureOf(session.connect());

    expect(failure.kind, ConnectionFailureKind.authFailed);
    expect(failure.message, contains('公钥'));
    expect(failure.message, isNot(contains('Unsupported')));
  });

  test('不是 PEM 的文件 → 文案说"不是 PEM"，不说"格式不支持"', () async {
    // 实测：`hello world` 抛
    // `FormatException: PEM header must start with -----BEGIN `。
    // 分类器认不出它（`FormatException` 遍布 `dart:core`）。
    final session = SshSession(
      profile: _profile(keyPath: _writeTemp('not_a_key.txt', 'hello world\n')),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    final failure = await _failureOf(session.connect());

    expect(failure.kind, ConnectionFailureKind.authFailed);
    expect(failure.message, contains('PEM'));
    expect(failure.message, isNot(contains('FormatException')));
  });

  test('损坏的 OPENSSH 私钥 → 绝不能报成"协议错误"', () async {
    // §13.19-9 第 4 行，也是那张表里**方向错得最狠**的一行。实测：截断的
    // OPENSSH 私钥抛 `SSHPacketError`，而分类器把 `SSHPacketError` 全局映射成
    // `protocolError`（它在传输层有 18 个抛出点，不能全局改）—— 用户会去
    // 查算法，实际是他的密钥文件坏了。
    //
    // 这一条走的是 `_identities()` 的兜底 `catch`，所以它也证明那个兜底存在。
    final session = SshSession(
      profile: _profile(
        keyPath: _writeTemp(
          'id_ed25519',
          '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n'
              '-----END OPENSSH PRIVATE KEY-----\n',
        ),
      ),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    final failure = await _failureOf(session.connect());

    expect(failure.kind, ConnectionFailureKind.authFailed);
    expect(failure.message, contains('私钥'));
    // 关键：不能把方向指到协议/算法上去。
    expect(failure.message, isNot(contains('协议错误')));
    expect(failure.message, isNot(contains('算法')));
    // 原文**要留着**（§13.19-1「永远不吞掉异常」），与分类器 `unknown` 那一格
    // 同一个设计：认得出的给干净中文，认不出的给中文框架 + 原文。少了这条断言，
    // 把兜底消息里的 `$error` 删掉是一样的绿 —— 而那就把异常吞了。
    expect(failure.message, contains('SSHPacketError'));
  });

  test('带口令的 OPENSSH 私钥 → 走分类器，绝不能漏出字面 null', () async {
    // 守 `_identities()` 里 `on SSHKeyDecryptError` 那一支。**这一支不能删**
    // —— 删了它，这个异常会落进兜底 `catch`，而 `SSHKeyDecryptError` 的
    // `error` 字段**就是 null**（实测
    // `SSHKeyDecryptError(Private key is encrypted, null)`），于是用户看到
    // 「无法读取私钥：<路径>\n原始信息：SSHKeyDecryptError(Private key is
    // encrypted, null)」—— §13.19-7 修好的那个 null 泄漏，换一层原样复活，
    // 而 Task 3 的用例**照绿**（它们直接测分类器，不经过 `_identities()`）。
    //
    // 也**不能改成 `rethrow`**：那样 `connect()` 抛出的就不是
    // `ConnectionFailure` 了，用户看到什么取决于调用方有没有记得分类。
    //
    // 下面是**一次性的测试夹具**，用
    // `ssh-keygen -t ed25519 -N fixture-pass` 生成，口令就是 `fixture-pass`。
    // 它不是任何真实设备的密钥，也不对应任何生产凭据。
    final session = SshSession(
      profile: _profile(
        keyPath: _writeTemp(
          'id_ed25519_enc',
          '-----BEGIN OPENSSH PRIVATE KEY-----\n'
              'b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDzJhElhL\n'
              'ZC4quN68dxaD+oAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAII0XNBvuCWPL5haR\n'
              'rSk1xpK71hXUAuqLHEPOyTlfjc88AAAAkNDLCL2UJGRbxc6VlATFngWCsfvB6KgC0yVoll\n'
              'gOThm5FkwLY8OBCJaixXln+cYCoVedYFxjHnVAan3J9/Ut3Wk9RBlB6VZTU+DnKWachIoA\n'
              'ZQYFaAE4Gpz7N8X5M7sCUYtppdK8w3iErB9jfbCCVP/jJTW7bjheC6OBRW0vF554yfTIYa\n'
              'qeLJmqgQ9WYle79Q==\n'
              '-----END OPENSSH PRIVATE KEY-----\n',
        ),
      ),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    final failure = await _failureOf(session.connect());

    expect(failure.kind, ConnectionFailureKind.authFailed);
    // 给的是"去掉口令"这条可操作的方向。
    expect(failure.message, contains('口令'));
    expect(failure.message, isNot(contains('null')));
    expect(failure.message, isNot(contains('SSHKeyDecryptError')));
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/connection/ssh_session_test.dart`
Expected: 编译失败，**0 个用例被执行**（CFE 措辞见 Task 1 Step 3：`Error when reading ...`，不是 `Target of URI doesn't exist`）

- [ ] **Step 3: 实现**

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/device_profile.dart';
import 'connection_failure.dart';
import 'connection_socket.dart';
import 'connector.dart';
import 'known_host.dart';
import 'session.dart';

/// 基于 dartssh2 的 SSH 会话实现。
///
/// 与 [TelnetSession] 的结构差异：这里不需要"原始字节 → 文本"的中间
/// controller，直接把 `session.stdout` 解码进 `_output` 即可。因此本类
/// **没有**单订阅 controller，spec §13.11 的挂起风险不存在。
class SshSession implements Session {
  SshSession({
    required this.profile,
    this.connector = const DirectConnector(),
    required this.hostKeyStore,
    this.connectTimeout = const Duration(seconds: 15),
    this.verifyHostKey = true,
    this.onUnknownHostKey,
    this.ptyType = 'xterm',
    this.ptyWidth = 120,
    this.ptyHeight = 40,
    this.pollInterval = const Duration(milliseconds: 250),
  });

  final DeviceProfile profile;

  /// 建连方式。默认直连；计划 3 会注入带跳板机的实现。
  final Connector connector;

  /// 已知主机密钥存储。**由外部注入**（spec §13.5）。
  final HostKeyStore hostKeyStore;

  final Duration connectTimeout;

  /// 是否校验主机密钥（FR-C-11）。默认开启（NFR-S-03）。
  final bool verifyHostKey;

  /// 首次连接某主机时询问用户是否接受该指纹。
  /// 返回 true 表示接受并保存。为 null 时一律拒绝 —— 见 [_verifyHostKey]。
  final Future<bool> Function(KnownHost host)? onUnknownHostKey;

  final String ptyType;
  final int ptyWidth;
  final int ptyHeight;

  /// 重连时的探活间隔（TCP keepalive 由 dartssh2 的 keepAliveInterval 负责）。
  final Duration pollInterval;

  final _output = StreamController<String>.broadcast();
  final _done = Completer<void>();

  /// 会话断开时保留错误对象（FR-C-06 / spec §13.12）。null 表示正常断开。
  Object? _lastError;

  ConnectionSocket? _socket;
  SSHClient? _client;
  SSHSession? _session;
  StreamSubscription<String>? _decodeSub;
  var _closed = false;

  /// 供测试断言"校验关闭时也没有把 null 传下去"。
  ///
  /// **这是一条代理断言，别读成"接线已验证"**：它读的是
  /// [_buildHostKeyCallback] 的返回值，而不是真正交给 `SSHClient` 的那个值 ——
  /// 把 [connect] 里的 `onVerifyHostKey:` 改成 null，它依然为真。真正锁住
  /// 接线的是 Task 7 的真 sshd 用例：回调为 null 时 dartssh2 接受任意主机
  /// 密钥（§13.14-1），于是"用户拒绝指纹则连不上"那条会失败。
  bool get debugHostKeyCallbackIsNull => _buildHostKeyCallback() == null;

  /// 最近一次断开的原始错误。正常断开为 null。
  Object? get lastError => _lastError;

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  /// 构造传给 dartssh2 的主机密钥校验回调。
  ///
  /// **返回 null 的情况被刻意排除**：dartssh2 在回调为 null 时会把
  /// `userVerified` 直接取 true，即接受任意主机密钥（§13.14-1）。
  /// 因此这里总是返回一个非 null 回调 —— 校验关闭时返回恒真回调，
  /// 让"校验被关掉了"在代码里是可见的。
  Future<bool> Function(String, Uint8List)? _buildHostKeyCallback() {
    if (!verifyHostKey) {
      // 显式的恒真回调，而不是 null。两者行为相同，但这一行可被 grep、
      // 可被评审看见；null 则藏在库的默认值里。
      return (String type, Uint8List fingerprint) async => true;
    }
    return (String type, Uint8List fingerprint) async {
      final candidate = KnownHost(
        host: profile.host,
        port: profile.port,
        keyType: type,
        fingerprint: utf8.decode(fingerprint, allowMalformed: true),
      );

      final known = await hostKeyStore.find(
        candidate.host,
        candidate.port,
        candidate.keyType,
      );

      if (known != null) {
        // 指纹不一致：可能是设备换过密钥，也可能是中间人。
        // 一律拒绝，由用户去设置里清除旧记录后重连。
        return known.fingerprint == candidate.fingerprint;
      }

      final accept = await onUnknownHostKey?.call(candidate) ?? false;
      if (accept) {
        await hostKeyStore.save(candidate);
      }
      return accept;
    };
  }

  @override
  Future<void> connect() async {
    // **先加载私钥，再开 socket。** 两个理由：
    //   1. 私钥读不出来是**本地配置错误**，与网络无关。让它先失败，就不必为
    //      一个注定连不上的会话开连接；否则 `_socket` 已赋值、`_client` 还没建，
    //      会出现第三种"半初始化"状态（另两种见下面两处 `if (_closed)` 守卫）。
    //   2. 这让"私钥翻译"这条路径**不需要假 SSH 服务端就能测**：用一个必然
    //      失败的 connector 就能证明它**先**失败（见 Step 1 的用例）。Task 4
    //      的其余几条要么不碰网络、要么留给 Task 7，唯有这一条既重要又可测。
    final identities = _identities();

    final conn = await connector.open(
      profile.host,
      profile.port,
      timeout: connectTimeout,
    );
    // 建连期间可能已经被 close()（用户切设备、关窗口）。与 TelnetSession
    // 同样的守卫：把刚拿到的连接关掉直接返回，否则资源泄漏。
    if (_closed) {
      await conn.close();
      return;
    }

    // 不保留 conn 字段：它的生命周期由 ConnectionSocket 持有并负责释放
    // （见 close() 里的 _socket?.dispose()）。多存一份只会带来"两份引用、
    // 一处释放"的不一致。
    final socket = ConnectionSocket(conn);
    _socket = socket;

    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities,
      onPasswordRequest: _onPasswordRequest,
      // 始终非 null，见 _buildHostKeyCallback 的说明。
      onVerifyHostKey: _buildHostKeyCallback(),
    );
    _client = client;

    await client.authenticated;

    // 认证期间也可能被 close()。
    if (_closed) {
      await client.close();
      socket.dispose();
      return;
    }

    final session = await client.shell(
      pty: SSHPtyConfig(type: ptyType, width: ptyWidth, height: ptyHeight),
    );
    if (_closed) {
      session.close();
      await client.close();
      socket.dispose();
      return;
    }
    _session = session;

    // .cast<List<int>>() 不能省：stdout 是 Stream<Uint8List>，而
    // Stream.transform 按**运行时**类型校验 transformer，直接 transform
    // 会抛 "type 'Utf8Decoder' is not a subtype of type
    // 'StreamTransformer<Uint8List, String>'"。与计划 1 connector.dart
    // 记录的是同一个协变陷阱。
    _decodeSub = session.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_output.add, onError: _onError);

    // done 的转发必须带守卫：client.close() 会完成 session.done，
    // 不守卫的话"主动关闭"会被看成一次意外断线，触发自动重连。
    session.done.then(
      (_) => _onDisconnected(null),
      onError: (Object e, StackTrace _) => _onDisconnected(e),
    );
  }

  /// 加载私钥，并把**本地能判定的失败**翻译成中文的 [ConnectionFailure]。
  ///
  /// §13.19-9 记录了七种实测的 `fromPem` 失败形态，分类器**认不出**其中三种：
  /// 它只拿到一个裸 `Object`，无从知道某个 `FormatException` 来自"读私钥"还是
  /// 别处（`SSHPacketError` 在传输层有 18 个抛出点，`FormatException` 遍布
  /// `dart:core`）。上下文只有这里知道，所以翻译必须在**调用点**做。
  ///
  /// 分类器对 [ConnectionFailure] 是幂等的（§13.19-10），这里直接抛即可。
  ///
  /// **判据是"这一层不许漏"，不是"覆盖 §13.19-9 表里那七种"** —— 那张表是照着
  /// 实测输入列的、未必穷尽，所以末尾必须留一个兜底 `catch`。
  List<SSHIdentity>? _identities() {
    final path = profile.privateKeyPath;
    if (path == null || path.isEmpty) return null;

    try {
      final pem = File(path).readAsStringSync();
      // 这里不处理带口令的私钥：口令要从凭据接口取，属于计划 4。
      return SSHKeyPair.fromPem(pem);
    } on PathNotFoundException {
      // 最可能发生的一种（路径打错、文件被挪走）—— 单独一支，方向最明确。
      // 其余 I/O 失败（选到了目录、权限不足）不单独设支：它们会落到下面的
      // 兜底，那条同样带上路径与原文，而兜底已经有用例钉住（见 Step 1）。
      // **不为没有用例的支数写代码** —— 写一条没人守的分支，就是给后来人
      // 留一条可以静默改坏的路径。
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法读取私钥文件：路径不存在。请检查设备设置里的私钥路径。\n$path',
      );
    } on UnsupportedError {
      // 公钥文件，或本版本不支持的 PKCS#8（明文与加密都落在这里）。
      // **两种原因必须分开说**：选错文件是用户操作错了、换一个就好；
      // 格式不支持是本版本的缺口。混成一句"格式不支持"，用户会去反复确认
      // 自己的私钥没问题 —— 与 §13.15 同一个坑。
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法使用这个私钥：$path\n'
        '两个常见原因：选中的是公钥文件（.pub），'
        '或这个私钥格式（PKCS#8）本版本暂不支持。'
        '请选择 PEM 格式的 RSA 私钥（-----BEGIN RSA PRIVATE KEY-----）。',
      );
    } on FormatException {
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法解析这个文件：$path\n它看起来不是 PEM 格式的私钥。',
      );
    } on SSHKeyDecryptError {
      // 带口令的 OPENSSH 私钥。**分类器也认得这一支**（§13.19-9 论证过：这两个
      // 类的抛出点全关在 dartssh2 的 `lib/src/key_pair/` 里，全局映射是安全的），
      // 所以这里是一次**刻意的重复**。理由是维持一条可检验的不变量：
      //
      //   **`connect()` 不该为本地密钥问题漏出非 `ConnectionFailure` 的异常。**
      //
      // 若改成 `rethrow` 放行给分类器，用户看到什么就取决于调用方有没有记得
      // 分类 —— 而 §13.19-7 那个 `null` 泄漏正是这样一层一层漏过去的。
      // 下面这句话与分类器里那一句是同一句，**两处要一起改**。
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '私钥已加密，本版本暂不支持带口令的私钥。'
        '请改用不带口令的私钥，或等待后续版本支持。',
      );
    } catch (error) {
      // 兜底：损坏的 OPENSSH（`SSHPacketError`）、带口令的 PKCS#1
      // （`ArgumentError`），以及 §13.19-9 还没量到的形态。**这一支不能省** ——
      // 省了它们就漏到分类器，用户看到英文类名，其中 `SSHPacketError` 还会被
      // 报成"协议错误"，把方向指到算法上去。
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法读取私钥：$path\n原始信息：$error',
        cause: error,
      );
    }
  }

  FutureOr<String?> _onPasswordRequest() => profile.password;

  void _onError(Object error, StackTrace _) {
    _lastError = error;
  }

  void _onDisconnected(Object? error) {
    // §13.14-5：主动 close() 也会走到这里（client.close() 完成 done），
    // 必须靠 _closed 区分，否则退出应用会触发一轮自动重连。
    if (_closed) return;
    if (error != null) _lastError = error;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void write(String text) {
    if (_closed) return;
    _session?.write(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    // 必须在关 client 之前置位，否则 client.close() 完成的 session.done
    // 会被当成意外断线。
    _closed = true;

    await _decodeSub?.cancel();
    _session?.close();
    await _client?.close();
    _socket?.dispose();

    // 不 await：_output 是**广播** controller，close() 即使无人监听也会
    // 立刻完成，所以这里改成 await 也不会挂 —— 留 unawaited 只是不想在
    // 关闭路径上等一个无意义的 future。真正会永不完成的是**单订阅**
    // controller，那是 ConnectionSocket 的 _stream / _sink（§13.11），
    // 与本类无关（见类文档）。
    unawaited(_output.close());
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/connection/ssh_session_test.dart`
Expected: 9 个用例全部 PASS

- [ ] **Step 5: 反证测试的非空性**

本 Task 的 9 条单测逐条变异验证，**每次改完逐字还原**：

1. `_client?.close()` 改成 `_client!.close()`（`_decodeSub?.cancel()`、
   `_session?.close()` 同理）：必须让前 3 条用例变红 —— 它们守的就是
   `close()` 的空路径。
2. 让 `_buildHostKeyCallback()` 在 `verifyHostKey == false` 时返回 null：
   必须让 `verify 回调必须被显式传入` 变红。
3. 删掉 `on PathNotFoundException` 那一支：必须让「私钥路径写错」变红。
   它会落到兜底，消息里仍然有"私钥"和路径，**红的是
   `isNot(contains('PathNotFoundException'))` 这一条** —— 这正是那条断言存在的
   理由（兜底的 `原始信息：$error` 会把英文类名带回来）。
4. 删掉 `on UnsupportedError` 那一支：必须让「选中的是公钥文件」变红。
5. 删掉 `on FormatException` 那一支：必须让「不是 PEM 的文件」变红。
6. 删掉 `on SSHKeyDecryptError` 那一支：必须让「带口令的 OPENSSH 私钥」变红
   （字面 `null` 与 `SSHKeyDecryptError` 会从兜底漏出去）。
   **这一条是本 Task 最值得跑的一条** —— 它守的缺陷在 Task 3 里刚修过，
   换一层就复活，而 Task 3 的用例看不见（它们不经过 `_identities()`）。
   把那一支改成 `rethrow` 也应当变红（抛出的不再是 `ConnectionFailure`，
   `_failureOf` 不接）。
7. 删掉兜底 `catch (error)` 那一支：必须让「损坏的 OPENSSH 私钥」变红
   （`SSHPacketError` 会直接冒到分类器，报成"协议错误"）。
8. 把 `final identities = _identities();` 移回 `connector.open()` **之后**：
   必须让「私钥路径写错」变红 —— 抛出来的会变成 connector 那个异常
   （`_failureOf` 不接非 `ConnectionFailure`，用例直接红）。
9. 把兜底消息里的 `$error` 删掉：必须让「损坏的 OPENSSH 私钥」变红
   （`contains('SSHPacketError')` 那一条）。

**本表已由计划作者在隔离副本里实跑过一遍**（把两个 fence 抽出来放进一份临时拷贝，
没动本仓库）。观察到的红与上面逐条一致：第 1 条 3 红，第 2—7、9 条各 1 红，
第 8 条 5 红，**零假红**（没有一条红是点名文件的加载/编译失败）。所以上面那些
"必须让某条变红"不是估计，是量过的 —— 你跑出来不一样就是发现，请报告。
**但你自己仍要跑一遍**：Step 2 的红、Step 4 的绿、这里的变异红，是三个不同的
证据，缺一个都不算完成。

Run: `flutter test test/connection/ssh_session_test.dart`

**私钥翻译这条路径是覆盖到的，而且不需要假服务端** —— 因为实现把加载私钥排在
建连**之前**（第 3—9 条变异都在守这一点）。这是本 Task 里唯一既重要、又能用
一个必然失败的 connector 测到真行为的地方。**别为了"更真实"把它挪回
`connector.open()` 之后** —— 那样这五条用例会一起失效，而它们守的正是
§13.19-9 那个"英文类名漏给用户"的洞。

**本 Task 覆盖不到的部分 —— 这是量的结论，不要当作通过：**

- `_onDisconnected` 里的 `if (_closed) return;` 守卫。删掉它，预期 4 条用例
  **全部照绿**：没有任何一条会真的建起 SSHClient，`_onDisconnected` 压根
  不会被调用。跑一遍确认是这个结果；**若你看到红，那是发现，请报告**。
- 主机密钥回调的**函数体**（find → 比对 → save / 拒绝）。没有任何用例
  调用过它。
- `onVerifyHostKey:` 这个**传参点**。`debugHostKeyCallbackIsNull` 读的是
  `_buildHostKeyCallback()` 的返回值，而不是真正交给 `SSHClient` 的那个值 ——
  所以把 `connect()` 里改成 `onVerifyHostKey: null`，这条用例依然绿。这是个
  代理断言，别把它当成"接线已被验证"。

这三条都由 **Task 7** 用真 sshd 覆盖（首次询问 / 接受后落库 / 拒绝则连不上 /
指纹不一致则拒绝，以及 close-done 守卫）。所以这里**不要**自己造一个"能连上的
假会话"去补 —— 一个假 SSH 服务端是 Task 7 的活，在这里造只会得到一个
测不出真问题的替身。变异跑完，把上述结论如实写进报告。

- [ ] **Step 6: 提交**

```bash
dart analyze lib/connection/ssh_session.dart test/connection/ssh_session_test.dart
git add lib/connection/ssh_session.dart test/connection/ssh_session_test.dart
git commit -m "feat: SshSession —— PTY shell、主机密钥校验、断线守卫"
```

---

## Task 5: `SessionFactory` —— 按协议造会话

**Files:**
- Create: `lib/connection/session_factory.dart`
- Test: `test/connection/session_factory_test.dart`

**为什么要这一层：** 上层（`ConnectionManager`、计划 5 的界面）不应该知道 SSH 与 Telnet 的区别，也不应该知道 `HostKeyStore` 从哪来。这一层是唯一的协议分叉点。计划 3 的跳板机只需要换掉 `connectorResolver`，不改任何其他代码。

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connector.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/connection/session_factory.dart';
import 'package:win_cli_tool/connection/ssh_session.dart';
import 'package:win_cli_tool/connection/telnet_session.dart';
import 'package:win_cli_tool/models/device_profile.dart';

DeviceProfile _profile(DeviceProtocol protocol) => DeviceProfile(
      id: 'd1',
      name: '设备',
      protocol: protocol,
      host: '10.0.0.1',
      port: protocol.defaultPort,
      username: 'admin',
    );

void main() {
  test('SSH 设备造出 SshSession', () {
    final factory = SessionFactory(hostKeyStore: InMemoryHostKeyStore());
    expect(factory.create(_profile(DeviceProtocol.ssh)), isA<SshSession>());
  });

  test('Telnet 设备造出 TelnetSession', () {
    final factory = SessionFactory(hostKeyStore: InMemoryHostKeyStore());
    expect(factory.create(_profile(DeviceProtocol.telnet)), isA<TelnetSession>());
  });

  test('每次调用返回新实例（重连要换新会话，不能复用旧的）', () {
    final factory = SessionFactory(hostKeyStore: InMemoryHostKeyStore());
    final p = _profile(DeviceProtocol.ssh);

    expect(identical(factory.create(p), factory.create(p)), isFalse);
  });

  test('可以把建连方式换掉（计划 3 的跳板机靠这个注入）', () {
    final factory = SessionFactory(
      hostKeyStore: InMemoryHostKeyStore(),
      connectorResolver: (profile) => const DirectConnector(),
    );
    expect(factory.create(_profile(DeviceProtocol.ssh)), isA<SshSession>());
  });
}
```

> 需要 `import 'package:win_cli_tool/connection/connector.dart';`

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/connection/session_factory_test.dart`
Expected: 编译失败，**0 个用例被执行**（CFE 措辞见 Task 1 Step 3：`Error when reading ...`，不是 `Target of URI doesn't exist`）

- [ ] **Step 3: 实现**

```dart
import '../models/device_profile.dart';
import 'connector.dart';
import 'known_host.dart';
import 'session.dart';
import 'ssh_session.dart';
import 'telnet_session.dart';

/// 决定一台设备用哪种 [Connector] 建连。
///
/// 默认直连。计划 3 的跳板机在这里注入 —— `SshSession` 与
/// `ConnectionManager` 都不需要为此改动。
typedef ConnectorResolver = Connector Function(DeviceProfile profile);

Connector _directConnector(DeviceProfile profile) => const DirectConnector();

/// 按设备协议造出对应的 [Session]。
///
/// 这是全应用**唯一**的协议分叉点：上层不应出现
/// `if (protocol == ssh)` 这样的判断。
class SessionFactory {
  const SessionFactory({
    required this.hostKeyStore,
    this.connectorResolver = _directConnector,
    this.connectTimeout = const Duration(seconds: 15),
    this.verifyHostKey = true,
    this.onUnknownHostKey,
  });

  /// 已知主机密钥存储，注入给 [SshSession]（spec §13.5）。
  final HostKeyStore hostKeyStore;

  final ConnectorResolver connectorResolver;
  final Duration connectTimeout;
  final bool verifyHostKey;
  final Future<bool> Function(KnownHost host)? onUnknownHostKey;

  Session create(DeviceProfile profile) {
    final connector = connectorResolver(profile);

    return switch (profile.protocol) {
      DeviceProtocol.ssh => SshSession(
          profile: profile,
          connector: connector,
          hostKeyStore: hostKeyStore,
          connectTimeout: connectTimeout,
          verifyHostKey: verifyHostKey,
          onUnknownHostKey: onUnknownHostKey,
        ),
      DeviceProtocol.telnet => TelnetSession(
          profile: profile,
          connector: connector,
          connectTimeout: connectTimeout,
        ),
    };
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/connection/session_factory_test.dart`
Expected: 4 个用例全部 PASS

- [ ] **Step 5: 提交**

```bash
dart analyze lib/connection/session_factory.dart test/connection/session_factory_test.dart
git add lib/connection/session_factory.dart test/connection/session_factory_test.dart
git commit -m "feat: SessionFactory —— 按协议构造会话，唯一的协议分叉点"
```

---

## Task 6: `ConnectionManager` —— 生命周期、重连与队列

**Files:**
- Modify: `lib/connection/connection_manager.dart`（Task 0 的骨架）
- Test: `test/connection/connection_manager_test.dart`

**本 Task 实现的 FR：** FR-C-01/02（长连接常驻）、FR-C-05（主动断开）、FR-C-07（指数退避重连）、FR-C-08（每次重连后重新执行登录后命令）、FR-C-09（重连分隔标记）、FR-C-10（丢弃未发命令）、FR-C-12（退出时不发命令）。

**退避序列（FR-C-07）：** 1s → 2s → 4s → 8s → 16s → 30s 封顶，此后维持 30s。

**退避在"连上一次"之后归零（对 FR-C-07 的解释）：** FR-C-07 的序列描述的是**连续重连尝试**的间隔，即"一直连不上时等多久"，不是"这台设备历史上断过几次"。因此 `_attemptConnect` 一旦连上就 `_attempt = 0`；此后再次断线，从 1s 重新开始。

理由：一台能连上、只是偶尔掉线的设备，若永不归零，会因为几次早期失败而永久退化到 30s 才重连一次 —— 用户看到的"设备明明在线却半天不恢复"就是这么来的。反过来，一台连上就立刻掉的设备会每 1s 重连一次，但每次都是一轮完整的 TCP+SSH 握手（秒级），不构成打爆设备的循环。

这是**对需求的解释**，不是需求原文。若日后要求"跨断线累积退避"，改 `_attemptConnect` 里归零的那一行即可，测试「连上一次之后退避归零」就是这条边界。

**时间源必须用 `clock.now()`，不能用 `DateTime.now()`：** `_disconnectedAt` 与 FR-C-09 的 `downtime` 都走 `package:clock`。`fake_async` 推进的是 `clock`，`DateTime.now()` 走真实时间 —— 用它的话，测试里 `elapse(1s)` 之后 `downtime` 恒为 0 秒，「重连成功发出 Reconnected 事件并带上断线时长」永远断言不了。

**拆除（teardown）相关断言一律用真实 `async`，不要用 `fakeAsync`：** `fake_async` 推不动完整的拆除链 —— `cancel()` / `close()` 的 future 在 fake zone 下不会完成，`await` 停在里面，`session.close()` 根本执行不到，断言于是**假失败**（实测：同一段代码真实 async 下 `closed == true`，fakeAsync 下恒为 `false`，且 `pendingTimers` 与 `microtaskCount` 都是 0，无处可推）。拆除本身不涉及计时，真实 async 更直接也更强。`fakeAsync` 只用在**需要控制时间**的用例上（退避序列、封顶、`downtime`）。

**本类的四个所有权/健壮性要点（都是预演中改出来的，不要改回去）：**

1. **失败分支也必须认 `_userClosed`。** `_attemptConnect` 的 catch 与 `_scheduleRetry` 都要在 `_userClosed` 时早退：用户在 `session.connect()` 返回前点"断开"，`disconnect()` 关掉 socket 会让在途的 connect 抛错，走进 catch。不早退就会发出一个**假告警**（这次失败是我们自己造成的），并把状态刷成 `failed` —— 按钮从灰变红，而 spec §5.4 要求用户主动断开后是**灰**的。真正该变红的只有 `!autoReconnect` 一种情形，两者不要合并判断。
2. **`_teardownSession()` 在任何 `await` 之前先把所有字段取走并置空。** 否则慢的那次拆除会在 `await` 之后把**新会话**的 `_outputSub` / `_dispatcher` 置空 —— 重连与拆除交叠时必然发生。
3. **不要给 `dispatcher.events` 挂转发订阅。** 曾经有过一个：收到 `QueueDropped` 就 `_events.add(SessionLost(null))`。它**永不触发** —— `CommandDispatcher._events` 是异步广播 controller，`QueueDropped` 要等一个 microtask，而 `_teardownSession()` 在同一个同步块里就把它取消了（实测：原样放回去测试仍然全绿）。而且它想达成的效果本来就重复：丢弃数由 `QueueDropped` 承载，界面直接订阅 `dispatcher.events` 取用（spec §13.16 第 2 条的设计结论）。所以本类**不订阅** dispatcher 的任何事件，`_dispatcher` 只用来调 `onOutput` / `onDisconnected` / `dispose`。
4. **`_teardownSession()` 不 `await dispatcher.dispose()`。** 它是广播 `StreamController`，`close()` 的 future 要等订阅者全部摘干净才完成，而订阅者不止我们（界面会直接订阅 `dispatcher.events`）。把 `session.close()` 挂在它后面，就等于让 FR-C-12 依赖一个我们控制不了的 future。`dispose()` 的同步部分（`_disposed = true`、清空队列）立即生效，所以 fire-and-forget 不会再发出任何命令。同理，建连失败分支里也是 `unawaited(_teardownSession())` —— 拆除是清理，不能挡住重连排程。

- [ ] **Step 1: 写失败测试**

```dart
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/command_dispatcher.dart';
import 'package:win_cli_tool/connection/connection_failure.dart';
import 'package:win_cli_tool/connection/connection_manager.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/connection/session.dart';
import 'package:win_cli_tool/connection/session_factory.dart';
import 'package:win_cli_tool/models/device_profile.dart';

/// 建连失败（设备不可达之类）。用自定义类型避免依赖 dart:io。
class _ConnectFailed implements Exception {
  const _ConnectFailed();

  @override
  String toString() => 'connect failed';
}

/// 可控的假会话。
class _FakeSession implements Session {
  _FakeSession(this.profile, {this.failConnect = false, this.gate = false});

  final DeviceProfile profile;
  final bool failConnect;

  /// 为 true 时 connect() 会挂在握手中途，直到 close() 把它打断 ——
  /// 用来复现"建连尚未返回时用户就点了断开"。
  final bool gate;
  Completer<void>? _gate;
  final _output = StreamController<String>.broadcast();
  final _done = Completer<void>();
  final written = <String>[];
  var connectCalls = 0;
  var closed = false;

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> connect() async {
    connectCalls++;
    if (gate) {
      _gate = Completer<void>();
      await _gate!.future;
    }
    if (failConnect) throw const _ConnectFailed();
  }

  @override
  void write(String text) => written.add(text);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    // 真实会话里 socket 在握手途中被关掉，connect() 必然抛错 —— 复现它。
    if (!(_gate?.isCompleted ?? true)) _gate!.complete();
    unawaited(_output.close());
  }

  /// 模拟对端断开。
  void drop() {
    if (!_done.isCompleted) _done.complete();
  }

  void emit(String s) {
    if (!_output.isClosed) _output.add(s);
  }
}

class _FakeFactory implements SessionFactory {
  _FakeFactory(this.sessions, {this.failConnect = false, this.gate = false});

  final List<_FakeSession> sessions;

  /// 可中途翻转：测试"先失败若干次、再连上"的场景。
  bool failConnect;

  /// 透传给每个 _FakeSession。
  final bool gate;

  var created = 0;

  @override
  Session create(DeviceProfile profile) {
    created++;
    final s = _FakeSession(profile, failConnect: failConnect, gate: gate);
    sessions.add(s);
    return s;
  }

  @override
  HostKeyStore get hostKeyStore => InMemoryHostKeyStore();

  @override
  ConnectorResolver get connectorResolver =>
      (p) => throw UnimplementedError();

  @override
  Duration get connectTimeout => const Duration(seconds: 15);

  @override
  bool get verifyHostKey => true;

  @override
  Future<bool> Function(KnownHost)? get onUnknownHostKey => null;
}

DeviceProfile _profile() => const DeviceProfile(
  id: 'd1',
  name: '核心交换机',
  protocol: DeviceProtocol.ssh,
  host: '10.0.0.1',
  port: 22,
  username: 'admin',
  postLoginCommands: ['enable'],
);

void main() {
  test('connect() 成功后状态为 connected，并下发登录后命令', () async {
    final sessions = <_FakeSession>[];
    final mgr = ConnectionManager(
      profile: _profile(),
      factory: _FakeFactory(sessions),
    );

    await mgr.connect();

    expect(mgr.state, DeviceConnectionState.connected);
    expect(sessions.single.connectCalls, 1);
    // FR-C-08：登录后命令在连接成功后自动下发。
    expect(sessions.single.written, ['enable\n']);
  });

  test('连续建连失败按 1s -> 2s -> 4s 退避（FR-C-07）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      // 建连一律失败 —— 退避序列讲的是"一直连不上时等多久"，
      // 只有让每次尝试都失败，才能观察到序列本身。
      final factory = _FakeFactory(sessions, failConnect: true);
      final mgr = ConnectionManager(profile: _profile(), factory: factory);

      mgr.connect(); // 第 1 次尝试立即失败
      async.flushMicrotasks();
      expect(factory.created, 1);
      expect(mgr.state, DeviceConnectionState.reconnecting);

      // 第 1 次重连：1s。差 1ms 时必须还没动，否则"等了 1s"无从证明。
      async.elapse(const Duration(milliseconds: 999));
      async.flushMicrotasks();
      expect(factory.created, 1, reason: '不足 1s 不得重连');
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(factory.created, 2, reason: '1s 后应进行第 1 次重连');

      // 第 2 次重连：2s
      async.elapse(const Duration(milliseconds: 1999));
      async.flushMicrotasks();
      expect(factory.created, 2, reason: '不足 2s 不得重连');
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(factory.created, 3, reason: '2s 后应进行第 2 次重连');

      // 第 3 次重连：4s
      async.elapse(const Duration(milliseconds: 3999));
      async.flushMicrotasks();
      expect(factory.created, 3, reason: '不足 4s 不得重连');
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(factory.created, 4, reason: '4s 后应进行第 3 次重连');

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('退避在 30s 封顶，之后维持 30s（FR-C-07）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final factory = _FakeFactory(sessions, failConnect: true);
      final mgr = ConnectionManager(profile: _profile(), factory: factory);

      mgr.connect();
      async.flushMicrotasks();

      // 1,2,4,8,16,30 —— 第 6 次起到达封顶，之后一直是 30s。
      const schedule = [1, 2, 4, 8, 16, 30, 30, 30];
      for (var i = 0; i < schedule.length; i++) {
        final delay = Duration(seconds: schedule[i]);

        // 两头都断言：早 1ms 不许动，到点必须动。
        // 只断言"到点已经动了"是假测试 —— 等超了也满足。
        async.elapse(delay - const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(
          factory.created,
          i + 1,
          reason: '第 ${i + 1} 次重连不得早于 ${schedule[i]}s',
        );

        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(
          factory.created,
          i + 2,
          reason: '第 ${i + 1} 次重连应在 ${schedule[i]}s 后发生',
        );
      }

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('连上一次之后退避归零：再断线仍从 1s 开始（FR-C-07）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final factory = _FakeFactory(sessions, failConnect: true);
      final mgr = ConnectionManager(profile: _profile(), factory: factory);

      // 先失败两次：退避已经升到 2s 档（下一次该等 4s）。
      mgr.connect();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(factory.created, 3);

      // 这次让它连上（第 3 次重连，4s 档）。
      factory.failConnect = false;
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(mgr.state, DeviceConnectionState.connected);
      expect(factory.created, 4);

      // 再断线：退避应重新从 1s 开始。若不归零，这里要等 8s。
      sessions.last.drop();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 999));
      async.flushMicrotasks();
      expect(factory.created, 4, reason: '归零后不足 1s，不得重连');
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(factory.created, 5, reason: '退避应从 1s 重新开始');

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('重连成功后重新下发登录后命令（FR-C-08）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: _FakeFactory(sessions),
      );

      mgr.connect();
      async.flushMicrotasks();
      expect(sessions[0].written, ['enable\n']);

      sessions[0].drop();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      // 每次重连成功都要重新执行 —— 这是 FR-C-08 明确要求的。
      expect(sessions[1].written, ['enable\n']);

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('断线时未发出的命令被丢弃且不重放（FR-C-10）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: _FakeFactory(sessions),
      );

      mgr.connect();
      async.flushMicrotasks();

      final events = <ConnectionEvent>[];
      mgr.events.listen(events.add);

      // 队列里已有登录后命令 'enable'，它已经写出去了、正在等提示符
      // （即"在途"）。再排三条用户命令，它们排在 'enable' 后面等着。
      final dispatcher = mgr.dispatcher!;
      final dropped = <int>[];
      dispatcher.events.listen((e) {
        if (e is QueueDropped) dropped.add(e.count);
      });
      dispatcher.enqueue(['show version', 'show run', 'show ip']);

      // 断线
      sessions[0].drop();
      async.flushMicrotasks();

      expect(
        events.whereType<SessionLost>().isNotEmpty,
        isTrue,
        reason: '断线必须通知界面',
      );

      // FR-C-10 要求"输出区给出告警"，所以丢弃数必须报上来。
      // 3 条排队的 + 1 条在途的 = 4：在途那条的输出永远收不到了，
      // 它同样属于"未完成、不得重放"，漏掉它就少报一条。
      expect(dropped, [4], reason: '要报出被丢弃的命令数（含在途的那条）');

      // 重连成功后，被丢弃的命令**不得**被重放
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(sessions[1].written, ['enable\n'], reason: '只应有登录后命令，被丢弃的命令不得重放');

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('用户主动断开不触发重连（FR-C-05 / §5.4）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final factory = _FakeFactory(sessions);
      final mgr = ConnectionManager(profile: _profile(), factory: factory);

      mgr.connect();
      async.flushMicrotasks();

      mgr.disconnect();
      // 状态必须在 disconnect() 被调用的当下就翻转，不能等拆除流程走完 ——
      // 否则用户点了"断开"，按钮要过一会儿才变灰。
      expect(mgr.state, DeviceConnectionState.disconnected);

      async.elapse(const Duration(seconds: 60));
      async.flushMicrotasks();

      expect(factory.created, 1, reason: '主动断开后不得再重连');

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('重连成功发出 Reconnected 事件并带上断线时长（FR-C-09）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: _FakeFactory(sessions),
      );

      final events = <ConnectionEvent>[];
      mgr.connect();
      async.flushMicrotasks();
      mgr.events.listen(events.add);

      sessions[0].drop();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      final reconnected = events.whereType<Reconnected>().single;
      // 断线到重连成功恰好 1s（退避序列第一档）。
      // 这里能断言，靠的是 ConnectionManager 用 clock.now() 而不是
      // DateTime.now() —— 后者不受 fake_async 影响，会恒为 0。
      expect(reconnected.downtime.inSeconds, 1);
      expect(reconnected.attempt, 1);

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('建连途中用户主动断开：不得报失败，也不得转红（FR-C-05 / §5.4）', () async {
    // 真实 async：这条要等 close() 把在途的 connect() 打回来才会走完。
    final sessions = <_FakeSession>[];
    final mgr = ConnectionManager(
      profile: _profile(),
      factory: _FakeFactory(sessions, failConnect: true, gate: true),
    );

    final failures = <ConnectionFailure>[];
    mgr.events.listen((e) {
      if (e is ConnectionFailed) failures.add(e.failure);
    });

    final connecting = mgr.connect(); // 挂在握手中途，还没返回
    await Future<void>.delayed(Duration.zero);
    expect(mgr.state, DeviceConnectionState.connecting);

    // 用户此刻点了"断开"。拆除会关掉 socket，于是在途的 connect() 抛错。
    await mgr.disconnect();
    await connecting;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // §5.4：用户主动断开 → 停止重连，按钮变灰。不是红。
    expect(
      mgr.state,
      DeviceConnectionState.disconnected,
      reason: '§5.4：主动断开后按钮变灰，而不是红',
    );
    // 这次失败是我们自己关 socket 造成的，报给用户就是假告警。
    expect(failures, isEmpty, reason: '自己造成的失败不得报给用户');
    expect(sessions.length, 1, reason: '不得因这次失败再重连');
  });

  test('一次断线只发一个 SessionLost，丢弃数由 QueueDropped 承载（FR-C-10）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: _FakeFactory(sessions),
      );

      mgr.connect();
      async.flushMicrotasks();

      final lost = <SessionLost>[];
      mgr.events.listen((e) {
        if (e is SessionLost) lost.add(e);
      });
      final dropped = <int>[];
      mgr.dispatcher!.events.listen((e) {
        if (e is QueueDropped) dropped.add(e.count);
      });

      // 'enable' 已写出、在途；这条排在它后面等着。
      mgr.dispatcher!.enqueue(['show version']);

      sessions[0].drop();
      async.flushMicrotasks();

      // 界面按 SessionLost 在输出区插标记，发两次就是两个标记。
      expect(lost.length, 1, reason: '一次断线只应发一个 SessionLost');
      // 丢弃数以 QueueDropped 为准（1 条排队 + 1 条在途）。
      expect(dropped, [2], reason: '丢弃数由 QueueDropped 承载');

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('关闭自动重连时，建连失败置为 failed（红），且不排程重连（FR-C-06）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final factory = _FakeFactory(sessions, failConnect: true);
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: factory,
        autoReconnect: false,
      );

      final failures = <ConnectionFailure>[];
      mgr.events.listen((e) {
        if (e is ConnectionFailed) failures.add(e.failure);
      });

      mgr.connect();
      async.flushMicrotasks();

      // autoReconnect=false 是唯一应当变红（failed）的情形。
      // 注意与"用户主动断开"区分：那种情况 §5.4 要求是灰的。
      expect(mgr.state, DeviceConnectionState.failed);
      expect(failures.length, 1, reason: '失败原因只报一次');
      expect(factory.created, 1);

      // 推过整个退避序列，都不该有新会话。
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      expect(factory.created, 1, reason: 'autoReconnect=false 时不得重连');
      expect(mgr.state, DeviceConnectionState.failed);

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('dispose() 关闭会话，且不向设备发送任何命令（FR-C-12）', () async {
    // 这条**不用 fakeAsync**：fake_async 推不动完整的拆除链
    // （cancel/close 的 future 在 fake zone 下不会完成），断言会假失败。
    // 拆除本身不涉及计时，真实 async 更直接也更强。
    final sessions = <_FakeSession>[];
    final mgr = ConnectionManager(
      profile: _profile(),
      factory: _FakeFactory(sessions),
    );

    await mgr.connect();
    final before = List<String>.from(sessions.single.written);

    await mgr.dispose();

    expect(sessions.single.closed, isTrue);
    expect(sessions.single.written, before, reason: 'FR-C-12：退出时不得发送任何命令');

    // dispose 之后即使对端断开，也不得再重连。
    sessions.single.drop();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sessions.length, 1, reason: 'dispose 之后不得再重连');
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/connection/connection_manager_test.dart`
Expected: 编译失败 —— `ConnectionManager` 没有 `profile` / `factory` / `connect` 等成员

- [ ] **Step 3: 实现**

在 Task 0 建好的 `lib/connection/connection_manager.dart` 里补齐实现。**Task 0 已经写好的 `DeviceConnectionState` 枚举与 `ConnectionEvent` 事件类（`ConnectionStateChanged` / `SessionReady` / `ReconnectScheduled` / `Reconnected` / `ConnectionFailed` / `SessionLost`）原样保留，不要重写**；下面是完整文件内容，Task 0 的那部分已包含在内：

```dart
import 'dart:async';

import 'package:clock/clock.dart';

import '../command/command_dispatcher.dart';
import '../command/more_pager.dart';
import '../command/prompt_detector.dart';
import '../models/device_profile.dart';
import 'connection_failure.dart';
import 'session.dart';
import 'session_factory.dart';

/// 一台设备的连接状态。与 spec §5.4 的按钮颜色一一对应。
///
/// 颜色映射（供计划 5 使用）：disconnected→灰、connecting→黄、
/// connected→绿、reconnecting→黄、failed→红。
///
/// 注意"红"：§5.4 的逐事件表里**没有**红（只有黄/黄/绿/灰），红来自
/// FR-C-06 的"连接失败"。`failed` 何时可达目前尚未定论，见 spec §13.17-3。
enum DeviceConnectionState {
  /// 未连接。与 [connecting]/[reconnecting] 同为"没有连接"，
  /// 但颜色不同：这两个是黄，本状态是灰。
  disconnected,
  connecting,
  connected,

  /// 重连中。与 [connecting] **颜色相同**（都是黄），区别只在输出区文案。
  reconnecting,

  /// 连接失败且**不再自动重试**（`autoReconnect` 为 false 时）。
  ///
  /// 注意：用户主动断开**不是**这个状态 —— §5.4 要求那种情况按钮变灰，
  /// 也就是 [disconnected]。
  failed;

  /// 该状态下设备按钮是否应显示为"有连接"。重连中算"没有连接"——
  /// 此时发给设备的命令会失败，界面必须让用户看出来。
  bool get isLive => this == DeviceConnectionState.connected;
}

/// [ConnectionManager] 对外发出的事件。每台设备一个 manager，各自一条流。
///
/// 声明为 `sealed`：界面（计划 5）对它的 switch 会被编译器要求穷尽，
/// 将来新增一种事件会成为**编译错误**，而不是某个分支悄悄不渲染。
sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// 状态迁移。界面据此更新按钮颜色与输出区提示。
final class ConnectionStateChanged extends ConnectionEvent {
  const ConnectionStateChanged(this.state);

  final DeviceConnectionState state;
}

/// 会话已就绪（首次连接或重连成功），可以下发命令了。
///
/// 携带的是本次会话的 [CommandDispatcher]：每次重连都会**新建**一个，
/// 所以界面必须在这里重新订阅 `dispatcher.events`（命令输出与
/// [QueueDropped] 都从那里来）。
///
/// **界面不得订阅 `Session.output`** —— 会话对象在重连时会被整个替换，
/// 直接订阅它会让输出区在第一次断线后永久静止而按钮是绿的。
/// 输出请订阅 `ConnectionManager.output`。
final class SessionReady extends ConnectionEvent {
  const SessionReady(this.dispatcher);

  final CommandDispatcher dispatcher;
}

/// 即将在 [delay] 之后发起第 [attempt] 次重连（从 1 开始）。
final class ReconnectScheduled extends ConnectionEvent {
  const ReconnectScheduled(this.attempt, this.delay);

  final int attempt;
  final Duration delay;
}

/// 重连成功。FR-C-09 要求输出区插入醒目分隔标记，[downtime] 即断线时长。
final class Reconnected extends ConnectionEvent {
  const Reconnected(this.downtime, this.attempt);

  /// 从断开到重连成功经过的时长（FR-C-09 的标记要显示它）。
  final Duration downtime;

  /// 是第几次重连尝试成功的（从 1 开始）。
  ///
  /// 计数在**连接成功**时归零，所以它只统计本次断线期间的重试次数。
  /// 首次就连接成功不发本事件（attempt 恒 > 0）。
  final int attempt;
}

/// 连接失败。[failure] 携带可读原因（FR-C-06）。
final class ConnectionFailed extends ConnectionEvent {
  const ConnectionFailed(this.failure);

  final ConnectionFailure failure;
}

/// 会话断开。
///
/// 被丢弃的命令数**不在**这里 —— 它在 [CommandDispatcher] 的 [QueueDropped]
/// 上（那是计划 1 已有的契约，界面直接订阅 `dispatcher.events` 取用）。
/// 一次断线只发**一个**本事件。
final class SessionLost extends ConnectionEvent {
  const SessionLost(this.failure);

  /// null 表示对端正常结束，或本次断开没有可分类的错误 ——
  /// 界面需要自备兜底文案。
  final ConnectionFailure? failure;
}

/// 一台设备的会话生命周期、重连与命令队列。
///
/// **所有权约定**：界面只订阅本类的 [events] 与 [dispatcher]，
/// **不直接订阅 [Session]**。会话在重连时会被整个替换，本类是唯一
/// 知道"什么时候换了"的角色；若界面直接持有旧的 Session，重连之后
/// 输出区会永久静止而按钮却是绿的。
class ConnectionManager {
  ConnectionManager({
    required this.profile,
    required this.factory,
    this.autoReconnect = true,
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ],
    this.promptDetector,
    this.morePager,
  });

  final DeviceProfile profile;
  final SessionFactory factory;
  final bool autoReconnect;

  /// 退避序列。最后一项即封顶值，之后一直用它（FR-C-07）。
  final List<Duration> backoff;

  final PromptDetector? promptDetector;
  final MorePager? morePager;

  final _events = StreamController<ConnectionEvent>.broadcast();
  final _output = StreamController<String>.broadcast();

  Session? _session;
  CommandDispatcher? _dispatcher;
  StreamSubscription<String>? _outputSub;
  Timer? _retryTimer;
  var _state = DeviceConnectionState.disconnected;
  var _attempt = 0;
  var _disconnectedAt = clock.now();
  var _disposed = false;
  var _userClosed = false;

  Stream<ConnectionEvent> get events => _events.stream;

  /// 该设备的合并输出流。跨重连连续 —— 界面只订阅这一个。
  Stream<String> get output => _output.stream;

  DeviceConnectionState get state => _state;

  /// 当前会话的命令队列。未连接时为 null。
  CommandDispatcher? get dispatcher => _dispatcher;

  void _setState(DeviceConnectionState s) {
    if (_state == s) return;
    _state = s;
    if (!_events.isClosed) _events.add(ConnectionStateChanged(s));
  }

  /// 发起连接。用户点击设备按钮时调用（FR-C-03）。
  Future<void> connect() async {
    if (_disposed) return;
    _userClosed = false;
    await _attemptConnect();
  }

  Future<void> _attemptConnect() async {
    if (_disposed || _userClosed) return;

    _setState(
      _attempt == 0
          ? DeviceConnectionState.connecting
          : DeviceConnectionState.reconnecting,
    );

    final session = factory.create(profile);
    _session = session;

    try {
      await session.connect();
    } catch (e) {
      if (_disposed) return;
      // 不 await：拆除是清理，不能挡住重连排程。_teardownSession 会在任何
      // await 之前同步清空 _session/_outputSub 等状态，所以 fire-and-forget
      // 不会与随后的重连串到一起去。
      unawaited(_teardownSession());
      // 用户已断开或应用已退出：这次失败是我们自己关掉 socket 造成的。
      // 报给用户就是假告警，改状态则会让按钮从灰变红（§5.4 要求是灰的）。
      if (_disposed || _userClosed) return;
      if (!_events.isClosed) {
        _events.add(ConnectionFailed(classifyConnectionFailure(e)));
      }
      _scheduleRetry();
      return;
    }

    if (_disposed || _userClosed) {
      // 建连期间用户已经断开或应用已退出：直接关掉，不进入已连接状态。
      await _teardownSession();
      return;
    }

    _outputSub = session.output.listen((chunk) {
      if (!_output.isClosed) _output.add(chunk);
      _dispatcher?.onOutput(chunk);
    }, onError: (Object _) {});

    _dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: promptDetector ?? PromptDetector(),
      morePager: morePager ?? MorePager(),
      lineEnding: profile.lineEnding,
    );
    session.done.then(
      (_) => _onSessionDone(),
      onError: (Object e, StackTrace _) {
        _onSessionDone(e);
      },
    );

    final wasReconnect = _attempt > 0;
    if (wasReconnect) {
      // 用 clock.now() 而不是 DateTime.now()：fake_async 推进的是 clock，
      // 用真实时间会让 FR-C-09 的断线时长在测试里恒为 0。
      final downtime = clock.now().difference(_disconnectedAt);
      if (!_events.isClosed) _events.add(Reconnected(downtime, _attempt));
    }
    if (!_events.isClosed) _events.add(SessionReady(_dispatcher!));

    // 退避计数在**连接成功**时归零：FR-C-07 的 1→2→4→… 描述的是
    // "一直连不上时等多久"，不是"这台设备历史上断过几次"。一台能连上、
    // 只是偶尔掉线的设备，每次都应该 1s 后就重连，而不是无限升级到 30s。
    _attempt = 0;
    _setState(DeviceConnectionState.connected);

    // FR-C-08：连接成功后自动下发登录后命令。追加到队列尾部，
    // 因此用户此时发出的命令会排在其后。
    if (profile.postLoginCommands.isNotEmpty) {
      _dispatcher!.enqueue(profile.postLoginCommands);
    }
  }

  void _onSessionDone([Object? error]) {
    if (_disposed || _userClosed) return;
    _disconnectedAt = clock.now();

    // FR-C-10：未发出的命令一律丢弃，不自动重放。
    // onDisconnected 会把在途的那条也计入丢弃数 —— 它的输出永远收不到了。
    _dispatcher?.onDisconnected();
    _teardownSession();

    if (!_events.isClosed) {
      _events.add(
        SessionLost(error == null ? null : classifyConnectionFailure(error)),
      );
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    // 用户主动断开或应用退出：状态已由 disconnect()/dispose() 定好，
    // 这里再改一次就会把按钮从灰刷成红（§5.4 要求灰色）。
    if (_disposed || _userClosed) return;

    if (!autoReconnect) {
      _setState(DeviceConnectionState.failed);
      return;
    }

    _setState(DeviceConnectionState.reconnecting);
    _attempt++;

    // 超出序列时用最后一项（封顶，FR-C-07）。
    final delay =
        backoff[_attempt - 1 < backoff.length
            ? _attempt - 1
            : backoff.length - 1];

    if (!_events.isClosed) _events.add(ReconnectScheduled(_attempt, delay));

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (_disposed || _userClosed) return;
      unawaited(_attemptConnect());
    });
  }

  /// 用户主动断开（FR-C-05）。停止重连，按钮变灰（§5.4）。
  Future<void> disconnect() async {
    _userClosed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _attempt = 0;
    // 立即置为已断开：用户点了"断开"，按钮就该马上变灰，而不是等拆除
    // 流程走完（关闭 socket 可能要等对端响应）。state 是同步可读的，
    // 界面下一帧就会看到。
    _setState(DeviceConnectionState.disconnected);
    await _teardownSession();
  }

  /// 应用退出时调用（FR-C-12）。
  ///
  /// **不向设备发送任何命令** —— 包括不清除分页、不执行任何登出序列。
  /// 目的是避免意外改变设备状态。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _userClosed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _teardownSession();
    await _events.close();
    await _output.close();
  }

  /// 拆除当前会话。可重入：状态在任何 await 之前就被清空并取走，
  /// 因此重复调用是空操作，也不会出现"慢的那个把新会话的字段置空"。
  Future<void> _teardownSession() async {
    final session = _session;
    final outputSub = _outputSub;
    final dispatcher = _dispatcher;
    _session = null;
    _outputSub = null;
    _dispatcher = null;

    await outputSub?.cancel();

    // 不 await dispatcher.dispose()：它是广播 StreamController，close() 的
    // future 要等订阅者全部摘干净才完成，而订阅者不止我们 —— 界面会直接
    // 订阅 dispatcher.events。把 session.close() 挂在它后面，就等于让
    // FR-C-12（退出时必须关闭会话）依赖一个我们控制不了的 future。
    // 实测：await 它会让本函数停在此处不再往下走，session.close() 永远
    // 执行不到。dispose() 的同步部分（_disposed=true、清空队列）立即生效，
    // 所以 fire-and-forget 不会再发出任何命令。
    if (dispatcher != null) unawaited(dispatcher.dispose());

    if (session != null) {
      // done 完成不等于资源已释放（spec §13.12）：close() 仍必须调用。
      await session.close();
    }
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/connection/connection_manager_test.dart`
Expected: 12 个用例全部 PASS

- [ ] **Step 5: 反证九个承载行为的非空性（逐个做，每个都要看到红）**

计划 1 的教训是"全绿"不等于"被约束"。下表每一条都是把缺陷**放回去**，确认对应测试确实变红；不变红就说明那条测试是空的。每改一条立刻恢复，最后 `git diff` 确认工作区干净再提交。

| # | 把缺陷放回去 | 必须变红的测试 |
|---|---|---|
| M1 | `_scheduleRetry` 里 `final delay = backoff[...]` 改成 `backoff[0]`（退避不再升级） | 连续建连失败按 1s -> 2s -> 4s 退避 |
| M2 | `_attemptConnect` 成功分支里删掉 `_attempt = 0;`（连上后不归零） | 连上一次之后退避归零 |
| M3 | `disconnect()` 里把 `_setState(disconnected)` 挪到 `await _teardownSession()` **之后** | 用户主动断开不触发重连 |
| M4 | `_teardownSession` 里删掉 `await session.close();` | dispose() 关闭会话（FR-C-12） |
| M5 | `_onSessionDone` 里删掉 `_dispatcher?.onDisconnected();` | 断线时未发出的命令被丢弃（FR-C-10） |
| M6 | `onDisconnected` 里 `_queue.length + (_current != null ? 1 : 0)` 改成只算 `_queue.length` | 同上（丢弃数漏算在途的那条） |
| M7 | `_attemptConnect` 的 catch 里去掉 `if (_disposed \|\| _userClosed) return;`，并把 `_scheduleRetry` 的 `_userClosed` 早退合并回「置 failed」 | 建连途中用户主动断开：不得报失败，也不得转红 |
| M8 | `_onSessionDone` 里再补一句 `_events.add(SessionLost(null));` | 一次断线只发一个 SessionLost |
| M9 | `_scheduleRetry` 里删掉 `if (!autoReconnect) { _setState(failed); return; }` | 关闭自动重连时，建连失败置为 failed（红） |

已实测：M1–M9 全部变红。

**M7（代码评审查出来的真缺陷）**：catch 分支原来只认 `_disposed`，成功分支却认 `_disposed || _userClosed` —— 这个不对称就是漏洞。用户在 `session.connect()` 还没返回时点"断开"，`disconnect()` 会关掉 socket 让在途的 connect 抛错，于是走进 catch：既发了一个**假告警**（这次失败是我们自己造成的），又经 `_scheduleRetry()` 把状态刷成 `failed` —— 按钮从灰变红。spec §5.4 写得很清楚：用户主动断开，**按钮变灰**。修法是 catch 与 `_scheduleRetry` 都认 `_userClosed`，并且把 `!autoReconnect`（真正该变红的唯一情形）与 `_userClosed` 分开处理。

**M9 为什么必须有**：把 `failed` 收窄到 `!autoReconnect` 之后，这条路径就成了 `failed` 的**唯一**来源，而它当时一条测试都没有 —— 实测把整个 `if (!autoReconnect) {...}` 删掉，11 个用例**全绿**。一个"改了行为却没有测试压住"的路径，等于没改。补上用例后 M9 变红（`Expected: failed, Actual: reconnecting`）。

**关于 M8 附近的一条被证伪的推断，记录在案**：代码评审曾判断 `_attemptConnect` 里那个 `_dispatcherSub` 转发订阅会导致**一次断线发两个 `SessionLost`**（一次来自 `_onSessionDone`，一次来自 `QueueDropped` 的转发）。实测**不成立** —— 在 M7 修复后的代码上把那两行原样放回去，`一次断线只发一个 SessionLost` 仍然全绿。原因是 `CommandDispatcher._events` 是**异步**广播 controller（`command_dispatcher.dart:100`，没有 `sync: true`），`onDisconnected()` 投递的 `QueueDropped` 要等一个 microtask 才到，而 `_teardownSession()` 在**同一个同步块**里就把 `_dispatcherSub` 取消了 —— 转发监听器永远收不到那条事件。也就是说那段转发是**永不触发的死代码**，不是重复发送。

**这条结论是顺序敏感的，不只是"取消得早"**：把 `_teardownSession()` 里那行 `cancel()` 挪到 `await outputSub?.cancel()` **之后**，转发就会收到事件、测试立刻变红（`expected 1, actual 2`）。所以真正的约束不是"记得取消订阅"，而是**根本不要订阅 `dispatcher.events` 来转发** —— 让正确性依赖两行代码的先后顺序，迟早会被一次无心的重排打破。结论仍然是删掉它，理由换成了"它达不到注释宣称的效果"，与"丢弃数由 `QueueDropped` 承载（界面直接订阅 `dispatcher.events`，见 §13.16 第 2 条的设计结论）"一致。**不要**再据"广播 close/取消的顺序"去推断类似问题，先测。

**M5/M6 值得特别说明**：只断言"重连后没有重放"是**假测试** —— 重连会新建一个 `CommandDispatcher`，旧队列在结构上就不可能被重放，去掉 `onDisconnected()` 它照样绿。FR-C-10 真正可观测的是**告警**（"输出区给出告警"），所以测试断言的是 `QueueDropped` 事件的**条数**：3 条排队的 + 1 条在途的 = 4。

- [ ] **Step 6: 提交**

```bash
dart analyze lib/connection/connection_manager.dart test/connection/connection_manager_test.dart
git add lib/connection/connection_manager.dart test/connection/connection_manager_test.dart
git commit -m "feat: ConnectionManager —— 长连接、指数退避重连、队列生命周期"
```

---

## Task 7: 真 `sshd` 集成测试

**Files:**
- Create: `test/fixtures/sshd_harness.dart`
- Test: `test/connection/ssh_session_integration_test.dart`

**为什么需要这一层：** `dartssh2` **不提供 SSH 服务端**（spec §9.3 已更正），所以没法在进程内造假 SSH 设备。上面各 Task 的假 `Session` 能覆盖状态机，但覆盖不了三件只有真连接才能验的事：① 真实握手与 PTY；② `client.close()` 完成 `session.done` 这条守卫（Task 4 Step 5 没能反证的那条）；③ `stdout` 的运行时类型确实是 `Uint8List`。

**跳过守卫是硬要求**：Windows 开发机与 CI 上没有 `sshd`，这些用例必须 `skip` 而不是失败。

- [ ] **Step 1: 写测试夹具**

```dart
import 'dart:io';

/// 一个真实的本地 sshd，用于 SSH 集成测试。
///
/// spec §9.3：dartssh2 不提供 SSH 服务端，因此用真 sshd 起回环连接。
/// 不可用时（Windows、CI）所有用例应跳过而非失败。
class SshdHarness {
  SshdHarness._(this.port, this._dir, this._pid);

  final int port;
  final Directory _dir;
  final int _pid;

  /// 本机是否具备运行条件。**同步**判断，因为 `skip:` 参数需要同步求值。
  static String? get unavailableReason {
    if (!File('/usr/sbin/sshd').existsSync()) {
      return '本机没有 /usr/sbin/sshd（Windows 或精简环境下跳过）';
    }
    if (!File('/usr/bin/ssh-keygen').existsSync()) {
      return '本机没有 ssh-keygen';
    }
    return null;
  }

  static bool get isAvailable => unavailableReason == null;

  /// 起一个只监听回环、只接受公钥认证的 sshd。
  static Future<SshdHarness> start() async {
    final dir = Directory.systemTemp.createTempSync('wct-sshd-');
    final user = Platform.environment['USER'] ?? 'tester';

    String run(String exe, List<String> args) {
      final r = Process.runSync(exe, args, workingDirectory: dir.path);
      if (r.exitCode != 0) {
        throw StateError('$exe ${args.join(' ')} 失败: ${r.stderr}');
      }
      return r.stdout as String;
    }

    // 主机密钥
    run('/usr/bin/ssh-keygen', ['-q', '-t', 'ed25519', '-f', 'hostkey', '-N', '']);
    // 用户密钥
    run('/usr/bin/ssh-keygen', ['-q', '-t', 'ed25519', '-f', 'userkey', '-N', '']);

    File('${dir.path}/authorized_keys')
        .writeAsStringSync(File('${dir.path}/userkey.pub').readAsStringSync());

    // 找一个空闲高位端口：先绑 0 拿到端口号再释放。
    // ServerSocket 没有 bindSync，这里 await —— start() 本来就是异步的。
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final config = '''
Port $port
ListenAddress 127.0.0.1
HostKey ${dir.path}/hostkey
PidFile ${dir.path}/sshd.pid
AuthorizedKeysFile ${dir.path}/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
UsePAM no
StrictModes no
LogLevel ERROR
''';
    File('${dir.path}/sshd_config').writeAsStringSync(config);

    final r = Process.runSync(
      '/usr/sbin/sshd',
      ['-f', '${dir.path}/sshd_config', '-E', '${dir.path}/sshd.log'],
    );
    if (r.exitCode != 0) {
      throw StateError('sshd 启动失败: ${r.stderr}');
    }

    final pid = int.parse(File('${dir.path}/sshd.pid').readAsStringSync().trim());

    // 等端口真正可连
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final s = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(milliseconds: 200));
        s.destroy();
        break;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    final h = SshdHarness._(port, dir, pid);
    h.user = user;
    h.privateKeyPath = '${dir.path}/userkey';
    return h;
  }

  late final String user;
  late final String privateKeyPath;

  /// 主机密钥指纹，形如 `SHA256:...`。
  String hostFingerprint() {
    final out = Process.runSync('/usr/bin/ssh-keygen', [
      '-lf', '${_dir.path}/hostkey',
    ]).stdout as String;
    // 输出形如 "256 SHA256:xxxx no comment (ED25519)"
    return out.split(' ')[1];
  }

  Future<void> stop() async {
    Process.runSync('kill', ['$_pid']);
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 清理失败不影响测试结论
    }
  }
}
```

- [ ] **Step 2: 写集成测试**

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/connection/ssh_session.dart';
import 'package:win_cli_tool/models/device_profile.dart';

import '../fixtures/sshd_harness.dart';

void main() {
  final skipReason = SshdHarness.unavailableReason;
  late SshdHarness sshd;

  setUpAll(() async {
    if (skipReason == null) sshd = await SshdHarness.start();
  });

  tearDownAll(() async {
    if (skipReason == null) await sshd.stop();
  });

  SshSession sessionWith(
    HostKeyStore store, {
    bool verify = true,
    Future<bool> Function(KnownHost)? onUnknown,
  }) =>
      SshSession(
        profile: DeviceProfile(
          id: 'd1',
          name: '本地 sshd',
          protocol: DeviceProtocol.ssh,
          host: '127.0.0.1',
          port: sshd.port,
          username: sshd.user,
          privateKeyPath: sshd.privateKeyPath,
        ),
        hostKeyStore: store,
        verifyHostKey: verify,
        onUnknownHostKey: onUnknown,
      );

  test('首次连接会询问指纹，接受后写入 store', () async {
    final store = InMemoryHostKeyStore();
    KnownHost? asked;

    final session = sessionWith(store, onUnknown: (h) async {
      asked = h;
      return true;
    });

    await session.connect();

    expect(asked, isNotNull);
    expect(asked!.fingerprint, startsWith('SHA256:'));
    expect(store.all.single.fingerprint, asked!.fingerprint);

    await session.close();
  }, skip: skipReason);

  test('已记录的主机不再询问，直接连上', () async {
    final store = InMemoryHostKeyStore();
    var askCount = 0;

    final first = sessionWith(store, onUnknown: (h) async {
      askCount++;
      return true;
    });
    await first.connect();
    await first.close();
    expect(askCount, 1);

    final second = sessionWith(store, onUnknown: (h) async {
      askCount++;
      return true;
    });
    await second.connect();
    await second.close();

    expect(askCount, 1, reason: '第二次不应再询问');
  }, skip: skipReason);

  test('用户拒绝指纹则连不上', () async {
    final store = InMemoryHostKeyStore();
    final session = sessionWith(store, onUnknown: (h) async => false);

    await expectLater(session.connect(), throwsA(anything));
    expect(store.all, isEmpty);

    await session.close();
  }, skip: skipReason);

  test('指纹与已记录的不一致时拒绝连接', () async {
    final store = InMemoryHostKeyStore();
    // 预置一条错误的指纹
    await store.save(KnownHost(
      host: '127.0.0.1',
      port: sshd.port,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:this-is-not-the-real-fingerprint',
    ));

    var asked = false;
    final session = sessionWith(store, onUnknown: (h) async {
      asked = true;
      return true;
    });

    await expectLater(session.connect(), throwsA(anything));
    expect(asked, isFalse, reason: '有记录时不应回退到询问用户');

    await session.close();
  }, skip: skipReason);

  test('主动 close() 不触发 done —— client.close() 会完成 session.done，'
      '必须被 _closed 守卫挡住（spec §13.14-5）', () async {
    final store = InMemoryHostKeyStore();
    final session = sessionWith(store, onUnknown: (h) async => true);

    await session.connect();

    var doneFired = false;
    unawaited(session.done.then((_) => doneFired = true));

    await session.close();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(doneFired, isFalse,
        reason: '主动关闭不得被看成意外断线 —— 否则退出应用会触发一轮自动重连');
  }, skip: skipReason);

  test('真实会话的 stdout 解码正常（UTF-8 与多字节字符）', () async {
    final store = InMemoryHostKeyStore();
    final session = sessionWith(store, onUnknown: (h) async => true);

    await session.connect();

    final out = StringBuffer();
    final sub = session.output.listen(out.write);

    // 用 printf 输出多字节字符，验证流式解码器跨分片正确
    session.write('printf "中文测试OK\\n"\n');

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!out.toString().contains('中文测试OK') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(out.toString(), contains('中文测试OK'));

    await sub.cancel();
    await session.close();
  }, skip: skipReason);
}
```

- [ ] **Step 3: 运行测试**

Run: `flutter test test/connection/ssh_session_integration_test.dart`
Expected: 本机有 sshd，6 个用例应全部 PASS。

在 Windows 或无 sshd 的环境上应显示为 skipped，而不是 failed —— 这是本 Task 的验收点之一。

- [ ] **Step 4: 反证「主动 close() 不触发 done」这条的非空性**

把 `SshSession._onDisconnected` 里的 `if (_closed) return;` 删掉，重跑：
Expected: 上面第 5 条必须变红。

这是 Task 4 Step 5 没能完成的那个反证，这里用真会话补上。**若删掉守卫后仍然全绿，说明这条测试没约束到行为。**

改完恢复。

- [ ] **Step 5: 提交**

```bash
dart analyze test/fixtures/sshd_harness.dart test/connection/ssh_session_integration_test.dart
git add test/fixtures/sshd_harness.dart test/connection/ssh_session_integration_test.dart
git commit -m "test: 真 sshd 回环集成测试（含主机密钥与 close/done 守卫）"
```

---

## Task 8: SSH 端到端 —— `SshSession` + `CommandDispatcher`

**Files:**
- Test: `test/e2e/ssh_dispatch_e2e_test.dart`

**验的是什么：** 计划 1 的 `CommandDispatcher` 与计划 2 的 `SshSession` 能否串成完整链路。这是唯一能验证「命令真的发到了对端并被对端执行」的测试 —— 前面所有测试都停在这一步之前。

- [ ] **Step 1: 写端到端测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/command_dispatcher.dart';
import 'package:win_cli_tool/command/more_pager.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/connection/ssh_session.dart';
import 'package:win_cli_tool/models/device_profile.dart';

import '../fixtures/sshd_harness.dart';

void main() {
  final skipReason = SshdHarness.unavailableReason;
  late SshdHarness sshd;

  setUpAll(() async {
    if (skipReason == null) sshd = await SshdHarness.start();
  });

  tearDownAll(() async {
    if (skipReason == null) await sshd.stop();
  });

  test('命令经 SSH 下发、被对端执行、输出回流', () async {
    final session = SshSession(
      profile: DeviceProfile(
        id: 'd1',
        name: '本地 sshd',
        protocol: DeviceProtocol.ssh,
        host: '127.0.0.1',
        port: sshd.port,
        username: sshd.user,
        privateKeyPath: sshd.privateKeyPath,
        lineEnding: '\n',
      ),
      hostKeyStore: InMemoryHostKeyStore(),
      onUnknownHostKey: (h) async => true,
    );

    await session.connect();

    // 把提示符设成一个网络设备风格的串，让默认提示符正则能命中。
    final dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: PromptDetector(),
      morePager: MorePager(),
      lineEnding: '\n',
    );

    final output = StringBuffer();
    final events = <DispatchEvent>[];
    dispatcher.events.listen(events.add);

    session.output.listen((chunk) {
      output.write(chunk);
      dispatcher.onOutput(chunk);
    });

    // 先摆好提示符，再等它出现
    session.write("PS1='RTR> '\n");
    final settle = DateTime.now().add(const Duration(seconds: 10));
    while (!output.toString().contains('RTR> ') &&
        DateTime.now().isBefore(settle)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    dispatcher.enqueue(['echo E2E_MARKER', 'echo SECOND']);

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (events.whereType<QueueFinished>().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    // 两条命令都被对端真正执行了
    expect(output.toString(), contains('E2E_MARKER'));
    expect(output.toString(), contains('SECOND'));

    // 两条命令都正常完成（没有靠超时兜底）
    final completed = events.whereType<CommandCompleted>().toList();
    expect(completed.length, 2);
    expect(completed.every((c) => !c.timedOut), isTrue,
        reason: '提示符判定应该命中，不应走到超时');

    // 顺序正确
    expect(completed.map((c) => c.command).toList(),
        ['echo E2E_MARKER', 'echo SECOND']);

    await dispatcher.dispose();
    await session.close();
  }, skip: skipReason);
}
```

- [ ] **Step 2: 运行测试**

Run: `flutter test test/e2e/ssh_dispatch_e2e_test.dart`
Expected: PASS（或在本机无 sshd 时 skipped）

> **若 `timedOut` 为 true**：说明提示符没被识别。先确认 `PS1` 是否真的生效 —— 非交互式 shell 可能不读 `PS1`。这种情况下改用 `bash -i` 或直接把 `promptDetector` 换成一个能匹配对端实际提示符的正则，**不要**为了让测试变绿而放宽默认提示符正则（spec §13.9 明确禁止靠改正则回避问题）。

- [ ] **Step 3: 反证「串行下发」的非空性**

把 `CommandDispatcher.enqueue` 改成一次把所有命令都写出去（在 `_emitNext` 里循环写完整个队列），重跑：
Expected: 必须变红。若仍绿，说明这条 e2e 没有真正验证串行性。

改完恢复（这个变异只用于验证测试有效性，不进代码库）。

- [ ] **Step 4: 跑全量测试**

Run: `flutter test`
Expected: 全部 PASS（集成测试在无 sshd 环境为 skipped）

- [ ] **Step 5: 提交**

```bash
dart analyze
git add test/e2e/ssh_dispatch_e2e_test.dart
git commit -m "test: SSH 端到端 —— 命令下发、执行、输出回流"
```

---

## 收尾

- [ ] **更新 spec 的目录结构（§8.5）**，补上本计划新增的 5 个文件：

```bash
# 在 §8.5 的 connection/ 段落里补：
#   connection_socket.dart   Connection -> SSHSocket 适配器
#   known_host.dart          已知主机密钥模型与注入式接口
#   host_key_verifier.dart   主机密钥校验逻辑
#   connection_failure.dart  FR-C-06 失败原因分类
#   session_factory.dart     按协议构造会话
```

- [ ] **全量测试与分析**

```bash
flutter test && dart analyze
```

- [ ] **交给 finishing-a-development-branch 收尾**

---

## 未决项：`Session.done` 不带错误，断开原因在 Task 6 里被丢掉（**需要决策，阻塞 Task 6**）

Task 6 的 fence 是这样取失败原因的：

```dart
    session.done.then(
      (_) => _onSessionDone(),
      onError: (Object e, StackTrace _) => _onSessionDone(e),
    );
```

`_onSessionDone(error)` 里再 `SessionLost(classifyConnectionFailure(error))`。

**但 `Session.done` 永远不会以错误完成。** 两个实现都是：

- `telnet_session.dart:77-80`：`_onDisconnected([Object? _])` —— 形参直接写成 `_`，
  错误被丢掉；随后 `_done.complete()` 不带参数。
- Task 4 的 `SshSession._onDisconnected`：先 `if (error != null) _lastError = error;`，
  然后同样是 `_done.complete()`（不带参数）。

于是 `onError` 那条分支**永远不会执行**，`_onSessionDone()` 恒收到 `null`，
`SessionLost(null)` —— **失败原因一次都没到过界面**。这正是 §13.12 抱怨的形态
（「连接被重置」与「主机不可达」在调用方看来完全一样），只是往上挪了一层：
错误对象确实被 `SshSession.lastError` 留下了，但**没有任何人读它**。

`SshSession.lastError` 也救不了：`Session` 接口（`lib/connection/session.dart`）
上**没有** `lastError`，而 `ConnectionManager` 只认 `Session` 这个类型。

### 建议的修法

1. `Session` 接口加 `Object? get lastError;`。**要抽象成员，不要默认 `=> null`** ——
   默认值会让新的实现静默地返回 null，正是这类缺陷的温床。
2. `TelnetSession` 补上（三行：字段、getter、`_onDisconnected` 里先存再 `complete`），
   并加一条用例：喂一个 `addError` 之后 `await session.done` 必须**正常完成**，
   且 `lastError` 就是那个错误对象。
3. `SshSession` 的 getter 改成 `@override`（Task 4 已经有它）。
4. Task 6 的 fence 改成 `session.done.then((_) => _onSessionDone(session.lastError))`，
   并**删掉**那条死的 `onError` 分支 —— 或者保留但注明它只是防御性的。
   一条永远不会执行的错误分支比没有更糟：它读起来像"原因就是从这儿传下去的"。

### 为什么不让 `done` 直接以错误完成

那是最省事的写法，但每个 `await session.done` 的人都被迫处理这个错误，而
"为什么断的"是给用户看的诊断信息，不是控制流信号；无人监听的 `completeError`
还会变成未捕获的异步错误。§13.12 给的也正是这两个选项（「新增错误事件或
`lastError`」）。

**必须在 Task 6 实现之前落地。** 否则 Task 6 的单测会照常通过（它测的是
`SessionLost` 事件发出来了，不是它带了什么），而产品里断线原因永远是空的。
已同步记入 spec §13.20。

## 未决项：`failed`（红）在产品里何时可达（**需要决策，不阻塞 Task 1–5**）

FR-C-06 要求「连接失败时，设备按钮变红」，但本计划的 `ConnectionManager` 里 `autoReconnect` **默认 true、且没有任何生产代码传 false**（只有下面的测试传过） —— 也就是说 `failed` 这个状态在实际产品里**永远到不了**，红按钮不会被点亮。这与 FR-C-06 是冲突的。

冲突的根源是 spec 里两处口径不一致：

- **FR-D-09** 把颜色总结为「红=连接失败**或已断开**」；
- **§5.4** 的逐事件表却是：检测到断开→**黄**（重连中）、重连失败→**维持黄**、用户主动断开→**灰**。§5.4 表里**没有红**，也没有为「首次建连就失败」给出任何一行。

于是有两种读法，需要选一个（**本计划暂按第 1 种实现**，因为它与 §5.4 的逐事件表一致，而 §5.4 比 FR-D-09 的概述更具体）：

1. **首次建连失败也走退避重连**（当前实现：黄），`failed` 仅留给 `autoReconnect == false`。这样 FR-C-06 的红在 V1 里不出现，需要把 FR-C-06 的措辞改成「重连被关闭时」或明确「V1 暂不点亮红」。
2. **首次建连失败立即变红**（照 FR-C-06 字面），随后若仍要自动重连再转黄。这样 `_attempt == 0` 的失败分支要置 `failed` 而非 `reconnecting`，测试「连续建连失败按 1s -> 2s -> 4s 退避」的首次断言也要跟着改。

另外 `autoReconnect` 这个开关本身在 spec 里**没有依据**：FR-G-01 的设置项列表里没有「自动重连」开关，而 FR-C-07 又要求断线后必须自动重试。若选第 1 种读法，需要一个设置项来承载它（属于计划 5），否则这个参数应删除。

**这一项在 Task 6 实现前必须定下来。** 已同步记入 spec §13.17-3。

## 本计划**不**包含（属于计划 3）

- `JumpHostPool`、`SshTunnelConnector`、`connection_socket.dart` 之外的多跳组合
- `forwardLocal` / `direct-tcpip` 通道与 `SSHForwardChannel.destroy()`
- 跳板机断线导致的批量断线通知（FR-J-05 的跨设备部分）

计划 2 已经为这些留好了位置：`ConnectorResolver` 是注入点，`ConnectionSocket` 是可复用的适配器，`SshSession` 不需要任何改动。

## 已知未决项（不阻塞本计划）

- **spec §13.10 的翻页恢复方案**尚未选定（三个选项）。它影响 `CommandDispatcher` 与计划 5 的显示逻辑，**不影响计划 2**：`SshSession` 只把字节交给既有管线，不自己做提示符或翻页判定（§13.9 提到"SshSession 若也做翻页判定"—— 本计划的选择是**不做**，判定权仍归 `CommandDispatcher` 一处）。
- **FR-C-14（启动时自动连接）不在本计划**：`DeviceProfile.autoConnect` 字段已存在，但"应用启动后自动发起连接"是应用装配层的行为，属于计划 5（providers）。本计划提供的能力是 `ConnectionManager.connect()`，计划 5 在启动时对 `autoConnect == true` 的设备各调用一次即可。
- **用户主动断开时，命令队列不会发出任何队列事件。** `disconnect()` / `dispose()` 走的是 `dispatcher.dispose()`，它只静默清空队列，**不发** `QueueDropped` 也不发 `QueueAborted`（对比 `onDisconnected()` 会发 `QueueDropped`）。后果：若界面上还挂着"执行中 3/8"这类进度显示，主动断开时没有队列事件去清它。界面应当改用 `ConnectionStateChanged(disconnected)` 兜底清空。这不是缺陷，但**别留到计划 5 去发现** —— 已知信息，记在这里。
- **`you@example.com` 这个 git 作者**仍是占位值，推送前需处理。
