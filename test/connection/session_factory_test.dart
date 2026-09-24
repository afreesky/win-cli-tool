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
