# SSH 会话与重连 实现计划（计划 2）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让工具能通过 SSH 连上设备并维持长连接 —— 包含主机密钥校验、可读的失败原因、断线自动重连，以及一次可选的并发模型改造（见 Task 0）。

**Architecture:** 在计划 1 已有的 `Connector`/`Connection` 传输抽象与 `Session` 会话抽象之上，新增三块：① `ConnectionSocket` 把我们的 `Connection` 适配成 dartssh2 的 `SSHSocket`（这一步是计划 3 跳板机能够复用同一份 `SshSession` 的前提）；② `SshSession` 用 dartssh2 申请 PTY shell，把输出接进既有 `Session` 契约；③ `ConnectionManager` 持有会话生命周期、指数退避重连与每设备的 `CommandDispatcher`。主机密钥的持久化通过**注入的** `HostKeyStore` 接口完成，计划 2 自己不写文件（spec §13.5）。

**Tech Stack:** Flutter 3.44.4 / Dart 3.12.2、`dartssh2` 4.1.0（已确认可解析）、`clock`（`ConnectionManager` 的时间源，见 Task 6）、`flutter_test`、`fake_async`。

---

## 执行前必读

### 本计划的三条硬约束（来自 spec §13，违反即为缺陷）

| 约束 | 出处 | 在本计划中的落点 |
|---|---|---|
| 转发 `session.done` 前必须查 `_closed` 标志 | §13.14-5 | Task 4 的 `_onDisconnected` |
| 始终显式传 `onVerifyHostKey`，不得留 `null` | §13.14-1 | Task 4 的 `SSHClient(...)` 构造 |
| 错误分类看 `.reason`，不看顶层类型或消息 | §13.15 | Task 3 的 `classifyConnectionFailure` |

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

- [ ] **Step 1: 创建 `lib/connection/connection_manager.dart`，只放状态枚举与事件类型**

```dart
import 'connection_failure.dart';
import 'session.dart';

/// 一台设备的连接状态。与 spec §5.4 的按钮颜色一一对应。
///
/// 颜色映射（供计划 5 使用）：disconnected→灰、connecting→黄、
/// connected→绿、reconnecting→黄、failed→红。
enum DeviceConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,

  /// 连接失败且不再自动重试（用户主动断开，或重连被关闭）。
  failed;

  /// 该状态下设备按钮是否应显示为"有连接"。重连中算"没有连接"——
  /// 此时发给设备的命令会失败，界面必须让用户看出来。
  bool get isLive => this == DeviceConnectionState.connected;
}

sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// 状态迁移。界面据此更新按钮颜色与输出区提示。
class ConnectionStateChanged extends ConnectionEvent {
  const ConnectionStateChanged(this.state);

  final DeviceConnectionState state;
}

/// 会话已就绪（首次连接或重连成功），可以下发命令了。
class SessionReady extends ConnectionEvent {
  const SessionReady(this.session);

  final Session session;
}

/// 即将在 [delay] 之后发起第 [attempt] 次重连（从 1 开始）。
class ReconnectScheduled extends ConnectionEvent {
  const ReconnectScheduled(this.attempt, this.delay);

  final int attempt;
  final Duration delay;
}

/// 重连成功。FR-C-09 要求输出区插入醒目分隔标记，[downtime] 即断线时长。
class Reconnected extends ConnectionEvent {
  const Reconnected(this.downtime, this.attempt);

  final Duration downtime;
  final int attempt;
}

/// 连接失败。[failure] 携带可读原因（FR-C-06）。
class ConnectionFailed extends ConnectionEvent {
  const ConnectionFailed(this.failure);

  final ConnectionFailure failure;
}

/// 会话断开。未发出的命令已被丢弃（FR-C-10）。
class SessionLost extends ConnectionEvent {
  const SessionLost(this.failure);
    
  final ConnectionFailure? failure;
}
```

- [ ] **Step 2: 运行分析器确认无错**

Run: `dart analyze lib/connection/connection_manager.dart`
Expected: 只有 `connection_failure.dart` 尚不存在导致的 import 错误 —— 这是预期的，Task 3 会创建它。若报其他错误（尤其是"未使用的 import"）则修正。

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
  var closed = false;

  @override
  Stream<List<int>> get input => _input.stream;

  void feed(List<int> bytes) {
    if (closed) return;
    _input.add(bytes);
  }

  Future<void> feedDone() => _input.close();

  @override
  void write(List<int> data) => written.addAll(data);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(_input.close());
  }
}

void main() {
  test('对端字节从 socket.stream 出来，且是 Uint8List', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    final got = <int>[];
    socket.stream.listen(got.addAll);

    conn.feed([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);

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

  test('destroy() 关闭底层 Connection', () async {
    final conn = _FakeConnection();
    final socket = ConnectionSocket(conn);

    socket.destroy();
    await Future<void>.delayed(Duration.zero);

    expect(conn.closed, isTrue);
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

    conn._input.addError(const SocketException('连接被重置'));
    await Future<void>.delayed(Duration.zero);

    expect(caught, isA<SocketException>());
  });
}
```

> 测试里用到 `SocketException`，需在文件顶部加 `import 'dart:io';`。

- [ ] **Step 3: 运行测试确认失败**

Run: `flutter test test/connection/connection_socket_test.dart`
Expected: 编译失败 —— `Target of URI doesn't exist: 'package:win_cli_tool/connection/connection_socket.dart'`

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
      onError: (Object _) {},
      onDone: () => unawaited(_conn.close()),
    );
  }

  final Connection _conn;
  final _stream = StreamController<Uint8List>();
  final _sink = StreamController<List<int>>();
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
  /// 无人监听时永久挂起（spec §13.11）。
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
Expected: 6 个用例全部 PASS

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

void main() {
  test('往返 JSON 一致', () {
    final k = KnownHost(
      host: '10.0.0.1',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:abc123',
    );

    final back = KnownHost.fromJson(k.toJson());

    expect(back.host, '10.0.0.1');
    expect(back.port, 22);
    expect(back.keyType, 'ssh-ed25519');
    expect(back.fingerprint, 'SHA256:abc123');
  });

  test('identity 由 host/port/keyType 三者共同决定', () {
    final a = KnownHost(
      host: 'h',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:x',
    );
    final b = KnownHost(
      host: 'h',
      port: 22,
      keyType: 'ssh-rsa',
      fingerprint: 'SHA256:y',
    );

    // 同一主机、不同算法 → 身份证不同，因此互不覆盖，
    // 也不会把算法变更误报成"密钥变了"。
    expect(a.identity, isNot(b.identity));
  });

  test('同一主机同一算法重新保存会覆盖（identity 相同）', () {
    final a = KnownHost(
      host: 'h',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:old',
    );
    final b = KnownHost(
      host: 'h',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:new',
    );

    expect(a.identity, b.identity);
  });

  test('指纹为 null 以外的空串是非法值，构造时拒绝', () {
    // 空指纹会让"指纹不匹配"永远为真，从而把每一次连接都判成
    // 主机密钥变更 —— 必须在这里挡住，而不是让它在比较时才发作。
    expect(
      () => KnownHost(
        host: 'h',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: '',
      ),
      throwsArgumentError,
    );
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/connection/known_host_test.dart`
Expected: 编译失败 —— `Target of URI doesn't exist`

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
  }

  final String host;
  final int port;

  /// 主机密钥算法名，如 `ssh-ed25519` / `rsa-sha2-256`。
  final String keyType;

  /// 形如 `SHA256:<base64>`，dartssh2 直接给出，无需自己算。
  final String fingerprint;

  /// 记录的唯一标识。**必须包含 keyType** —— 同一主机同时提供多种算法时，
  /// 每把密钥的指纹都不同，只按 host:port 存会把正常的算法协商误报成
  /// 主机密钥变更（见本 Task 开头的说明）。
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
}

/// 内存实现，供测试与"不持久化"的场景使用。
class InMemoryHostKeyStore implements HostKeyStore {
  final _byIdentity = <String, KnownHost>{};

  /// 已保存记录的快照，供断言。
  List<KnownHost> get all => List.unmodifiable(_byIdentity.values);

  @override
  Future<KnownHost?> find(String host, int port, String keyType) async =>
      _byIdentity['$host:$port:$keyType'];

  @override
  Future<void> save(KnownHost host) async {
    _byIdentity[host.identity] = host;
  }
}
```

> `package:meta` 是 Flutter 的传递依赖，`@immutable` 可直接使用；若分析器报未声明依赖，改为 `flutter pub add meta`。

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/connection/known_host_test.dart`
Expected: 4 个用例全部 PASS

- [ ] **Step 5: 提交**

```bash
dart analyze lib/connection/known_host.dart test/connection/known_host_test.dart
git add lib/connection/known_host.dart test/connection/known_host_test.dart pubspec.yaml
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
    test('连接超时', () {
      final f = classifyConnectionFailure(
        TimeoutException('timed out'),
      );
      expect(f.kind, ConnectionFailureKind.timeout);
    });

    test('主机不可达（SocketException，拒绝连接）', () {
      final f = classifyConnectionFailure(
        const SocketException('Connection refused'),
      );
      expect(f.kind, ConnectionFailureKind.unreachable);
    });

    test('认证失败（所有认证方式都试过了）', () {
      final f = classifyConnectionFailure(SSHAuthFailError('all failed'));
      expect(f.kind, ConnectionFailureKind.authFailed);
    });

    test('协议错误（握手失败）', () {
      final f = classifyConnectionFailure(
        SSHHandshakeError('Invalid version: HTTP/1.1 200 OK'),
      );
      expect(f.kind, ConnectionFailureKind.protocolError);
    });

    test('跳板机失败会指明是第几跳', () {
      final f = classifyConnectionFailure(
        const SocketException('Connection refused'),
        hop: const JumpHop(index: 1, name: '堡垒机-A'),
      );
      expect(f.kind, ConnectionFailureKind.jumpHostFailed);
      expect(f.message, contains('第 1 跳'));
      expect(f.message, contains('堡垒机-A'));
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
          SSHInternalError(StateError('Bad state: No matching key exchange algorithm')),
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
          SSHInternalError(StateError('Bad state: No matching key exchange algorithm')),
        ),
      );

      // 两者的异常类型与 toString 完全相同，唯一区别在 .reason。
      expect(hostkey.kind, isNot(algo.kind));
    });

    test('认不出的 reason 优雅降级为 protocolError 并附上原文', () {
      final f = classifyConnectionFailure(
        SSHAuthAbortError('boom', SSHInternalError(StateError('something new'))),
      );
      expect(f.kind, ConnectionFailureKind.protocolError);
      expect(f.message, contains('something new'));
    });
  });

  group('message 必须是可读中文，且带原始信息', () {
    test('每种 kind 都有非空的中文说明', () {
      for (final e in <Object>[
        TimeoutException('t'),
        const SocketException('r'),
        SSHAuthFailError('a'),
        SSHHandshakeError('h'),
      ]) {
        final f = classifyConnectionFailure(e);
        expect(f.message, isNotEmpty);
        expect(f.message, isNot(contains('null')));
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
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/connection/connection_failure_test.dart`
Expected: 编译失败 —— `Target of URI doesn't exist`

- [ ] **Step 3: 实现**

```dart
import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

/// 失败原因分类。前五项对应 FR-C-06 列举的原因，[hostKey] 是 §13.15
/// 要求单独区分出来的项。
enum ConnectionFailureKind {
  /// 连接超时（FR-C-13，默认 15s）。
  timeout,

  /// 认证失败：口令或密钥不对。
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
  final String message;

  /// 原始异常对象。用于日志与排查，不展示给用户。
  final Object? cause;

  @override
  String toString() => 'ConnectionFailure(${kind.name}): $message';
}

/// 把任意异常归类成 [ConnectionFailure]。
///
/// **判据是 `SSHAuthAbortError.reason`，不是顶层类型或消息文本** ——
/// 主机密钥被拒与算法协商失败抛出的异常类型与 toString 完全相同
/// （spec §13.15），只有 reason 不同。
ConnectionFailure classifyConnectionFailure(Object error, {JumpHop? hop}) {
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
  if (error is TimeoutException) {
    return ConnectionFailure(
      ConnectionFailureKind.timeout,
      '连接超时：目标设备在超时时间内没有响应',
      cause: error,
    );
  }

  // SSHAuthAbortError 必须在 SSHAuthError 之前判 —— 它是子类。
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
      return ConnectionFailure(
        ConnectionFailureKind.protocolError,
        '协议错误：与该设备协商加密参数失败。'
        '常见原因是设备只提供已被淘汰的 SSH 算法'
        '（ssh-rsa/SHA-1、aes-cbc、hmac-md5 等），V1 暂不支持。'
        '原始信息：${reason.error}',
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
    return ConnectionFailure(
      ConnectionFailureKind.unreachable,
      '主机不可达：${error.osError?.message ?? error.message}',
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
Expected: 12 个用例全部 PASS

- [ ] **Step 5: 反证测试的非空性（本计划的强制步骤）**

把 `_classify` 里 `if (reason is SSHHostkeyError)` 这一支删掉，重跑：

Run: `flutter test test/connection/connection_failure_test.dart`
Expected: **必须变红**，且失败的是「主机密钥被用户拒绝 → hostKey」与「两者必须分类不同」两条。

若删掉后仍然全绿，说明这两条测试没有约束任何行为，必须重写。改完记得恢复代码。

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

**三个必须照做的点（写错任何一个都会静默出错）：**

1. `_closed` 必须在关 `client` **之前**置位 —— 否则 `client.close()` 完成的 `session.done` 会被当成一次意外断线，导致退出应用时每台设备触发一次自动重连（§13.14-5）。
2. `onVerifyHostKey` 必须**始终**显式传，即便校验被全局关闭（§13.14-1）。
3. `stdout` 必须 `.cast<List<int>>()` 后才能 `.transform(Utf8Decoder())`（协变陷阱）。

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  test('从未连上的会话，close() 必须能返回（不能永久挂起）', () async {
    // spec §13.11：单订阅 controller 的 close() 在无人监听时永不完成。
    // 这条路径就是"连不上之后清理"，挂在这里应用就退不掉。
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
    // 这里断言 SshSession 不会把 null 传下去 —— 用"校验关闭"的场景来测，
    // 因为那是最容易被写成"干脆不传"的路径。
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

}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/connection/ssh_session_test.dart`
Expected: 编译失败 —— `Target of URI doesn't exist`

- [ ] **Step 3: 实现**

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/device_profile.dart';
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

  /// 供测试断言"回调确实被传下去了"。见 Task 4 的测试说明。
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
      identities: _identities(),
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

  List<SSHIdentity>? _identities() {
    final path = profile.privateKeyPath;
    if (path == null || path.isEmpty) return null;
    final pem = File(path).readAsStringSync();
    // 这里不处理带口令的私钥：口令要从凭据接口取，属于计划 4。
    return SSHKeyPair.fromPem(pem);
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

    // 不 await：单订阅 controller 无监听者时 close() 永不完成（§13.11）。
    unawaited(_output.close());
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/connection/ssh_session_test.dart`
Expected: 5 个用例全部 PASS

- [ ] **Step 5: 反证测试的非空性**

把 `close()` 里的 `_closed = true;` 挪到方法**末尾**，并临时加一个能连上的假会话跑一遍 —— 或者更直接地对 `_onDisconnected` 的守卫做变异：删掉 `if (_closed) return;` 一行。

Run: `flutter test test/connection/`
Expected: 必须先看到**新增的失败**。若仍全绿，说明守卫没有被任何测试覆盖 —— Task 7 的集成测试会补上这条（它用真 sshd，能真实走完 close 路径）。

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
Expected: 编译失败 —— `Target of URI doesn't exist`

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

**本类的三个所有权/健壮性要点（都是预演中改出来的，不要改回去）：**

1. **`_dispatcherSub` 必须被保存并取消。** 订阅别人的广播流却不接住返回的订阅对象，等于把生命周期交给运气。
2. **`_teardownSession()` 在任何 `await` 之前先把所有字段取走并置空。** 否则慢的那次拆除会在 `await` 之后把**新会话**的 `_outputSub` / `_dispatcher` 置空 —— 重连与拆除交叠时必然发生。
3. **`_teardownSession()` 不 `await dispatcher.dispose()`。** 它是广播 `StreamController`，`close()` 的 future 要等订阅者全部摘干净才完成，而订阅者不止我们（界面会直接订阅 `dispatcher.events`）。把 `session.close()` 挂在它后面，就等于让 FR-C-12 依赖一个我们控制不了的 future。`dispose()` 的同步部分（`_disposed = true`、清空队列）立即生效，所以 fire-and-forget 不会再发出任何命令。同理，建连失败分支里也是 `unawaited(_teardownSession())` —— 拆除是清理，不能挡住重连排程。

- [ ] **Step 1: 写失败测试**

```dart
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/command_dispatcher.dart';
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
  _FakeSession(this.profile, {this.failConnect = false});

  final DeviceProfile profile;
  final bool failConnect;
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
    if (failConnect) throw const _ConnectFailed();
  }

  @override
  void write(String text) => written.add(text);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
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
  _FakeFactory(this.sessions, {this.failConnect = false});

  final List<_FakeSession> sessions;

  /// 可中途翻转：测试"先失败若干次、再连上"的场景。
  bool failConnect;

  var created = 0;

  @override
  Session create(DeviceProfile profile) {
    created++;
    final s = _FakeSession(profile, failConnect: failConnect);
    sessions.add(s);
    return s;
  }

  @override
  HostKeyStore get hostKeyStore => InMemoryHostKeyStore();

  @override
  ConnectorResolver get connectorResolver => (p) => throw UnimplementedError();

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
        expect(factory.created, i + 1,
            reason: '第 ${i + 1} 次重连不得早于 ${schedule[i]}s');

        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(factory.created, i + 2,
            reason: '第 ${i + 1} 次重连应在 ${schedule[i]}s 后发生');
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
      expect(dropped, [4],
          reason: '要报出被丢弃的命令数（含在途的那条）');

      // 重连成功后，被丢弃的命令**不得**被重放
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(sessions[1].written, ['enable\n'],
          reason: '只应有登录后命令，被丢弃的命令不得重放');

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
    expect(sessions.single.written, before,
        reason: 'FR-C-12：退出时不得发送任何命令');

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
enum DeviceConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,

  /// 连接失败且不再自动重试（用户主动断开，或重连被关闭）。
  failed;

  /// 该状态下设备按钮是否应显示为"有连接"。重连中算"没有连接"——
  /// 此时发给设备的命令会失败，界面必须让用户看出来。
  bool get isLive => this == DeviceConnectionState.connected;
}

sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// 状态迁移。界面据此更新按钮颜色与输出区提示。
class ConnectionStateChanged extends ConnectionEvent {
  const ConnectionStateChanged(this.state);

  final DeviceConnectionState state;
}

/// 会话已就绪（首次连接或重连成功），可以下发命令了。
class SessionReady extends ConnectionEvent {
  const SessionReady(this.session);

  final Session session;
}

/// 即将在 [delay] 之后发起第 [attempt] 次重连（从 1 开始）。
class ReconnectScheduled extends ConnectionEvent {
  const ReconnectScheduled(this.attempt, this.delay);

  final int attempt;
  final Duration delay;
}

/// 重连成功。FR-C-09 要求输出区插入醒目分隔标记，[downtime] 即断线时长。
class Reconnected extends ConnectionEvent {
  const Reconnected(this.downtime, this.attempt);

  final Duration downtime;
  final int attempt;
}

/// 连接失败。[failure] 携带可读原因（FR-C-06）。
class ConnectionFailed extends ConnectionEvent {
  const ConnectionFailed(this.failure);

  final ConnectionFailure failure;
}

/// 会话断开。未发出的命令已被丢弃（FR-C-10）。
class SessionLost extends ConnectionEvent {
  const SessionLost(this.failure);
    
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
  StreamSubscription<DispatchEvent>? _dispatcherSub;
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

    _setState(_attempt == 0
        ? DeviceConnectionState.connecting
        : DeviceConnectionState.reconnecting);

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

    _outputSub = session.output.listen(
      (chunk) {
        if (!_output.isClosed) _output.add(chunk);
        _dispatcher?.onOutput(chunk);
      },
      onError: (Object _) {},
    );

    _dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: promptDetector ?? PromptDetector(),
      morePager: morePager ?? MorePager(),
      lineEnding: profile.lineEnding,
    );
    _dispatcherSub = _dispatcher!.events.listen((e) {
      // 命令队列的事件由界面直接消费 dispatcher.events；
      // 这里只订阅以便队列在断线时被正确清空。
      if (e is QueueDropped && !_events.isClosed) {
        _events.add(SessionLost(null));
      }
    });

    session.done.then((_) => _onSessionDone(), onError: (Object e, StackTrace _) {
      _onSessionDone(e);
    });

    final wasReconnect = _attempt > 0;
    if (wasReconnect) {
      // 用 clock.now() 而不是 DateTime.now()：fake_async 推进的是 clock，
      // 用真实时间会让 FR-C-09 的断线时长在测试里恒为 0。
      final downtime = clock.now().difference(_disconnectedAt);
      if (!_events.isClosed) _events.add(Reconnected(downtime, _attempt));
    }
    if (!_events.isClosed) _events.add(SessionReady(session));

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
      _events.add(SessionLost(error == null ? null : classifyConnectionFailure(error)));
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed || _userClosed || !autoReconnect) {
      _setState(DeviceConnectionState.failed);
      return;
    }

    _setState(DeviceConnectionState.reconnecting);
    _attempt++;

    // 超出序列时用最后一项（封顶，FR-C-07）。
    final delay = backoff[
        _attempt - 1 < backoff.length ? _attempt - 1 : backoff.length - 1];

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
    final dispatcherSub = _dispatcherSub;
    final dispatcher = _dispatcher;
    _session = null;
    _outputSub = null;
    _dispatcherSub = null;
    _dispatcher = null;

    // 我们自己挂的订阅，先摘掉。
    unawaited(dispatcherSub?.cancel() ?? Future<void>.value());
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
Expected: 9 个用例全部 PASS

- [ ] **Step 5: 反证六个承载行为的非空性（逐个做，每个都要看到红）**

计划 1 的教训是"全绿"不等于"被约束"。下表每一条都是把缺陷**放回去**，确认对应测试确实变红；不变红就说明那条测试是空的。每改一条立刻恢复，最后 `git diff` 确认工作区干净再提交。

| # | 把缺陷放回去 | 必须变红的测试 |
|---|---|---|
| M1 | `_scheduleRetry` 里 `final delay = backoff[...]` 改成 `backoff[0]`（退避不再升级） | 连续建连失败按 1s -> 2s -> 4s 退避 |
| M2 | `_attemptConnect` 成功分支里删掉 `_attempt = 0;`（连上后不归零） | 连上一次之后退避归零 |
| M3 | `disconnect()` 里把 `_setState(disconnected)` 挪到 `await _teardownSession()` **之后** | 用户主动断开不触发重连 |
| M4 | `_teardownSession` 里删掉 `await session.close();` | dispose() 关闭会话（FR-C-12） |
| M5 | `_onSessionDone` 里删掉 `_dispatcher?.onDisconnected();` | 断线时未发出的命令被丢弃（FR-C-10） |
| M6 | `onDisconnected` 里 `_queue.length + (_current != null ? 1 : 0)` 改成只算 `_queue.length` | 同上（丢弃数漏算在途的那条） |

已实测：M1–M6 全部变红。

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

## 本计划**不**包含（属于计划 3）

- `JumpHostPool`、`SshTunnelConnector`、`connection_socket.dart` 之外的多跳组合
- `forwardLocal` / `direct-tcpip` 通道与 `SSHForwardChannel.destroy()`
- 跳板机断线导致的批量断线通知（FR-J-05 的跨设备部分）

计划 2 已经为这些留好了位置：`ConnectorResolver` 是注入点，`ConnectionSocket` 是可复用的适配器，`SshSession` 不需要任何改动。

## 已知未决项（不阻塞本计划）

- **spec §13.10 的翻页恢复方案**尚未选定（三个选项）。它影响 `CommandDispatcher` 与计划 5 的显示逻辑，**不影响计划 2**：`SshSession` 只把字节交给既有管线，不自己做提示符或翻页判定（§13.9 提到"SshSession 若也做翻页判定"—— 本计划的选择是**不做**，判定权仍归 `CommandDispatcher` 一处）。
- **FR-C-14（启动时自动连接）不在本计划**：`DeviceProfile.autoConnect` 字段已存在，但"应用启动后自动发起连接"是应用装配层的行为，属于计划 5（providers）。本计划提供的能力是 `ConnectionManager.connect()`，计划 5 在启动时对 `autoConnect == true` 的设备各调用一次即可。
- **`you@example.com` 这个 git 作者**仍是占位值，推送前需处理。
