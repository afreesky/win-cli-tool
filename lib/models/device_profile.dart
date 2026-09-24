/// 设备登录协议。
enum DeviceProtocol {
  ssh,
  telnet;

  /// JSON 中的字符串转枚举。未知名称直接抛错，避免静默降级成错误的协议。
  static DeviceProtocol fromName(String name) => DeviceProtocol.values.firstWhere(
        (p) => p.name == name,
        orElse: () => throw FormatException('未知的设备协议: $name'),
      );

  /// 该协议的默认端口。
  int get defaultPort => this == DeviceProtocol.ssh ? 22 : 23;
}

/// 「调用方没传这个参数」的哨兵，用来区分它与「调用方显式传了 null」。
///
/// [DeviceProfile.password]、[DeviceProfile.privateKeyPath] 与
/// [DeviceProfile.promptRegex] 的 null 都是有语义的值（不启用密码认证 /
/// 不启用密钥认证 / 用全局默认提示符正则），不能被 `?? this.x` 吞掉：
/// 否则用户清空密码改用密钥认证后，旧密码仍留在明文配置里，且界面上
/// 再没有任何地方能看到它。
const Object _unset = Object();

/// 一条可复用的命令片段，归属于单台设备。
class Snippet {
  const Snippet({required this.id, required this.name, required this.content});

  final String id;
  final String name;
  final String content;

  Snippet copyWith({String? name, String? content}) => Snippet(
        id: id,
        name: name ?? this.name,
        content: content ?? this.content,
      );

  factory Snippet.fromJson(Map<String, Object?> json) => Snippet(
        id: json['id']! as String,
        name: json['name']! as String,
        content: json['content']! as String,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'content': content,
      };
}

/// 一台 SSH 跳板机（堡垒机）。全局共享，设备通过 id 引用。
class JumpHost {
  const JumpHost({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKeyPath,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPath;

  JumpHost copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    Object? password = _unset,
    Object? privateKeyPath = _unset,
  }) =>
      JumpHost(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password:
            identical(password, _unset) ? this.password : password as String?,
        privateKeyPath: identical(privateKeyPath, _unset)
            ? this.privateKeyPath
            : privateKeyPath as String?,
      );

  factory JumpHost.fromJson(Map<String, Object?> json) => JumpHost(
        id: json['id']! as String,
        name: json['name']! as String,
        host: json['host']! as String,
        port: json['port']! as int,
        username: json['username']! as String,
        password: json['password'] as String?,
        privateKeyPath: json['privateKeyPath'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'privateKeyPath': privateKeyPath,
      };
}

/// 一台被管理的网络设备。
class DeviceProfile {
  const DeviceProfile({
    required this.id,
    required this.name,
    required this.protocol,
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKeyPath,
    this.jumpHostIds = const [],
    this.lineEnding = '\n',
    this.promptRegex,
    this.postLoginCommands = const [],
    this.autoConnect = false,
    this.snippets = const [],
  });

  final String id;
  final String name;
  final DeviceProtocol protocol;
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPath;

  /// 跳板机链，有序。空表示直连。
  final List<String> jumpHostIds;

  /// 命令行尾符，默认 '\n'，部分老设备需要 '\r\n'。
  final String lineEnding;

  /// 该设备专用的提示符正则；null 表示用全局默认值。
  final String? promptRegex;

  /// 登录成功（含每次重连成功）后自动依次下发的命令。
  final List<String> postLoginCommands;

  final bool autoConnect;
  final List<Snippet> snippets;

  DeviceProfile copyWith({
    String? name,
    DeviceProtocol? protocol,
    String? host,
    int? port,
    String? username,
    Object? password = _unset,
    Object? privateKeyPath = _unset,
    List<String>? jumpHostIds,
    String? lineEnding,
    Object? promptRegex = _unset,
    List<String>? postLoginCommands,
    bool? autoConnect,
    List<Snippet>? snippets,
  }) =>
      DeviceProfile(
        id: id,
        name: name ?? this.name,
        protocol: protocol ?? this.protocol,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password:
            identical(password, _unset) ? this.password : password as String?,
        privateKeyPath: identical(privateKeyPath, _unset)
            ? this.privateKeyPath
            : privateKeyPath as String?,
        jumpHostIds: jumpHostIds ?? this.jumpHostIds,
        lineEnding: lineEnding ?? this.lineEnding,
        promptRegex: identical(promptRegex, _unset)
            ? this.promptRegex
            : promptRegex as String?,
        postLoginCommands: postLoginCommands ?? this.postLoginCommands,
        autoConnect: autoConnect ?? this.autoConnect,
        snippets: snippets ?? this.snippets,
      );

  factory DeviceProfile.fromJson(Map<String, Object?> json) => DeviceProfile(
        id: json['id']! as String,
        name: json['name']! as String,
        protocol: DeviceProtocol.fromName(json['protocol']! as String),
        host: json['host']! as String,
        port: json['port']! as int,
        username: json['username']! as String,
        password: json['password'] as String?,
        privateKeyPath: json['privateKeyPath'] as String?,
        jumpHostIds: (json['jumpHostIds'] as List<Object?>? ?? const [])
            .cast<String>(),
        lineEnding: json['lineEnding'] as String? ?? '\n',
        promptRegex: json['promptRegex'] as String?,
        postLoginCommands:
            (json['postLoginCommands'] as List<Object?>? ?? const [])
                .cast<String>(),
        autoConnect: json['autoConnect'] as bool? ?? false,
        snippets: (json['snippets'] as List<Object?>? ?? const [])
            .map((e) => Snippet.fromJson((e! as Map).cast<String, Object?>()))
            .toList(growable: false),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'privateKeyPath': privateKeyPath,
        'jumpHostIds': jumpHostIds,
        'lineEnding': lineEnding,
        'promptRegex': promptRegex,
        'postLoginCommands': postLoginCommands,
        'autoConnect': autoConnect,
        'snippets': snippets.map((s) => s.toJson()).toList(growable: false),
      };
}
