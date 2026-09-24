/// 一条已确认的主机密钥记录（TOFU，首次使用即信任）。
///
/// 持久化由调用方负责 —— 计划 2 只定义模型，写盘留给计划 4 的 store，
/// 中间通过 [HostKeyStore] 接口注入（spec §13.5）。
class KnownHost {
  KnownHost({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  }) {
    if (fingerprint.isEmpty) {
      throw ArgumentError.value(
        fingerprint,
        'fingerprint',
        '指纹不能为空：空指纹会让"不匹配"恒为真，把每次连接都判成密钥变更',
      );
    }
  }

  final String host;
  final int port;

  /// 主机密钥算法名，如 `ssh-ed25519` / `rsa-sha2-256`。
  final String keyType;

  /// 形如 `SHA256:<base64>`，dartssh2 直接给出，无需自己算。
  final String fingerprint;

  /// 记录的唯一标识。**必须包含 keyType** —— 同一主机同时提供多种算法时，
  /// 每把密钥的指纹都不同，只按 host:port 存会把正常的算法协商误报成
  /// 主机密钥变更（见本 Task 开头的说明）。
  String get identity => '$host:$port:$keyType';

  factory KnownHost.fromJson(Map<String, Object?> json) => KnownHost(
        host: json['host']! as String,
        port: json['port']! as int,
        keyType: json['keyType']! as String,
        fingerprint: json['fingerprint']! as String,
      );

  Map<String, Object?> toJson() => {
        'host': host,
        'port': port,
        'keyType': keyType,
        'fingerprint': fingerprint,
      };
}

/// 已知主机密钥的存储。**由外部注入**，计划 2 不提供文件实现。
///
/// spec §13.5：FR-C-11 要求"确认后保存"，但持久化边界属于计划 4。
/// 若计划 2 自己写文件，持久化就会漏成两处。
abstract class HostKeyStore {
  /// 查这条记录；没有则返回 null。
  Future<KnownHost?> find(String host, int port, String keyType);

  /// 保存（同一 [KnownHost.identity] 视为覆盖）。
  Future<void> save(KnownHost host);
}

/// 内存实现，供测试与"不持久化"的场景使用。
class InMemoryHostKeyStore implements HostKeyStore {
  final _byIdentity = <String, KnownHost>{};

  /// 已保存记录的快照，供断言。
  List<KnownHost> get all => List.unmodifiable(_byIdentity.values);

  @override
  Future<KnownHost?> find(String host, int port, String keyType) async =>
      _byIdentity['$host:$port:$keyType'];

  @override
  Future<void> save(KnownHost host) async {
    _byIdentity[host.identity] = host;
  }
}
