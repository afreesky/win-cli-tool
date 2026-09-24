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

/// 与 [DirectConnector] 可区分：`const DirectConnector()` 会被规范化，
/// 用它做注入就分不清"转发了"和"没转发、用了默认值"。
class _FakeConnector implements Connector {
  const _FakeConnector();

  @override
  Future<Connection> open(String host, int port, {Duration? timeout}) =>
      throw UnimplementedError('本测试只验证注入是否被转发，不真的建连');
}

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
    const injected = _FakeConnector();
    final factory = SessionFactory(
      hostKeyStore: InMemoryHostKeyStore(),
      connectorResolver: (profile) => injected,
    );

    final session = factory.create(_profile(DeviceProtocol.ssh)) as SshSession;
    expect(identical(session.connector, injected), isTrue);
  });

  test('默认开着主机密钥校验（NFR-S-03）—— 这一行改成 false 就是全线静默裸奔', () {
    final factory = SessionFactory(hostKeyStore: InMemoryHostKeyStore());
    final session = factory.create(_profile(DeviceProtocol.ssh)) as SshSession;

    expect(session.verifyHostKey, isTrue);
  });

  test('构造参数逐个原样转交 SshSession（工厂只做转发，转错一个就是静默降级）', () {
    final store = InMemoryHostKeyStore();
    Future<bool> onUnknown(KnownHost host) async => true;
    const injected = _FakeConnector();
    const timeout = Duration(seconds: 7);

    final factory = SessionFactory(
      hostKeyStore: store,
      connectorResolver: (profile) => injected,
      connectTimeout: timeout,
      verifyHostKey: false,
      onUnknownHostKey: onUnknown,
    );

    final session = factory.create(_profile(DeviceProtocol.ssh)) as SshSession;
    expect(identical(session.hostKeyStore, store), isTrue);
    expect(identical(session.connector, injected), isTrue);
    expect(session.connectTimeout, timeout);
    expect(session.verifyHostKey, isFalse);
    expect(identical(session.onUnknownHostKey, onUnknown), isTrue);
  });

  test('Telnet 也拿到同一个 connector 与超时', () {
    const injected = _FakeConnector();
    const timeout = Duration(seconds: 7);
    final factory = SessionFactory(
      hostKeyStore: InMemoryHostKeyStore(),
      connectorResolver: (profile) => injected,
      connectTimeout: timeout,
    );

    final session =
        factory.create(_profile(DeviceProtocol.telnet)) as TelnetSession;
    expect(identical(session.connector, injected), isTrue);
    expect(session.connectTimeout, timeout);
  });
}
