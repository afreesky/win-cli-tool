import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHKeyDecodeError;
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

/// 一条**不参与任何 SSH 握手**的字节流。
///
/// **它不是"假 SSH 服务端"**：对端永远不说话，握手**发不出也走不完**（Task 7
/// 才造真服务端）。措辞要紧：**不是"根本不会开始"** —— `SSHClient` 的构造
/// 函数就会建起 `SSHTransport`（其构造函数里 `_initSocket();
/// _startHandshake();`），状态机确实启动了，只是没人应它，推进不下去。
///
/// 它能做的有三件事 —— 给 `debugBuildClient()` 与 `connect()` 一个真
/// `SSHClient` 收得下的 socket；让 `connect()` 停在 `await client.authenticated`
/// 这个中间态（此时 `_client` 已赋值、`_session` 还是 null）；以及让 `close()`
/// 走到 `_client?.close()` 那一行（夹具可令其抛错）。
class _StubConnection implements Connection {
  _StubConnection({this.throwOnClose = false});

  /// 为 true 时 `close()` 抛错，用来守 `close()` 的"清理必须走完"。
  final bool throwOnClose;

  /// **必须是广播 controller。** 单订阅的 `close()` 在**无人监听**时永不完成
  /// （订阅流要有人 drain 才发得出 done），于是 `await _input.close()` 会永远
  /// 挂着。实测过代价：第 17 条变异（删掉 `connect()` 顶上的
  /// `if (_closed) return;`）本该是一条**点名断言**的 `[E]`，在这块夹具下退化成
  /// `TimeoutException after 0:00:30: Test timed out after 30 seconds` ——
  /// 证据还在，却被这条与缺陷无关的挂起盖住了。广播 controller 的 `close()`
  /// 立刻完成，红就落回它自己的断言上。
  final _input = StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  void write(List<int> data) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (throwOnClose) {
      throw const FileSystemException('底层关闭失败（测试夹具）');
    }
    if (!_input.isClosed) await _input.close();
  }
}

/// 立刻交出一条 [_StubConnection]，不做任何握手。会记账被调用了几次。
class _StubConnector implements Connector {
  _StubConnector(this.conn);

  final Connection conn;
  var openCount = 0;

  @override
  Future<Connection> open(String host, int port, {Duration? timeout}) async {
    openCount++;
    return conn;
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

var _tempSeq = 0;

/// 把一段内容写进系统临时目录，返回路径。**用完自动删除。**
///
/// 文件名里带 pid 与序号：固定名字下两个并发跑的 `flutter test` 会互相
/// 覆盖对方的夹具（一个刚写完、另一个 chmod 000，读的那个拿到 EACCES，
/// 于是红得像实现坏了）。清理同理 —— 不删就是在系统临时目录里留垃圾。
String _writeTemp(String name, String content) {
  final file = File(
    '${Directory.systemTemp.path}/wct_t4_${pid}_${_tempSeq++}_$name',
  );
  file.writeAsStringSync(content);
  addTearDown(() {
    if (file.existsSync()) file.deleteSync();
  });
  return file.path;
}

/// chmod 000 在本机是否真的能造出"读不了"的夹具。
///
/// 以 root 运行时权限位不生效（照样读得到），Windows 根本没有 chmod。
/// 这两种机器上那条用例必须**跳过**而不是假装通过 —— 一个恒绿的用例
/// 比没有用例更坏。
final bool _canMakeUnreadable = () {
  if (Platform.isWindows) return false;
  final file = File('${Directory.systemTemp.path}/wct_t4_${pid}_probe');
  try {
    file.writeAsStringSync('probe');
    Process.runSync('chmod', ['000', file.path]);
    try {
      file.readAsStringSync();
      return false;
    } on FileSystemException {
      return true;
    } finally {
      Process.runSync('chmod', ['600', file.path]);
      file.deleteSync();
    }
  } catch (_) {
    return false;
  }
}();

/// 指纹以 UTF-8 字节交给回调，与 dartssh2 一致。
Uint8List _fingerprint(String text) => Uint8List.fromList(utf8.encode(text));

/// 取出**真正交给 `SSHClient` 的那个**主机密钥回调。
///
/// 直接读已构造的 client 上的字段，而不是 `_buildHostKeyCallback()` 的
/// 返回值 —— 后者是代理断言：把传参点改成 null 它依然为真（§13.14-1 的
/// 旁路会静默通过）。
FutureOr<bool> Function(String, Uint8List) _hostKeyCallback(
  SshSession session,
) {
  final client = session.debugBuildClient(_StubConnection(), null);
  final callback = client.onVerifyHostKey;
  expect(
    callback,
    isNotNull,
    reason: 'onVerifyHostKey 为 null 时 dartssh2 接受任意主机密钥（FR-C-11 整体旁路）',
  );
  return callback!;
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

  test('close() 的清理必须走完：底层关闭抛错时 output 仍要关闭', () async {
    // 守的是 close() 的**非空**路径。原实现里清理是四行直笔的顺序代码，
    // `await _client?.close()` 一旦抛错，后面的 `_socket?.dispose()` 与
    // `_output.close()` 就都不执行 —— output 这个广播 controller 永远不关，
    // 订阅方（会话列表、终端视图）就这么挂着。这与上面三条空路径用例守的
    // 是同一类失败（"抛在这里应用就退不掉"），只是发生在非空路径上。
    //
    // 夹具让底层 Connection 的 close() 抛错，等价于设备把 TCP 掐了之后
    // 用户退出应用：`client.close()` 会带着这个错误返回。
    final session = SshSession(
      profile: _profile(),
      connector: _StubConnector(_StubConnection(throwOnClose: true)),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    // connect() 会停在 `await client.authenticated`（对端永远不说话）。
    // 这正是需要的中间态：_client 已赋值，_session 还是 null。
    unawaited(session.connect().catchError((Object _) {}));
    await Future<void>.delayed(Duration.zero);

    final outputClosed = session.output
        .drain<void>()
        .timeout(const Duration(seconds: 2));

    // 第一个错误仍然要抛出来（不吞异常），但清理不许因此半途而废。
    await expectLater(session.close(), throwsA(isA<FileSystemException>()));
    await expectLater(outputClosed, completes);
  });

  test('close() 之后再 connect() 必须直接返回，不能再拨号', () async {
    // 原实现没有入口守卫：close() 之后 connect() 照样拨号，走完
    // `if (_closed)` 分支再正常返回 —— 一个已关闭的会话对外报"连上了"。
    // 用户切设备、关窗口之后，任何一次迟到的 connect() 都会真的去连设备。
    final connector = _StubConnector(_StubConnection());
    final session = SshSession(
      profile: _profile(),
      connector: connector,
      hostKeyStore: InMemoryHostKeyStore(),
    );

    await session.close();
    await expectLater(session.connect(), completes);

    expect(connector.openCount, 0, reason: '已关闭的会话不该再拨号');
  });

  test('无论校验开关如何，交给 SSHClient 的回调都必须非 null', () {
    // §13.14-1：onVerifyHostKey 为 null 时 dartssh2 直接放行任意主机密钥
    // （`userVerified` 取 true），也就是 FR-C-11 被整体旁路（NFR-S-03）。
    //
    // 断言的是**已构造的 SSHClient 上的那个字段**，不是
    // `_buildHostKeyCallback()` 的返回值 —— 后者是代理断言，传参点改成
    // null 也照绿。两种开关都要查：关闭校验是最容易被写成"干脆不传"的路径。
    for (final verify in [true, false]) {
      final session = SshSession(
        profile: _profile(),
        connector: _FailingConnector(Exception('不该走到这里')),
        hostKeyStore: InMemoryHostKeyStore(),
        verifyHostKey: verify,
      );

      final client = session.debugBuildClient(_StubConnection(), null);

      expect(
        client.onVerifyHostKey,
        isNotNull,
        reason: 'verifyHostKey=$verify 时，回调仍必须被显式传入',
      );
    }
  });

  test('connect() 自己那条传参路径：它建出来的 client 也必须拿到非 null 回调', () async {
    // 上面那条用例断言的是**用例自己**通过 `debugBuildClient()` 造出来的
    // client —— 它钉住的是"工厂会传非 null"。但复审实测过：在 `connect()`
    // 里**直接内联** `SSHClient(…, onVerifyHostKey: null)` 编译得过、而且整套
    // 用例照绿（那条内联路径根本不经过工厂）。也就是说 `connect()` **自己的**
    // 传参点此前没人钉 —— 与当初那个代理断言是同一类缺口。
    //
    // 这一条让 `connect()` 自己跑：`_StubConnector` 交出一条 stub `Connection`
    // （对端不说话），`connect()` 会停在 `await client.authenticated` ——
    // 那正是需要的中间态，此时它手上的 client 已经建好。断言的是**它真的建出来的
    // 那个对象**（`debugLastBuiltClient`），不是用例另造的一个。
    //
    // 内联绕开 `_createClient()` 的写法会让 `debugLastBuiltClient` **保持
    // null**，于是第一条断言先红 —— 见 Step 5 第 24 条。
    final session = SshSession(
      profile: _profile(),
      connector: _StubConnector(_StubConnection()),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    unawaited(session.connect().catchError((Object _) {}));
    await Future<void>.delayed(Duration.zero);

    final built = session.debugLastBuiltClient;
    expect(
      built,
      isNotNull,
      reason: 'connect() 必须经由 _createClient() 造 client —— 内联会绕过那个'
          '唯一的传参点，onVerifyHostKey 就没人钉了',
    );
    expect(
      built!.onVerifyHostKey,
      isNotNull,
      reason: 'connect() 建出来的 client 上，onVerifyHostKey 为 null 时 dartssh2 '
          '接受任意主机密钥（§13.14-1，FR-C-11 整体旁路）',
    );
  });

  test('拨号之后的阶段也有超时：对端接了 TCP 却不说话时不能永远挂着', () async {
    // spec §13.21-1：`connectTimeout` 原先只交给拨号，`await client.authenticated`
    // 与 `await client.shell(...)` **没有任何上限**。一台"接受了 TCP 却不说话"
    // 的设备（老设备卡在 KEX、或中间有个只做 TCP 代理的黑洞）会让 `connect()`
    // **永远**挂着 —— 按钮一直黄，既没有 `ConnectionFailed`、也不重连。
    // FR-C-13 承诺的是"连接超时默认 15 秒"，用户得到的却是无限等待。
    //
    // 夹具用 `_StubConnection`：对端永远不说话，握手发不出也走不完，于是
    // `connect()` 正卡在 `await client.authenticated` 这一行 —— 就是这一条要
    // 钉住的那一段。拨号那一段由 `_StubConnector` 立刻交回连接，所以下面的
    // 超时**只可能**来自拨号之后的包超时。
    final connector = _StubConnector(_StubConnection());
    final session = SshSession(
      profile: _profile(),
      connector: connector,
      hostKeyStore: InMemoryHostKeyStore(),
      connectTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(session.close);

    // 哨兵：只有 `connect()` 永远不返回时才会拿到它。**不用测试框架自己的
    // 超时** —— 那条要跑满 30 秒才红，而且拿到的是同型的 `TimeoutException`，
    // 分不清是实现的超时还是框架的超时（那会让这条用例在变异下假绿）。
    const sentinel = 'connect() 一直没有返回';
    final hang = Completer<Object?>();
    final hangTimer = Timer(const Duration(seconds: 5), () => hang.complete(sentinel));

    final stopwatch = Stopwatch()..start();
    final result = await Future.any<Object?>([
      session.connect().then<Object?>((_) => null, onError: (Object e) => e),
      hang.future,
    ]);
    stopwatch.stop();
    hangTimer.cancel();

    expect(result, isNot(sentinel), reason: '对端不说话时 connect() 必须失败，不能永远挂着');
    expect(result, isA<TimeoutException>(), reason: '实际拿到：$result');
    expect(
      stopwatch.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 150)),
      reason: '必须真的等到 connectTimeout 才失败，而不是立刻以别的理由失败',
    );
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 3)),
      reason: '超时要发生在 connectTimeout(200ms) 附近，不是靠上面那个 5s 兜底',
    );

    // 超时必须落进分类器 `TimeoutException` → `timeout` 那一支 —— 拨号之后
    // 用 `.timeout()` 而不给 `SSHClient` 设 `handshakeTimeout`，理由正在于此：
    // 后者会变成 `SSHHandshakeError('Handshake timed out')` → `protocolError`，
    // 把方向指到"对端可能不是 SSH 服务"上去（§13.15）。
    expect(
      classifyConnectionFailure(result!).kind,
      ConnectionFailureKind.timeout,
    );
    // 拨号确实发生过（否则上面的"超时"可能只是 open 从来没被调用）。
    expect(connector.openCount, 1);
  });

  // ---------------------------------------------------------------------
  // 以下五条直接调用**交给 SSHClient 的那个回调**，守它的函数体：
  // find → 比对 → 询问用户 → save / 拒绝。这些用例既不需要假服务端，
  // 也不需要假会话 —— 回调本身就是一个可直接调用的函数。
  // ---------------------------------------------------------------------

  test('回调体：未知主机且没有人接受 → 必须拒绝', () async {
    // onUnknownHostKey 为 null 表示"没有可询问的 UI"，此时一律拒绝
    // （见 onUnknownHostKey 的文档）。绝不能因为"没人回答"就放行。
    final store = InMemoryHostKeyStore();
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: store,
    );

    final accepted = await _hostKeyCallback(session)(
      'ssh-ed25519',
      _fingerprint('SHA256:abc'),
    );

    expect(accepted, isFalse);
    expect(store.all, isEmpty);
  });

  test('回调体：未知主机且用户接受 → 接受并落库', () async {
    final store = InMemoryHostKeyStore();
    KnownHost? asked;
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: store,
      onUnknownHostKey: (host) async {
        asked = host;
        return true;
      },
    );

    final accepted = await _hostKeyCallback(session)(
      'ssh-ed25519',
      _fingerprint('SHA256:abc'),
    );

    expect(accepted, isTrue);
    // 问的是这台设备、这个算法、这个指纹。
    expect(asked?.host, '10.0.0.1');
    expect(asked?.port, 22);
    expect(asked?.keyType, 'ssh-ed25519');
    expect(asked?.fingerprint, 'SHA256:abc');
    // FR-C-11 要求"确认后保存"，否则下次还要再问一遍。
    expect(store.all, hasLength(1));
    expect(store.all.single.fingerprint, 'SHA256:abc');
  });

  test('回调体：指纹与已存记录一致 → 接受（且不打扰用户）', () async {
    final store = InMemoryHostKeyStore();
    await store.save(
      KnownHost(
        host: '10.0.0.1',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:abc',
      ),
    );
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: store,
      onUnknownHostKey: (_) async => fail('已存记录命中时不该再去问用户'),
    );

    final accepted = await _hostKeyCallback(session)(
      'ssh-ed25519',
      _fingerprint('SHA256:abc'),
    );

    expect(accepted, isTrue);
  });

  test('回调体：指纹与已存记录不一致 → 拒绝，且绝不询问用户', () async {
    // §13.15 / FR-C-11 的核心：设备换过密钥，或有中间人。**两种都不能问
    // 用户**"要不要接受新指纹" —— 那正是唯一一个用户绝不能学会点"是"的
    // 警告。方向只能是让用户去设置里清除旧记录。
    final store = InMemoryHostKeyStore();
    await store.save(
      KnownHost(
        host: '10.0.0.1',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:old',
      ),
    );
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: store,
      onUnknownHostKey: (_) async => fail('指纹不一致时绝不能去问用户'),
    );

    final accepted = await _hostKeyCallback(session)(
      'ssh-ed25519',
      _fingerprint('SHA256:new'),
    );

    expect(accepted, isFalse);
    // 旧记录不许被覆盖 —— 覆盖了，"指纹不一致"就再也不会被检测出来。
    expect(store.all.single.fingerprint, 'SHA256:old');
  });

  test('回调体：校验被关闭 → 恒真，但仍然是显式传入的回调', () async {
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
      verifyHostKey: false,
      // 关掉校验时，连"询问用户"都不该发生。
      onUnknownHostKey: (_) async => fail('校验关闭时不该询问用户'),
    );

    final accepted = await _hostKeyCallback(session)(
      'ssh-ed25519',
      _fingerprint('SHA256:abc'),
    );

    expect(accepted, isTrue);
  });

  test('输出流报错时必须完成 done（否则会话看着活着、其实永远哑了）', () async {
    // 原实现只把错误记进 _lastError，不完成 _done。若 stdout 的流报错而
    // `session.done` 又不完成，会话对外**看着还是活的**，但再也不会有任何
    // 输出 —— 上层既不会显示断线、也不会重连。
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    session.debugReportOutputError(Exception('解码失败'));

    expect(session.lastError, isNotNull, reason: '原文要留着，不能吞掉');
    // 不完成 done 的话，这里会以 TimeoutException 变红。
    await expectLater(
      session.done.timeout(const Duration(seconds: 2)),
      completes,
    );
  });

  test('主动 close() 之后，流上的收尾事件不许把 done 报成一次断开', () async {
    // `Session.done` 的契约写在 session.dart：**主动调用 close() 不会触发它。**
    // 落点在这里：done 一旦完成，上层就当成一次意外断线，触发自动重连 ——
    // 退出应用时每台设备白连一次（§13.14-5）。而"收尾事件在 close() **之后**
    // 才到"是常态（`client.close()` 本身就会完成 `session.done`），所以这一支
    // 必须被 `_closed` 挡住。
    final session = SshSession(
      profile: _profile(),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    var doneCompleted = false;
    unawaited(session.done.then((_) => doneCompleted = true));

    await session.close();
    session.debugReportOutputError(Exception('关闭后才到的收尾事件'));
    await pumpEventQueue();

    expect(doneCompleted, isFalse, reason: '主动关闭不能被报成意外断线');
  });

  // ---------------------------------------------------------------------
  // 以下十条守 `_identities()` 的翻译。**这是 Task 4 里唯一不需要假 SSH
  // 服务端就能测的真行为** —— 因为实现把加载私钥排在建连**之前**（见 Step 3
  // 的 connect()），所以一个必然失败的 connector 就足以证明"先失败的是私钥"。
  //
  // 每条用例喂的输入都在 2026-09-24 实测过，抛出的类型写在注释里。
  // 十条合起来覆盖 `_identities()` 的每一支：PathNotFound / UnsupportedError
  // （公钥、加密 PKCS#8、明文 PKCS#8 三种输入） / FormatException /
  // SSHKeyDecryptError / SSHKeyDecodeError（损坏的 RSA 与损坏的 EC，
  // 两种输入同一支）/ FileSystemException（目录与无读权限两种输入）/ 兜底。
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
    // 成因要用中文点名，方向是"去查路径"。少了这条断言，**单独一支**
    // `on PathNotFoundException` 就是可删的：删了它会落到下面
    // `on FileSystemException`（前者是后者的子类），而那条同样有"私钥"、
    // 同样有路径、同样不漏英文类名 —— 三条断言全过，方向却从
    // "路径不存在，去查设置"退成了「文件系统返回：No such file or directory」
    // （英文原文）。
    expect(failure.message, contains('路径不存在'));
    // 英文类名不能漏给用户。
    expect(failure.message, isNot(contains('PathNotFoundException')));
    // 也不能漏出另一支的框架（那是"顺序排反了"的指纹）。
    expect(failure.message, isNot(contains('文件系统返回')));
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
    // 关键：这一支**不能**退化成"格式不支持"。原实现三种输入共用一句话
    // （既说公钥又说 PKCS#8），于是这条断言才会红 —— 只测
    // `contains('公钥')` 是测不出区别的，那句话里本来就有"公钥"。
    expect(failure.message, isNot(contains('PKCS#8')));
    expect(failure.message, isNot(contains('口令')));
    expect(failure.message, isNot(contains('Unsupported')));
  });

  test('带口令的 PKCS#8 私钥 → 文案指向"口令"，不指向"换格式"', () async {
    // 实测：`-----BEGIN ENCRYPTED PRIVATE KEY-----` 抛
    // `UnsupportedError('Unsupported key type: ENCRYPTED PRIVATE KEY')`。
    // **注意 `ENCRYPTED PRIVATE KEY` 里含有 `PRIVATE KEY` 子串** ——
    // 判据写成 `contains('PRIVATE KEY')` 且排在这条之前，就会把这一种
    // 吞进"明文 PKCS#8"那一支，告诉用户去换格式。而换格式**治不好**
    // 一个带口令的私钥，与 §13.15 是同一个坑。
    final session = SshSession(
      profile: _profile(
        keyPath: _writeTemp(
          'id_rsa_pkcs8_enc',
          '-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n'
              '-----END ENCRYPTED PRIVATE KEY-----\n',
        ),
      ),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    final failure = await _failureOf(session.connect());

    expect(failure.kind, ConnectionFailureKind.authFailed);
    // 与 `on SSHKeyDecryptError` 那一支同一个方向：去掉口令。
    expect(failure.message, contains('口令'));
    expect(failure.message, isNot(contains('PKCS#8')));
    expect(failure.message, isNot(contains('公钥')));
    expect(failure.message, isNot(contains('Unsupported')));
  });

  test('明文 PKCS#8 私钥 → 说清"格式不支持"，并给出可换的格式', () async {
    // 实测：`-----BEGIN PRIVATE KEY-----` 抛
    // `UnsupportedError('Unsupported key type: PRIVATE KEY')`。
    // 这一种才是**用户没做错、本版本缺口**，方向是转成 PEM 的 RSA 私钥。
    final session = SshSession(
      profile: _profile(
        keyPath: _writeTemp(
          'id_rsa_pkcs8',
          '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n',
        ),
      ),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    final failure = await _failureOf(session.connect());

    expect(failure.kind, ConnectionFailureKind.authFailed);
    expect(failure.message, contains('PKCS#8'));
    // 不能与另外两种混成一句。
    expect(failure.message, isNot(contains('公钥')));
    expect(failure.message, isNot(contains('口令')));
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
    // —— 删了它，这个异常会落进**下一支** `on SSHKeyDecodeError`
    // （`SSHKeyDecryptError extends SSHKeyDecodeError`，所以父类那一支接得住），
    // 用户看到的是"内容已损坏，或格式不认识" —— **方向是错的**：一个只是带了口令
    // 的用户会被告知文件坏了，于是去重新生成密钥，而真正该做的是去掉口令。
    // 实测：这类变异红的正是 `contains('口令')` 这一条。
    //
    // 下面两条 `isNot` 守的是**更深一层的洞**：`SSHKeyDecodeError` 家族两个类的
    // `toString()` 都会把 `error` 字段打进字符串（`'$runtimeType($message,
    // $error)'`），而 `SSHKeyDecryptError` 的 `error` **就是 null**（实测
    // `SSHKeyDecryptError(Private key is encrypted, null)`）。只要上面那一支
    // 或 `on SSHKeyDecodeError` 那一支退化成"把 `$error` 附回去"，用户就会看到
    // 字面 `null` / 英文类名 —— §13.19-7 修好的那个泄漏，换一层原样复活，
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

  test('损坏的 RSA 私钥 → 中文 ConnectionFailure，一个英文类名都不许漏', () async {
    // 复审实测（2026-09-24，Dart 3.12 / dartssh2 4.1.0）：
    //   -----BEGIN RSA PRIVATE KEY----- + 一段垃圾 →
    //   `SSHKeyDecodeError(Failed to decode private key, Instance of 'ASN1Exception')`
    //
    // 此前它落到兜底 `catch`，而兜底的 `原始信息：$error` 用的是
    // `SSHKeyDecodeError.toString()` = `'$runtimeType($message, $error)'`
    // —— 用户看到的就是 `Instance of 'ASN1Exception'` 这个英文类名。
    //
    // **这一支尤其要看紧**：本应用自己的文案就把用户往这个格式上引 ——
    // `on UnsupportedError` 里"明文 PKCS#8"那一支推荐的正是
    // 「改用 PEM 格式的 RSA 私钥（-----BEGIN RSA PRIVATE KEY-----）」。
    // 用户照着这条建议去转格式、转坏了一个文件，落到这里的那句话必须是中文。
    //
    // 这一条也是 `on SSHKeyDecodeError` 与 `on SSHKeyDecryptError` **判序**的
    // 记录点：把新那一支排到前面，"带口令的 OPENSSH 私钥"那条用例就会红
    // （见 Step 5 第 26 条）。
    final session = SshSession(
      profile: _profile(
        keyPath: _writeTemp(
          'id_rsa_corrupt',
          '-----BEGIN RSA PRIVATE KEY-----\n'
              'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n'
              '-----END RSA PRIVATE KEY-----\n',
        ),
      ),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    final failure = await _failureOf(session.connect());

    expect(failure.kind, ConnectionFailureKind.authFailed);
    expect(failure.message, contains('私钥'));
    expect(failure.message, contains('损坏'));
    // 关键：英文类名一个都不许漏 —— 这条用例存在的全部理由。
    expect(failure.message, isNot(contains('ASN1Exception')));
    expect(failure.message, isNot(contains('SSHKeyDecodeError')));
    expect(failure.message, isNot(contains('Instance of')));
    expect(failure.message, isNot(contains('Failed to decode')));
    // 也不能被误当成口令问题：那是另一个方向，用户会去翻一个不存在的口令。
    expect(failure.message, isNot(contains('口令')));
    // 原文不丢：整个异常挂在 `cause` 上（§13.19-1「永远不吞掉异常」）。
    // 少了这条断言，把 `cause: error` 删掉是一样的绿 —— 那才是真的吞了异常。
    expect(failure.cause, isA<SSHKeyDecodeError>());
  });

  test('私钥路径指向目录 → 中文 ConnectionFailure，不漏英文类名', () async {
    // 代码复审实测（2026-09-24，Linux）：`File(<目录>).readAsStringSync()`
    // 抛的是 **`FileSystemException`**（`Is a directory, errno = 21`），
    // **不是** `PathNotFoundException` —— 也就是说它会落到兜底，而兜底的
    // `原始信息：$error` 会把英文类名原样交给用户。
    //
    // 判据是"调用点不许漏"，不是"§13.19-9 那七种"：`FileSystemException`
    // 家族在这一行是**封闭且可枚举**的，一个用例就能钉住。
    final dir = Directory('${Directory.systemTemp.path}/wct_t4_${pid}_dir');
    dir.createSync(recursive: true);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final session = SshSession(
      profile: _profile(keyPath: dir.path),
      connector: _FailingConnector(Exception('不该走到这里')),
      hostKeyStore: InMemoryHostKeyStore(),
    );

    final failure = await _failureOf(session.connect());

    expect(failure.kind, ConnectionFailureKind.authFailed);
    expect(failure.message, contains('私钥'));
    expect(failure.message, contains(dir.path));
    // 关键：兜底那句会把 `FileSystemException: Cannot open file …` 带回来，
    // 所以这条断言在"新分支被删掉"时必红。
    expect(failure.message, isNot(contains('FileSystemException')));
    expect(failure.message, isNot(contains('errno')));
  });

  test(
    '私钥文件没有读权限 → 中文 ConnectionFailure（PathAccessException）',
    () async {
      // 代码复审实测（2026-09-24，Linux，非 root）：
      // `chmod 000` 之后 `File(path).readAsStringSync()` 抛
      // **`PathAccessException`**（`Permission denied, errno = 13`）——
      // `FileSystemException` 的**另一个**子类，同样不是
      // `PathNotFoundException`，同样会漏出英文类名。
      //
      // 这一条同时也证明新分支是**按家族**收的（`on FileSystemException`
      // 收得住子类），不是照着两个类名各写一支。
      final path = _writeTemp('id_rsa_locked', 'not a key at all\n');
      Process.runSync('chmod', ['000', path]);
      addTearDown(() {
        // 先恢复权限再删（teardown 是后进先出，这条排在 _writeTemp 的删除之后）。
        Process.runSync('chmod', ['600', path]);
      });

      final session = SshSession(
        profile: _profile(keyPath: path),
        connector: _FailingConnector(Exception('不该走到这里')),
        hostKeyStore: InMemoryHostKeyStore(),
      );

      final failure = await _failureOf(session.connect());

      expect(failure.kind, ConnectionFailureKind.authFailed);
      expect(failure.message, contains('私钥'));
      expect(failure.message, isNot(contains('PathAccessException')));
      expect(failure.message, isNot(contains('FileSystemException')));
    },
    skip: _canMakeUnreadable
        ? false
        : 'chmod 000 在本机不生效（Windows 或以 root 运行），这一支测不了',
  );
}
