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
    if (keyType.contains(':')) {
      throw ArgumentError.value(
        keyType,
        'keyType',
        '算法名不能含冒号：identity 用冒号拼接，含冒号的算法名会和另一组 '
            '(host, port, keyType) 拼出同一个键，两条记录塌成一条',
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
  /// 主机密钥变更（见 spec §13.5）。
  ///
  /// 前提：`keyType` 不含冒号（构造函数强制）。dartssh2 的算法名
  /// （`ssh-ed25519`、`rsa-sha2-256` 等七个）都不含，所以这个拼法无歧义 ——
  /// IPv6 字面量主机（`::1`）也安全，因为 `port` 一定是纯数字段。
  /// 含冒号的算法名会让两组三元组拼出同一个键，构造函数直接拒绝。
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

  /// 删除这一条记录。
  ///
  /// **不是可选项。** 设备确实更换过主机密钥时，[find] 会一直返回旧指纹，
  /// 于是这台设备被**永久**拒绝连接；计划 3 的错误文案正是让用户
  /// "在设置中清除该主机的记录后重连"。接口少了这个方法，那句话就是在
  /// 教用户做一件做不到的事 —— 而"主机密钥变了"恰恰是唯一一个
  /// 用户绝不能学会忽略的警告。
  Future<void> remove(String host, int port, String keyType);
}

/// 内存实现，供测试与"不持久化"的场景使用。
class InMemoryHostKeyStore implements HostKeyStore {
  final _byIdentity = <String, KnownHost>{};

  /// 已保存记录的快照，供断言。
  List<KnownHost> get all => List.unmodifiable(_byIdentity.values);

  /// 仓库自己的查键。**必须与 [KnownHost.identity] 逐字一致** —— 两边各改
  /// 各的会让 [find] / [remove] 永远找不到记录，于是每次连接都被当成
  /// "首次连接"，已经变过密钥的主机也会被重新 TOFU 接受。测试里有一条
  /// 专门守这个跨类不变式。
  String _key(String host, int port, String keyType) => '$host:$port:$keyType';

  @override
  Future<KnownHost?> find(String host, int port, String keyType) async =>
      _byIdentity[_key(host, port, keyType)];

  @override
  Future<void> remove(String host, int port, String keyType) async {
    _byIdentity.remove(_key(host, port, keyType));
  }

  @override
  Future<void> save(KnownHost host) async {
    _byIdentity[host.identity] = host;
  }
}
