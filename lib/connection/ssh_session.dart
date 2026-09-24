import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/device_profile.dart';
import 'connection_failure.dart';
import 'connection_socket.dart';
import 'connector.dart';
import 'known_host.dart';
import 'session.dart';

/// 基于 dartssh2 的 SSH 会话实现。
///
/// 与 [TelnetSession] 的结构差异：这里不需要"原始字节 → 文本"的中间
/// controller，直接把 `session.stdout` 解码进 `_output` 即可。因此本类
/// **没有**单订阅 controller，spec §13.11 的挂起风险不存在。
class SshSession implements Session {
  SshSession({
    required this.profile,
    this.connector = const DirectConnector(),
    required this.hostKeyStore,
    this.connectTimeout = const Duration(seconds: 15),
    this.verifyHostKey = true,
    this.onUnknownHostKey,
    this.ptyType = 'xterm',
    this.ptyWidth = 120,
    this.ptyHeight = 40,
    this.pollInterval = const Duration(milliseconds: 250),
  });

  final DeviceProfile profile;

  /// 建连方式。默认直连；计划 3 会注入带跳板机的实现。
  final Connector connector;

  /// 已知主机密钥存储。**由外部注入**（spec §13.5）。
  final HostKeyStore hostKeyStore;

  final Duration connectTimeout;

  /// 是否校验主机密钥（FR-C-11）。默认开启（NFR-S-03）。
  final bool verifyHostKey;

  /// 首次连接某主机时询问用户是否接受该指纹。
  /// 返回 true 表示接受并保存。为 null 时一律拒绝 —— 见 [_verifyHostKey]。
  final Future<bool> Function(KnownHost host)? onUnknownHostKey;

  final String ptyType;
  final int ptyWidth;
  final int ptyHeight;

  /// 重连时的探活间隔（TCP keepalive 由 dartssh2 的 keepAliveInterval 负责）。
  final Duration pollInterval;

  final _output = StreamController<String>.broadcast();
  final _done = Completer<void>();

  /// 会话断开时保留错误对象（FR-C-06 / spec §13.12）。null 表示正常断开。
  Object? _lastError;

  ConnectionSocket? _socket;
  SSHClient? _client;
  SSHSession? _session;
  StreamSubscription<String>? _decodeSub;
  var _closed = false;

  /// 供测试断言"校验关闭时也没有把 null 传下去"。
  ///
  /// **这是一条代理断言，别读成"接线已验证"**：它读的是
  /// [_buildHostKeyCallback] 的返回值，而不是真正交给 `SSHClient` 的那个值 ——
  /// 把 [connect] 里的 `onVerifyHostKey:` 改成 null，它依然为真。真正锁住
  /// 接线的是 Task 7 的真 sshd 用例：回调为 null 时 dartssh2 接受任意主机
  /// 密钥（§13.14-1），于是"用户拒绝指纹则连不上"那条会失败。
  bool get debugHostKeyCallbackIsNull => _buildHostKeyCallback() == null;

  /// 最近一次断开的原始错误。正常断开为 null。
  Object? get lastError => _lastError;

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  /// 构造传给 dartssh2 的主机密钥校验回调。
  ///
  /// **返回 null 的情况被刻意排除**：dartssh2 在回调为 null 时会把
  /// `userVerified` 直接取 true，即接受任意主机密钥（§13.14-1）。
  /// 因此这里总是返回一个非 null 回调 —— 校验关闭时返回恒真回调，
  /// 让"校验被关掉了"在代码里是可见的。
  Future<bool> Function(String, Uint8List)? _buildHostKeyCallback() {
    if (!verifyHostKey) {
      // 显式的恒真回调，而不是 null。两者行为相同，但这一行可被 grep、
      // 可被评审看见；null 则藏在库的默认值里。
      return (String type, Uint8List fingerprint) async => true;
    }
    return (String type, Uint8List fingerprint) async {
      final candidate = KnownHost(
        host: profile.host,
        port: profile.port,
        keyType: type,
        fingerprint: utf8.decode(fingerprint, allowMalformed: true),
      );

      final known = await hostKeyStore.find(
        candidate.host,
        candidate.port,
        candidate.keyType,
      );

      if (known != null) {
        // 指纹不一致：可能是设备换过密钥，也可能是中间人。
        // 一律拒绝，由用户去设置里清除旧记录后重连。
        return known.fingerprint == candidate.fingerprint;
      }

      final accept = await onUnknownHostKey?.call(candidate) ?? false;
      if (accept) {
        await hostKeyStore.save(candidate);
      }
      return accept;
    };
  }

  @override
  Future<void> connect() async {
    // **先加载私钥，再开 socket。** 两个理由：
    //   1. 私钥读不出来是**本地配置错误**，与网络无关。让它先失败，就不必为
    //      一个注定连不上的会话开连接；否则 `_socket` 已赋值、`_client` 还没建，
    //      会出现第三种"半初始化"状态（另两种见下面两处 `if (_closed)` 守卫）。
    //   2. 这让"私钥翻译"这条路径**不需要假 SSH 服务端就能测**：用一个必然
    //      失败的 connector 就能证明它**先**失败（见 Step 1 的用例）。Task 4
    //      的其余几条要么不碰网络、要么留给 Task 7，唯有这一条既重要又可测。
    final identities = _identities();

    final conn = await connector.open(
      profile.host,
      profile.port,
      timeout: connectTimeout,
    );
    // 建连期间可能已经被 close()（用户切设备、关窗口）。与 TelnetSession
    // 同样的守卫：把刚拿到的连接关掉直接返回，否则资源泄漏。
    if (_closed) {
      await conn.close();
      return;
    }

    // 不保留 conn 字段：它的生命周期由 ConnectionSocket 持有并负责释放
    // （见 close() 里的 _socket?.dispose()）。多存一份只会带来"两份引用、
    // 一处释放"的不一致。
    final socket = ConnectionSocket(conn);
    _socket = socket;

    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities,
      onPasswordRequest: _onPasswordRequest,
      // 始终非 null，见 _buildHostKeyCallback 的说明。
      onVerifyHostKey: _buildHostKeyCallback(),
    );
    _client = client;

    await client.authenticated;

    // 认证期间也可能被 close()。
    if (_closed) {
      await client.close();
      socket.dispose();
      return;
    }

    final session = await client.shell(
      pty: SSHPtyConfig(type: ptyType, width: ptyWidth, height: ptyHeight),
    );
    if (_closed) {
      session.close();
      await client.close();
      socket.dispose();
      return;
    }
    _session = session;

    // .cast<List<int>>() 不能省：stdout 是 Stream<Uint8List>，而
    // Stream.transform 按**运行时**类型校验 transformer，直接 transform
    // 会抛 "type 'Utf8Decoder' is not a subtype of type
    // 'StreamTransformer<Uint8List, String>'"。与计划 1 connector.dart
    // 记录的是同一个协变陷阱。
    _decodeSub = session.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_output.add, onError: _onError);

    // done 的转发必须带守卫：client.close() 会完成 session.done，
    // 不守卫的话"主动关闭"会被看成一次意外断线，触发自动重连。
    session.done.then(
      (_) => _onDisconnected(null),
      onError: (Object e, StackTrace _) => _onDisconnected(e),
    );
  }

  /// 加载私钥，并把**本地能判定的失败**翻译成中文的 [ConnectionFailure]。
  ///
  /// §13.19-9 记录了七种实测的 `fromPem` 失败形态，分类器**认不出**其中三种：
  /// 它只拿到一个裸 `Object`，无从知道某个 `FormatException` 来自"读私钥"还是
  /// 别处（`SSHPacketError` 在传输层有 18 个抛出点，`FormatException` 遍布
  /// `dart:core`）。上下文只有这里知道，所以翻译必须在**调用点**做。
  ///
  /// 分类器对 [ConnectionFailure] 是幂等的（§13.19-10），这里直接抛即可。
  ///
  /// **判据是"这一层不许漏"，不是"覆盖 §13.19-9 表里那七种"** —— 那张表是照着
  /// 实测输入列的、未必穷尽，所以末尾必须留一个兜底 `catch`。
  List<SSHIdentity>? _identities() {
    final path = profile.privateKeyPath;
    if (path == null || path.isEmpty) return null;

    try {
      final pem = File(path).readAsStringSync();
      // 这里不处理带口令的私钥：口令要从凭据接口取，属于计划 4。
      return SSHKeyPair.fromPem(pem);
    } on PathNotFoundException {
      // 最可能发生的一种（路径打错、文件被挪走）—— 单独一支，方向最明确。
      // 其余 I/O 失败（选到了目录、权限不足）不单独设支：它们会落到下面的
      // 兜底，那条同样带上路径与原文，而兜底已经有用例钉住（见 Step 1）。
      // **不为没有用例的支数写代码** —— 写一条没人守的分支，就是给后来人
      // 留一条可以静默改坏的路径。
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法读取私钥文件：路径不存在。请检查设备设置里的私钥路径。\n$path',
      );
    } on UnsupportedError {
      // 公钥文件，或本版本不支持的 PKCS#8（明文与加密都落在这里）。
      // **两种原因必须分开说**：选错文件是用户操作错了、换一个就好；
      // 格式不支持是本版本的缺口。混成一句"格式不支持"，用户会去反复确认
      // 自己的私钥没问题 —— 与 §13.15 同一个坑。
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法使用这个私钥：$path\n'
        '两个常见原因：选中的是公钥文件（.pub），'
        '或这个私钥格式（PKCS#8）本版本暂不支持。'
        '请选择 PEM 格式的 RSA 私钥（-----BEGIN RSA PRIVATE KEY-----）。',
      );
    } on FormatException {
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法解析这个文件：$path\n它看起来不是 PEM 格式的私钥。',
      );
    } on SSHKeyDecryptError {
      // 带口令的 OPENSSH 私钥。**分类器也认得这一支**（§13.19-9 论证过：这两个
      // 类的抛出点全关在 dartssh2 的 `lib/src/key_pair/` 里，全局映射是安全的），
      // 所以这里是一次**刻意的重复**。理由是维持一条可检验的不变量：
      //
      //   **`connect()` 不该为本地密钥问题漏出非 `ConnectionFailure` 的异常。**
      //
      // 若改成 `rethrow` 放行给分类器，用户看到什么就取决于调用方有没有记得
      // 分类 —— 而 §13.19-7 那个 `null` 泄漏正是这样一层一层漏过去的。
      // 下面这句话与分类器里那一句是同一句，**两处要一起改**。
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '私钥已加密，本版本暂不支持带口令的私钥。'
        '请改用不带口令的私钥，或等待后续版本支持。',
      );
    } catch (error) {
      // 兜底：损坏的 OPENSSH（`SSHPacketError`）、带口令的 PKCS#1
      // （`ArgumentError`），以及 §13.19-9 还没量到的形态。**这一支不能省** ——
      // 省了它们就漏到分类器，用户看到英文类名，其中 `SSHPacketError` 还会被
      // 报成"协议错误"，把方向指到算法上去。
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法读取私钥：$path\n原始信息：$error',
        cause: error,
      );
    }
  }

  FutureOr<String?> _onPasswordRequest() => profile.password;

  void _onError(Object error, StackTrace _) {
    _lastError = error;
  }

  void _onDisconnected(Object? error) {
    // §13.14-5：主动 close() 也会走到这里（client.close() 完成 done），
    // 必须靠 _closed 区分，否则退出应用会触发一轮自动重连。
    if (_closed) return;
    if (error != null) _lastError = error;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void write(String text) {
    if (_closed) return;
    _session?.write(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    // 必须在关 client 之前置位，否则 client.close() 完成的 session.done
    // 会被当成意外断线。
    _closed = true;

    await _decodeSub?.cancel();
    _session?.close();
    await _client?.close();
    _socket?.dispose();

    // 不 await：_output 是**广播** controller，close() 即使无人监听也会
    // 立刻完成，所以这里改成 await 也不会挂 —— 留 unawaited 只是不想在
    // 关闭路径上等一个无意义的 future。真正会永不完成的是**单订阅**
    // controller，那是 ConnectionSocket 的 _stream / _sink（§13.11），
    // 与本类无关（见类文档）。
    unawaited(_output.close());
  }
}
