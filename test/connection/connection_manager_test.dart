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
    unawaited(_output.close());
  }

  /// 模拟对端断开。[error] 给出时先记进 [lastError] —— 与两个真实实现里
  /// `_onDisconnected` 的"先存再 `complete()`"保持同一顺序（§13.20）。
  void drop([Object? error]) {
    if (error != null) lastError = error;
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
