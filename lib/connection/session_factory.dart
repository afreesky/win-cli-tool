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
