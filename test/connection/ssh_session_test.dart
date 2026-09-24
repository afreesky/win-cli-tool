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
