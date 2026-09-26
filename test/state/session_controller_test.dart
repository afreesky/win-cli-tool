import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_manager.dart';
import 'package:win_cli_tool/state/output_buffer.dart';
import 'package:win_cli_tool/state/session_controller.dart';

import '../fixtures/fake_session.dart';

void main() {
  late Directory logsRoot;
  late OutputBuffer buffer;
  late FakeSessionFactory factory;

  setUp(() async {
    logsRoot = await Directory.systemTemp.createTemp('wct_session_');
    buffer = OutputBuffer(maxLines: 5000);
    factory = FakeSessionFactory();
  });

  tearDown(() async {
    if (logsRoot.existsSync()) await logsRoot.delete(recursive: true);
  });

  SessionController make({
    bool logEnabled = true,
    void Function(Object)? onLogError,
    bool autoConnect = false,
  }) => SessionController(
    profile: fakeProfile(autoConnect: autoConnect),
    factory: factory,
    buffer: buffer,
    logsDir: logsRoot,
    logEnabled: logEnabled,
    onLogError: onLogError,
  );

  /// 输出是一条广播流，订阅与转发都在微任务里 —— 让它们跑完。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('输出在**第一次连接之前**就已经接上了', () async {
    // 这条钉的正是"订阅 Session.output 会在第一次断线后永久静止"那个坑：
    // 缓冲接的是 ConnectionManager.output，它在连接之前就存在。
    final c = make();
    addTearDown(c.dispose);

    await c.connect();
    factory.sessions.single.emit('hello');
    await settle();

    expect(buffer.lines.first.single.text, 'hello');
  });

  test('重连之后输出仍然接着来（会话对象被换掉了）', () async {
    final c = make();
    addTearDown(c.dispose);

    await c.connect();
    factory.sessions.single.emit('before');
    await settle();

    // 对端断开 → 退避重连。用真实 async，因为这条要等拆除链走完。
    factory.sessions.single.drop();
    await Future<void>.delayed(const Duration(seconds: 2));
    await settle();
    expect(factory.sessions, hasLength(2), reason: '1s 后应当已经重连');

    factory.sessions[1].emit('after');
    await settle();

    final text = buffer.lines
        .map((line) => line.map((s) => s.text).join())
        .join('\n');
    expect(text, contains('before'));
    expect(text, contains('after'), reason: '换会话之后输出区不得静止');
  });

  test('状态跟着 ConnectionManager 走', () async {
    final c = make();
    addTearDown(c.dispose);

    expect(c.status.state, DeviceConnectionState.disconnected);
    await c.connect();
    // **`status` 是事件的镜像，不是 manager 自己的 `state`。** 事件走广播流，
    // 而投递**不是**"下一个微任务"那么快：实测 `await c.connect()` 刚返回时
    // `c.status.state` 还是 `connecting`，而 `c.state`（直接问 manager）已经是
    // `connected`；让一轮事件循环跑完（`settle()`）两者才一致。
    // 断言镜像就得等投递 —— 本文件读事件驱动状态的地方都这么做（见 `settle()`
    // 的定义：它存在的理由就是这件事）。
    //
    // 顺带记一笔给 5b：`SessionController.state`（同步，直接问 manager）与
    // `SessionStatus.state`（异步镜像）是**两个真相来源**，会差一个回合。
    // 界面得**有意地**挑一个用，别混着用。
    await settle();
    expect(c.status.state, DeviceConnectionState.connected);
    await c.disconnect();
    await settle();
    expect(c.status.state, DeviceConnectionState.disconnected);
  });

  test('断开与重连在输出区各插一个标记，且**不进日志**', () async {
    final c = make();
    addTearDown(c.dispose);
    await c.connect();

    factory.sessions.single.drop();
    await Future<void>.delayed(const Duration(seconds: 2));
    await settle();

    final text = buffer.lines
        .map((line) => line.map((s) => s.text).join())
        .join('\n');
    expect(text, contains('连接断开'));
    expect(text, contains('重连成功'));

    // **读日志之前必须先逼它落盘。** `LogWriter._flush` 默认只在攒够
    // `flushEveryLines`（32）行时才真写，`start()` / `write()` / `disconnected()`
    // 都**不是**强制点 —— 唯一的强制点是 `end()`。本用例到这一步只往日志里放了
    // 四行，所以不落盘的话磁盘上**什么都没有**，下面那两条"不含"就在空串上成立。
    //
    // 这条原本写的是 `expect(log, isNot(contains('连接断开')))`，**它永远不会红**：
    // ① 如上，读到的是空串；② 就算落了盘它也不成立 —— LogWriter 自己的断开标记
    // 里就有"连接断开"这四个字（§5.6 逐字规定，见 `LogWriter.disconnected`）。
    // 一个字段名被两边共用，"不含这个词"就不可能表达"输出区的标记没混进去"。
    // 判据只能是各自的**记号**：输出区的以 `--- ` 开头、不带时间戳，LogWriter 的
    // 形如 `[时间戳] !!! 连接断开 …！！！`。
    //
    // 用 `disconnect()` 而不是 `dispose()`：前者 `await` 了 `log.end()`，落盘是
    // 确定的；后者的 `_endLogSync` 是 `unawaited(log?.end())`，读的时候可能还没写完。
    await c.disconnect();

    final log = await _readAllLogs(logsRoot);
    // 这两条是下面两条的**前提**：它们证明日志确实有内容。
    // 没有它们，"不含"两条在"日志是空的"时也会绿。
    expect(log, contains('!!! 连接断开'), reason: 'LogWriter 自己会写断开标记（§5.6）');
    expect(log, contains('=== 重连成功'), reason: 'LogWriter 自己会写重连标记（§5.6）');
    expect(log, isNot(contains('--- 连接断开')), reason: '输出区的标记不进日志');
    expect(log, isNot(contains('--- 重连成功')), reason: '输出区的标记不进日志');
  });

  test('丢弃数从 dispatcher.events 取（FR-C-10）', () async {
    final c = make();
    addTearDown(c.dispose);
    await c.connect();

    c.enqueue(const ['show version', 'show clock']);
    await settle();
    factory.sessions.single.drop();
    await settle();

    expect(
      c.status.droppedCommands,
      greaterThan(0),
      reason: '未发出的命令一律丢弃，丢弃数由 QueueDropped 承载',
    );
  });

  test('关掉日志时不构造 LogWriter（FR-L-07）', () async {
    final c = make(logEnabled: false);
    addTearDown(c.dispose);
    await c.connect();
    factory.sessions.single.emit('hello\n');
    await settle();
    // **这里也必须是 `disconnect()`。** `dispose()` 的 `_endLogSync` 是
    // `unawaited(log?.end())`，读的时候磁盘上本来就可能什么都没有（下一条用例
    // 有实测）—— 那样"没有文件"就成了**空转**：即使真的构造了 `LogWriter`，
    // 这条也照样绿。`disconnect()` 会 `await end()`，真有 writer 就必然出现文件，
    // 于是"空"才真的证明"没构造"。
    await c.disconnect();

    expect(await _readAllLogs(logsRoot), isEmpty, reason: '没构造就不该有文件');
  });

  test('日志写在 logs/ 下的日期目录里，内容与输出区同源', () async {
    final c = make();
    addTearDown(c.dispose);
    await c.connect();
    factory.sessions.single.emit('a\x1b[31mred\x1b[0m\n');
    await settle();
    // **逼日志落盘要用 `disconnect()`，不能用 `dispose()`。** `dispose()` 走的是
    // `_endLogSync()`，那是 `unawaited(log?.end())` —— 读的时候写还没落下去，
    // 而在那之前**连日期目录都还不存在**（`LogWriter._flush` 只在真正要写的那
    // 一步才 `create(recursive: true)`）。实测：`dispose()` 之后立刻读是**空串**，
    // 300ms 之后才有内容（内容本身是对的：含 `red`、无 ESC）。
    // `disconnect()` 里的 `_endLog()` 是 `await log?.end()`，落盘是确定的。
    await c.disconnect();

    final log = await _readAllLogs(logsRoot);
    expect(log, contains('red'));
    expect(log, isNot(contains('\x1b')), reason: '日志是剥干净的纯文本');
  });

  test('日志写盘失败时回调一次，且不拖垮会话（FR-L-06）', () async {
    final errors = <Object>[];
    // 日志根目录的父路径是一个**普通文件**，所以写盘必定失败。
    final blocker = File('${logsRoot.path}/blocker')
      ..writeAsStringSync('not a dir');
    final c = SessionController(
      profile: fakeProfile(),
      factory: factory,
      buffer: buffer,
      logsDir: Directory('${blocker.path}/logs'),
      logEnabled: true,
      onLogError: errors.add,
    );
    addTearDown(c.dispose);

    await c.connect();
    // **必须喂够一次真实的写盘尝试，否则下面那条断言不可达。** `LogWriter._flush`
    // 默认只在缓冲攒够 `flushEveryLines`（32）行时才真写；`start()` / `write()`
    // 都**不是**强制点（唯一的强制点是 `end()`）。只喂一行的话根本不会碰磁盘，
    // `onLogError` 无从触发 —— 实测：一行 + `settle()` ⇒ **0 次**回调。
    //
    // 一次喂 40 行，而且是**同一个 chunk**（于是只触发一次 `_flush`）：写盘必定
    // 失败 ⇒ 回调一次 ⇒ `_failed` 置位，此后本类不再碰磁盘。
    //
    // 写成 `'x\n' * 40` 而不是 `'${'x\n' * 40}'`：后者那层插值是多出来的
    // （表达式本来就是 String），分析器判 `unnecessary_string_interpolations`，
    // 而完成标准 1 要求 `dart analyze` 干净。
    factory.sessions.single.emit('x\n' * 40);

    // 失败要等两个真的 IO 回合（`stat()` → `create()`）。实测：0ms 与 5ms 时还是
    // 0 次，50ms 时是 1 次 —— 所以固定等一个 `Duration.zero` 不够。这里**轮询到
    // 条件成立**（上限 2 秒），而不是赌一个毫秒数：等不到就是下面那条断言红，
    // 不会变成"偶尔绿"。
    for (var i = 0; i < 200 && errors.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(errors, hasLength(1), reason: '失败只报一次');
    expect(
      c.status.state,
      DeviceConnectionState.connected,
      reason: '日志坏掉绝不能拖垮会话',
    );
  });

  test('dispose() 关掉会话，且不向设备发任何命令（FR-C-12）', () async {
    final c = make();
    await c.connect();
    final session = factory.sessions.single;
    session.written.clear();

    await c.dispose();

    expect(session.closed, isTrue, reason: 'FR-C-12：退出时直接关闭所有会话');
    expect(
      session.written,
      isEmpty,
      reason: 'FR-C-12：不向设备发送任何命令 —— 包括不清除分页、不发登出序列',
    );
  });

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

  test('连接失败的原因必须写进**输出区**（FR-C-06）', () async {
    // 原先 `ConnectionFailed` 只做了 `_status.copyWith(lastFailure: …)`，
    // 而 `lib/ui/` 里**没有任何一处读 `lastFailure`** —— 于是原因只活在状态
    // 对象里，用户永远看不到。2026-09-26 对真机排查时现场正是这样：一台只
    // 提供 `ssh-rsa` 的交换机连不上，界面只有"X 秒后重连"在滚，没有任何线索。
    //
    // FR-C-06 的原文是「**在输出区**给出可读的失败原因」—— 所以这条断言必须
    // 落在 buffer 上，只断言 `status.lastFailure` 是抓不到这个缺陷的（那正是
    // 缺陷当时唯一的表现）。
    final c = make();
    addTearDown(c.dispose);

    factory.failConnect = true;
    await c.connect();
    await settle();

    expect(
      _textOf(buffer),
      contains('连接失败'),
      reason: 'FR-C-06：原因必须在输出区，不能只留在状态对象里',
    );
    expect(
      c.status.lastFailure,
      isNotNull,
      reason: '状态里那一份仍要保留（界面别处可能用它）',
    );
  });

  test('同一条原因只报一次，用户手动重连要重新报（FR-C-06）', () async {
    // `ConnectionFailed` 是**每次失败尝试**都发的，而 FR-C-07 会一直重试下去
    // （退避到 30s 封顶后无限期）。逐条写会把输出区刷满同一句话，把真正的
    // 输出挤走 —— 所以要抑制**重复的同一句**。
    //
    // 但抑制不能过头：用户手动点"连接"时必须重新报。否则界面会变成"按了
    // 连接，连一句理由都不给"，比不显示更费解。
    final c = make();
    addTearDown(c.dispose);

    factory.failConnect = true;
    await c.connect();
    await settle();
    expect(_countOf(_textOf(buffer), '--- 连接失败'), 1);

    // 再等至少两轮重试（退避 1s → 2s）。期间失败原因逐字相同。
    await Future<void>.delayed(const Duration(seconds: 3));
    await settle();
    expect(
      _countOf(_textOf(buffer), '--- 连接失败'),
      1,
      reason: '同一条原因重复出现时不得刷屏',
    );

    // 用户手动重连。
    await c.connect();
    await settle();
    expect(
      _countOf(_textOf(buffer), '--- 连接失败'),
      2,
      reason: '手动重连后必须重新给出理由，否则按了连接却看不到任何解释',
    );
  });

  test('失败原因**变了**就必须重新报（FR-C-06）', () async {
    // 抑制的判据是"与上一条**逐字相同**"，不是"报过就不再报"。原因从
    // 一种变成另一种（超时 → 认证失败）是新信息，用户要靠它决定下一步做什么。
    final c = make();
    addTearDown(c.dispose);

    factory.failConnect = true;
    await c.connect();
    await settle();
    expect(_textOf(buffer), contains('connect failed'));

    // 换一种失败原因，等下一轮重试探到它。
    factory.failError = const FakeConnectFailure2();
    await Future<void>.delayed(const Duration(seconds: 3));
    await settle();

    expect(
      _textOf(buffer),
      contains('connect failed differently'),
      reason: '换了一种失败原因，必须让用户看到新的那一条',
    );
  });
}

/// 输出区的全文。多条用例要看"某个标记出现了几次"，所以单独抽出来。
String _textOf(OutputBuffer buffer) =>
    buffer.lines.map((line) => line.map((s) => s.text).join()).join('\n');

/// [needle] 在 [haystack] 里出现了几次（不重叠）。
int _countOf(String haystack, String needle) {
  var count = 0;
  var from = 0;
  while (true) {
    final at = haystack.indexOf(needle, from);
    if (at < 0) return count;
    count++;
    from = at + needle.length;
  }
}

/// 读遍日志根目录下的所有 .log 文件，拼成一个字符串。
Future<String> _readAllLogs(Directory root) async {
  if (!root.existsSync()) return '';
  final parts = <String>[];
  await for (final entity in root.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.log')) {
      parts.add(await entity.readAsString());
    }
  }
  return parts.join('\n');
}
