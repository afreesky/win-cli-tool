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
    expect(c.status.state, DeviceConnectionState.connected);
    await c.disconnect();
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
    await c.dispose();

    expect(await _readAllLogs(logsRoot), isEmpty, reason: '没构造就不该有文件');
  });

  test('日志写在 logs/ 下的日期目录里，内容与输出区同源', () async {
    final c = make();
    addTearDown(c.dispose);
    await c.connect();
    factory.sessions.single.emit('a\x1b[31mred\x1b[0m\n');
    await settle();
    await c.dispose();

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
    factory.sessions.single.emit('boom\n');
    await settle();

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
