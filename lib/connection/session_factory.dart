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
///
/// 同步是**有意为之**：跳板机链在内存里解析，构造路径上不做 IO。
/// 将来若真需要异步查表（例如按需取凭据），改动点就是这里，不是别处。
typedef ConnectorResolver = Connector Function(DeviceProfile profile);

Connector _directConnector(DeviceProfile _) => const DirectConnector();

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

  /// 是否校验主机密钥（FR-C-11）。默认开启（NFR-S-03）。
  ///
  /// 这一行决定**每一台设备**的安全姿态，不是可选的舒适项。
  final bool verifyHostKey;

  /// 首次连接某主机时询问用户是否接受该指纹。
  /// 返回 true 表示接受并保存。为 null 时一律拒绝 —— 见 [SshSession.onUnknownHostKey]。
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
