import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/command_dispatcher.dart';
import 'package:win_cli_tool/command/more_pager.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';
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

  /// 断开原因。默认 null；[drop] 可以先把它置上。**刻意是可置值的字段，不是恒
  /// 返回 null 的桩** —— "失败了但不知道为什么"正是 §13.20 那个缺陷的形状。
  @override
  Object? lastError;

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
    // **刻意不关 `_output` —— 这一点与两个真实实现都不一样，是故意的。**
    //
    // `Session` 的契约（session.dart）**没有**承诺 `close()` 会结束 `output`。两个
    // 真实实现恰好都这么做（`_onDisconnected` 里 `_output.close()`），但那是这两个
    // 具体类的实现细节，不是契约。夹具照抄这个细节的代价是**一条恒真的断言**：
    // broadcast controller 的 `isClosed` 在 `close()` 之后**同步**变成 true，于是
    // `emit` 里那个门把 stale chunk 直接丢掉 ——「被替换掉的会话不得再往 `mgr.output`
    // 里灌数据」（I5a 下半段）想看的"订阅有没有被摘掉"根本没被看见，它只可能作为
    // `closed == true` 的重述而失败。实测：把 `_teardownSession()` 里那句
    // `await outputSub?.cancel();` 删掉，**26/26 全绿**。
    //
    // 夹具不关 output 之后，manager 的订阅所有权（它自己那句 `await outputSub?.cancel();`）
    // 才真的被钉住：cancel 在 ⇒ stale chunk 到不了界面；cancel 不在 ⇒ 到得了、断言变红。
    // manager 本来就不该依赖"两个具体类的 `close()` 顺手关了 output"这件没写进契约的事。
    // **不要"修回去"。**
  }

  /// 模拟对端断开。[error] 给出时先记进 [lastError] —— 与两个真实实现里
  /// `_onDisconnected` 的"先存再 `complete()`"保持同一顺序（§13.20）。
  void drop([Object? error]) {
    if (error != null) lastError = error;
    if (!_done.isCompleted) _done.complete();
  }

  void emit(String s) {
    // 不设 `isClosed` 门：夹具的 `_output` 从不由 `close()` 关掉（见上），门恒真，
    // 留着只会让"有人把 `close()` 里那行 `_output.close()` 修回去"变成一次**静默的
    // 空操作** —— 而那正是本文件当初那条断言恒真的原因。去掉门之后，同样的手笔会
    // 让这里直接抛 `StateError`，点名用例，红得响亮。
    _output.add(s);
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

/// 夹具的两个默认值，与生产默认值的关系**一同一不同**，别一概而论：
///
/// - `lineEnding` 默认 `'\n'`，与 `DeviceProfile.lineEnding` 的生产默认值**一致**
///   （lib/models/device_profile.dart）；
/// - `postLogin` 默认单条 `['enable']`，而 `DeviceProfile.postLoginCommands` 的生产
///   默认值是 **`const []`**（同一个文件），两者**刻意不同**：除 I2 那条显式传两条的
///   用例之外，所有用例都要让"连上后自动下发"这条路径真的跑起来，用生产默认值
///   （空列表）它们就全都断言不到 FR-C-08 了。
///
/// 两个参数都只在用例显式传值时才取别的值。而"夹具的值恰好等于实现里硬编码的那个
/// 值"这个洞，由 I2 的『登录后命令是多条时全部依次下发』堵住：它显式传
/// `['enable', 'configure terminal']`，实现里若把登录后命令写死成 `['enable']`，
/// 那条立刻变红。
DeviceProfile _profile({
  List<String> postLogin = const ['enable'],
  String lineEnding = '\n',
}) => DeviceProfile(
  id: 'd1',
  name: '核心交换机',
  protocol: DeviceProtocol.ssh,
  host: '10.0.0.1',
  port: 22,
  username: 'admin',
  postLoginCommands: postLogin,
  lineEnding: lineEnding,
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
      // FR-C-06（决策②）：**首次失败当场变红**，退避继续排。
      expect(
        mgr.state,
        DeviceConnectionState.failed,
        reason: '第一次就连不上时按钮必须是红的，不是黄的',
      );

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

      // 这里不再断言 `SessionLost.isNotEmpty`：本用例要钉的是**丢弃数**，
      // 而"事件发了"既不能证明条数、也不能证明它带上了什么（§13.20 那条
      // 缺陷正是一个 `isNotEmpty` 放过去的）。条数由下面这行钉，
      // "一次断线一个事件"由专门的用例钉。

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

  test('SessionLost 必须带上断开原因（§13.20）—— 事件发了不等于原因到了', () {
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

      // 刻意用**非 const** 调用：`const _ConnectFailed()` 会被规范化，
      // 两个字面量是同一个对象，`same()` 就恒真、什么也钉不住。
      final reason = _ConnectFailed();
      sessions[0].drop(reason);
      async.flushMicrotasks();

      expect(lost, hasLength(1));
      // §13.20 的缺陷形状：`session.done` 完成时读不到原因，于是 `SessionLost`
      // 带着 `null` 出去 —— 事件照发、界面拿到"原因不明"。只断言 `isNotEmpty`
      // 看不出来这件事，上一条用例正是这样。
      expect(lost.single.failure, isNotNull, reason: 'SessionLost 必须带上原因');
      expect(
        lost.single.failure!.cause,
        same(reason),
        reason: '原因必须就是会话报上来的那个对象',
      );
      expect(
        lost.single.failure!.message,
        contains('connect failed'),
        reason: '原因要能被翻译成给用户看的中文',
      );

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
      //
      // 断言的是**精确值**，不是 `inSeconds == 1`：后者会把 [1s, 2s) 全放过去，
      // 1.9s 的断线时长照样算"1 秒"。`_disconnectedAt` 与重连定时器是在同一个
      // 假时刻落下的（都是 drop 之后那个 microtask），所以差值是精确的 1s。
      expect(reconnected.downtime, const Duration(seconds: 1));
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

      // 红（failed）在默认配置下也到得了 —— 见上面那条断言。这里断的是
      // autoReconnect=false 时**停**在红：不排程重连，所以一直红着。
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

  // ---- 入口管线（C1）：`output` 是界面唯一被允许订阅的输出通道 ----

  test('会话输出经 mgr.output 转发，且跨重连连续（C1）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: _FakeFactory(sessions),
      );

      // 界面只订阅这一个流，且在第一次连接**之前**就订阅了 —— 重连不会
      // 让它重新订阅，所以它必须在新会话上继续有效。
      final received = <String>[];
      mgr.output.listen(received.add);

      mgr.connect();
      async.flushMicrotasks();

      sessions[0].emit('Switch>');
      async.flushMicrotasks();
      expect(received, ['Switch>'], reason: '设备输出必须转发到 mgr.output');

      // 断线重连：Session 对象被整个替换。
      sessions[0].drop();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(sessions.length, 2, reason: '应已重连');

      sessions[1].emit('reconnected output');
      async.flushMicrotasks();
      expect(
        received,
        ['Switch>', 'reconnected output'],
        reason: '同一个订阅必须继续收到**新**会话的输出 —— 否则重连后输出区永久静止',
      );

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('提示符回送时命令完成、队列继续下发（C1 / FR-C-04）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: _FakeFactory(sessions),
      );

      final completed = <CommandCompleted>[];
      final finished = <QueueFinished>[];

      mgr.connect();
      async.flushMicrotasks();

      final dispatcher = mgr.dispatcher!;
      dispatcher.events.listen((e) {
        if (e is CommandCompleted) completed.add(e);
        if (e is QueueFinished) finished.add(e);
      });

      // 'enable'（登录后命令）已写出、在途；这两条排在它后面等着。
      dispatcher.enqueue(['show version', 'show run']);
      expect(sessions[0].written, ['enable\n']);

      // `_dispatcher?.onOutput` 是把设备输出送进判定器的**唯一**入口：
      // 少了它，任何命令都不会在提示符上完成，只会一条条跑到 10s 超时。
      sessions[0].emit('Switch# ');
      async.elapse(const Duration(milliseconds: 200));
      async.flushMicrotasks();

      expect(
        completed.map((e) => e.command),
        ['enable'],
        reason: '提示符必须让在途命令完成，而不是等超时',
      );
      expect(completed.single.timedOut, isFalse, reason: '这是提示符判定，不是超时');
      expect(
        sessions[0].written,
        ['enable\n', 'show version\n'],
        reason: '一条完成后必须写下一条',
      );

      // 队列继续走完。
      for (var i = 0; i < 2; i++) {
        sessions[0].emit('Switch# ');
        async.elapse(const Duration(milliseconds: 200));
        async.flushMicrotasks();
      }

      expect(completed.map((e) => e.command), ['enable', 'show version', 'show run']);
      expect(finished, hasLength(1), reason: '三条都完成后队列结束');

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  // ---- 界面消费的事件（I1）----

  test('状态迁移经 ConnectionStateChanged 送达界面，含主动断开（§5.4 / I1）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: _FakeFactory(sessions),
      );

      final states = <DeviceConnectionState>[];
      mgr.events.listen((e) {
        if (e is ConnectionStateChanged) states.add(e.state);
      });

      mgr.connect();
      async.flushMicrotasks();

      // 断线：黄（重连中）→ 绿（重连成功）
      sessions[0].drop();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      // 用户主动断开：灰
      mgr.disconnect();
      async.flushMicrotasks();

      // §5.4 的按钮颜色全部映射在这条事件流上：只断言 `mgr.state`（内部字段）
      // 看不见"值有没有送到界面"，缺一环按钮颜色就是错的。
      expect(
        states,
        [
          DeviceConnectionState.connecting,
          DeviceConnectionState.connected,
          // FR-C-06（决策②）：掉线时 `_attempt` 是 0（上次连接成功时归的零），
          // 所以先红；1s 后重连定时器醒来，`_attemptConnect` 看到 `_attempt == 1`，
          // 于是这一格是**黄**（重连中）而不是灰/红。
          DeviceConnectionState.failed,
          DeviceConnectionState.reconnecting,
          DeviceConnectionState.connected,
          DeviceConnectionState.disconnected,
        ],
        reason: '每次状态迁移都必须发事件（含主动断开那一次）',
      );
      expect(states.last, mgr.state);

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('重连后 SessionReady 再发一次，且带的是新的 dispatcher（I1）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: _FakeFactory(sessions),
      );

      final ready = <SessionReady>[];
      mgr.events.listen((e) {
        if (e is SessionReady) ready.add(e);
      });

      mgr.connect();
      async.flushMicrotasks();
      expect(ready, hasLength(1), reason: '首次连上要报一次');
      final first = ready.single.dispatcher;

      sessions[0].drop();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      // 界面靠这条事件重新订阅 `dispatcher.events`。少了它，重连之后
      // 命令输出与 QueueDropped 都不会再到达界面，而按钮是绿的。
      expect(ready, hasLength(2), reason: '每次连上都要报一次');
      expect(
        ready.last.dispatcher,
        isNot(same(first)),
        reason: '每次重连都新建 CommandDispatcher，界面必须重订阅',
      );
      expect(ready.last.dispatcher, same(mgr.dispatcher));

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('ReconnectScheduled 带上第几次与等多久（FR-C-07 的可见形式）（I1）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final factory = _FakeFactory(sessions, failConnect: true);
      final mgr = ConnectionManager(profile: _profile(), factory: factory);

      final scheduled = <ReconnectScheduled>[];
      mgr.events.listen((e) {
        if (e is ReconnectScheduled) scheduled.add(e);
      });

      mgr.connect();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();

      // FR-C-07 要求界面能显示"X 秒后重连"，这条事件是它唯一的数据源。
      expect(scheduled.map((e) => e.attempt), [1, 2, 3]);
      expect(scheduled.map((e) => e.delay), [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  // ---- 夹具值与实现里的硬编码重合（I2）----

  test('登录后命令是多条时全部依次下发（FR-C-08 / I2）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(postLogin: ['enable', 'configure terminal']),
        factory: _FakeFactory(sessions),
      );

      mgr.connect();
      async.flushMicrotasks();
      expect(sessions[0].written, ['enable\n'], reason: '先发第一条');

      sessions[0].emit('Switch# ');
      async.elapse(const Duration(milliseconds: 200));
      async.flushMicrotasks();

      // 只发第一条的话，第二台以上的设备永远进不了配置模式 —— 且没有任何
      // 报错（FR-C-08 要求"依次下发"）。
      expect(
        sessions[0].written,
        ['enable\n', 'configure terminal\n'],
        reason: '整个列表都要下发，不能只发第一条',
      );

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('会话拿到的是这台设备的 profile（host/id/username 不得串台）（I2）', () async {
    final profile = _profile(postLogin: ['enable', 'show clock']);
    final sessions = <_FakeSession>[];
    final mgr = ConnectionManager(
      profile: profile,
      factory: _FakeFactory(sessions),
    );

    await mgr.connect();

    expect(
      sessions.single.profile,
      same(profile),
      reason: '交给工厂的必须是 manager 自己的那个 profile',
    );
    expect(sessions.single.profile.id, 'd1');
    expect(sessions.single.profile.host, '10.0.0.1');
    expect(sessions.single.profile.username, 'admin');

    await mgr.dispose();
  });

  // ---- 行尾符与两个注入的判定器（I3）----

  test('DeviceProfile.lineEnding 真的到了线上（老设备要 \\r\\n）（I3）', () async {
    final sessions = <_FakeSession>[];
    final mgr = ConnectionManager(
      profile: _profile(lineEnding: '\r\n'),
      factory: _FakeFactory(sessions),
    );

    await mgr.connect();

    // 行尾符配错时设备什么都不执行，而界面看不出任何异常。
    expect(
      sessions.single.written,
      ['enable\r\n'],
      reason: '行尾符配成 \\r\\n 就必须发 \\r\\n',
    );

    await mgr.dispose();
  });

  test('注入的 promptDetector 生效：默认提示符不再算完成（I3）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: _FakeFactory(sessions),
        // 只认 `>` 结尾。`#` 结尾的（默认正则认）不该再算提示符。
        promptDetector: PromptDetector(pattern: RegExp(r'>\s*$')),
      );

      final completed = <CommandCompleted>[];
      mgr.connect();
      async.flushMicrotasks();
      mgr.dispatcher!.events.listen((e) {
        if (e is CommandCompleted) completed.add(e);
      });

      // 默认正则认 `Switch#`，注入的这个不认 —— 命令不得完成。
      sessions[0].emit('Switch# ');
      async.elapse(const Duration(milliseconds: 500));
      async.flushMicrotasks();
      expect(
        completed,
        isEmpty,
        reason: '忽略注入的话默认正则认得 `#`，这条就会被判成完成',
      );

      // 注入的这个认 `Switch>` —— 这次必须完成。
      sessions[0].emit('Switch> ');
      async.elapse(const Duration(milliseconds: 500));
      async.flushMicrotasks();
      expect(completed, hasLength(1), reason: '自定义正则认得就必须完成');
      expect(completed.single.command, 'enable');

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('注入的 morePager 生效：自定义翻页提示也回送继续键（I3）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: _FakeFactory(sessions),
        // 设备用的是自定义的翻页提示，不在默认那三种里。
        morePager: MorePager(patterns: const ['(q)uit']),
      );

      mgr.connect();
      async.flushMicrotasks();
      expect(sessions[0].written, ['enable\n']);

      sessions[0].emit('...\n(q)uit');
      async.flushMicrotasks();

      // 不回送继续键，设备就停在翻页提示上：这一条命令要等到 10s 超时才
      // 算结束，后面的命令全部被它堵住。
      expect(
        sessions[0].written,
        ['enable\n', MorePager.continueKey],
        reason: '自定义翻页提示必须触发继续键',
      );

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  // ---- 退避序列这个注入口本身（I4）----

  test('注入的 backoff 生效：重连发生在配置的延迟上（I4）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final factory = _FakeFactory(sessions, failConnect: true);
      final mgr = ConnectionManager(
        profile: _profile(),
        factory: factory,
        backoff: const [Duration(milliseconds: 50), Duration(milliseconds: 80)],
      );

      mgr.connect();
      async.flushMicrotasks();
      expect(factory.created, 1);

      // 默认序列的第一档是 1s。注入 50ms 之后 999ms 那套断言就不再适用。
      async.elapse(const Duration(milliseconds: 49));
      async.flushMicrotasks();
      expect(factory.created, 1, reason: '不足注入的 50ms 不得重连');

      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(factory.created, 2, reason: '应按注入的 50ms 重连');

      // 第二档也是注入的 80ms —— 整个序列都换了，不只是第一项。
      async.elapse(const Duration(milliseconds: 80));
      async.flushMicrotasks();
      expect(factory.created, 3, reason: '第二档应按注入的 80ms');

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  // ---- connect() 必须拥有它替换掉的那条会话（I5）----

  test('已连接时再 connect()：被替换的会话必须被关掉、订阅必须被摘掉（I5a）', () async {
    final sessions = <_FakeSession>[];
    final mgr = ConnectionManager(
      profile: _profile(),
      factory: _FakeFactory(sessions),
    );

    final received = <String>[];
    mgr.output.listen(received.add);

    await mgr.connect();
    await mgr.connect();

    expect(sessions.length, 2, reason: '第二次手动连接会建一条新会话');
    // 泄漏的不是内存，是**一条仍插在设备上的 SSH 连接**：设备侧的 vty
    // 一直占着，而应用这边再也拿不到它去关。
    expect(
      sessions[0].closed,
      isTrue,
      reason: '被替换掉的会话必须被 close()，否则它永远没人关',
    );
    expect(sessions[1].closed, isFalse, reason: '当前会话仍然活着');
    expect(mgr.state, DeviceConnectionState.connected);
    expect(sessions[1].written, ['enable\n'], reason: '新会话照样要下发登录后命令');

    // 旧会话的订阅也必须摘掉：它还挂着的话，那条已被替换的连接会继续往
    // 界面灌数据（两个会话的回显混在一起，且谁也停不下来）。
    //
    // 这条断言钉的是 manager 自己那句 `await outputSub?.cancel();`：夹具的 `close()`
    // **不关** `_output`（见 `_FakeSession.close` 的注释），所以上面那句
    // `closed == isTrue` 通过之后，这次 emit 依然会真的送到订阅者手上 —— 把 cancel
    // 删掉，stale chunk 就会到达界面，这条断言随之变红。
    sessions[0].emit('stale output');
    sessions[1].emit('live output');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      received,
      ['live output'],
      reason: '被替换掉的会话不得再往 mgr.output 里灌数据',
    );

    await mgr.dispose();
  });

  test('重连待命中手动 connect()：待命的重连定时器必须作废（I5c）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final factory = _FakeFactory(sessions);
      final mgr = ConnectionManager(profile: _profile(), factory: factory);

      mgr.connect();
      async.flushMicrotasks();
      expect(factory.created, 1);

      // 断线 → 排程 1s 后的重连（`_retryTimer` 待命）。
      sessions[0].drop();
      async.flushMicrotasks();

      // 用户此刻手动点"连接"，并且在那个定时器到点前就连上了。
      mgr.connect();
      async.flushMicrotasks();
      expect(factory.created, 2, reason: '手动连接应立刻建一条新会话');

      // 原本待命的重连定时器到点。它若不作废，就会再造一条会话，把刚连上的
      // 这条顶掉（`_session` 被覆写 → 这条再也没人关）。
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(
        factory.created,
        2,
        reason: '待命的重连定时器不得在手动连接之后再触发一次',
      );
      expect(sessions[1].closed, isFalse, reason: '手动连上的会话不得被覆写掉');

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('连点两下 connect()：不留孤儿会话，也不发假告警', () async {
    // 真实 async（不是 fakeAsync）：这条要等第一次 connect() 被 close() 打回来。
    final sessions = <_FakeSession>[];
    final mgr = ConnectionManager(
      profile: _profile(),
      factory: _FakeFactory(sessions, failConnect: true, gate: true),
    );
    addTearDown(mgr.dispose);

    final failures = <ConnectionFailure>[];
    final reconnected = <Reconnected>[];
    mgr.events.listen((e) {
      if (e is ConnectionFailed) failures.add(e.failure);
      if (e is Reconnected) reconnected.add(e);
    });

    // 用户连点两下。第一次挂在握手中途；第二次的 connect() 会把第一条拆掉，
    // 于是第一条的 connect() 抛错 —— 而它**已经过期**，那条失败不是用户的线。
    final first = mgr.connect();
    await Future<void>.delayed(Duration.zero);
    final second = mgr.connect();
    unawaited(second); // 见下：这一条**故意不等**

    // 只有**第一次**能等到：它建的会话已经被第二次的 `_teardownSession()` 关掉，
    // 于是它的 connect() 抛错返回。
    await first;
    // 留一点时间给"万一存在的"重连定时器与在途拆除。
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // **不要 `await second`**：`gate: true` + `failConnect: true` 下，第二次建的
    // 那条会话挂在握手中途，而**没有任何东西会去关它**（它就是当下那条）。等它
    // 等于等一个永远不会到来的 gate —— 整个文件会挂到超时，而不是点名变红。
    // 夹具的 gate 只由 `close()` 打开，所以"它还开着"正是"它是当下的会话"。

    // 修复前实际是 3 条：过期那次失败还会 `_scheduleRetry()`，
    // 于是一个我们控制不了的定时器又建了第三条。
    expect(sessions, hasLength(2), reason: '两次点击只该建两条会话');

    // 断言写成"只有最后一条可以还开着"，不要写成 `closed` 全为 true —— 后者会被
    // 末尾那次 `mgr.dispose()` 的拆除变成**恒真**，看不出孤儿。
    final stillOpen = [
      for (var i = 0; i < sessions.length; i++)
        if (!sessions[i].closed) i,
    ];
    expect(
      stillOpen,
      [sessions.length - 1],
      reason: '只有当下那条可以还开着；其余都是占着设备侧一个 vty 的孤儿',
    );
    expect(failures, isEmpty, reason: '自己拆出来的失败不是用户的线，报了就是假告警');
    expect(reconnected, isEmpty, reason: '用户从没掉过线，不该有重连横幅');
  });

  test('被取代的会话不得再往 mgr.output 里灌数据', () async {
    // 不 gate、不 fail：两条会话都真的连上，于是两条都注册过 output 订阅 ——
    // 这才是"旧订阅有没有被摘掉"唯一能被看见的形状。
    final sessions = <_FakeSession>[];
    final mgr = ConnectionManager(
      profile: _profile(),
      factory: _FakeFactory(sessions),
    );
    addTearDown(mgr.dispose);

    final received = <String>[];
    mgr.output.listen(received.add);

    await mgr.connect();
    await mgr.connect(); // 取代第一条
    await Future<void>.delayed(Duration.zero);
    expect(sessions, hasLength(2));

    // 每条会话各吐一次。夹具的 close() 刻意不关 _output，所以旧会话**还能** emit，
    // 到不到得了 mgr.output 完全取决于订阅有没有被取消。
    sessions[0].emit('out0');
    sessions[1].emit('out1');
    await Future<void>.delayed(Duration.zero);

    expect(received, ['out1'], reason: '旧会话的订阅必须已经被摘掉');
  });
}
