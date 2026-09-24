import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:meta/meta.dart';

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
  /// 返回 true 表示接受并保存。为 null 时一律拒绝 —— 见 [_buildHostKeyCallback]。
  final Future<bool> Function(KnownHost host)? onUnknownHostKey;

  final String ptyType;
  final int ptyWidth;
  final int ptyHeight;

  final _output = StreamController<String>.broadcast();
  final _done = Completer<void>();

  /// 会话断开时保留错误对象（FR-C-06 / spec §13.12）。null 表示正常断开。
  Object? _lastError;

  ConnectionSocket? _socket;
  SSHClient? _client;
  SSHSession? _session;
  StreamSubscription<String>? _decodeSub;
  var _closed = false;

  /// 最近一次断开的原始错误。正常断开为 null。
  Object? get lastError => _lastError;

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  /// 构造 `SSHClient`。**只有这一处**给 `onVerifyHostKey` 传参 ——
  /// 单独成方法就是为了让那个传参点可以被直接断言（见 [debugBuildClient]
  /// 与 [debugLastBuiltClient]）。
  SSHClient _createClient(ConnectionSocket socket, List<SSHIdentity>? identities) {
    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities,
      onPasswordRequest: _onPasswordRequest,
      // 始终非 null，见 _buildHostKeyCallback 的说明。
      onVerifyHostKey: _buildHostKeyCallback(),
    );
    // 记在**唯一的构造点**上：只要 `connect()` 真的走这条路径，被记下的就是
    // 它手上那个 client。`connect()` 若改成自己内联一个 `SSHClient(…,
    // onVerifyHostKey: null)`，这里会**保持 null** —— 用例随即变红。
    debugLastBuiltClient = client;
    return client;
  }

  /// 仅供测试：**最近一次经 [_createClient] 造出来的那个** `SSHClient`。
  ///
  /// 与 [debugBuildClient] 的分工：后者让用例**自己**造一个 client 来断言形状
  /// （读到的是"工厂会造出什么"）；这一个记的是**实际造出来的那一个**，于是
  /// 用例可以让 `connect()` 自己跑一遍，再断言它手上那个 client 的
  /// `onVerifyHostKey` 非 null。
  ///
  /// 这个区别不是形式上的：复审实测过 —— 在 `connect()` 里**直接内联**一个
  /// `SSHClient(…, onVerifyHostKey: null)` 编译得过、而只钉 [debugBuildClient]
  /// 的用例**全部照绿**（那条路径根本没经过工厂）。内联的写法现在会让这里
  /// 保持 null，用例因此变红（见 Step 5 第 24 条）。
  @visibleForTesting
  SSHClient? debugLastBuiltClient;

  /// 仅供测试：用**与 [connect] 同一段代码**构造 `SSHClient` 并交出来。
  ///
  /// 存在的理由：让"回调有没有真的传下去"变成一条**直接断言**。
  /// 早先的 `debugHostKeyCallbackIsNull` 读的是 [_buildHostKeyCallback] 的
  /// 返回值 —— 那是代理断言：把传参点改成 `null`，它依然为真，而
  /// `onVerifyHostKey == null` 意味着 dartssh2 接受任意主机密钥
  /// （§13.14-1），即 FR-C-11 被整体旁路（NFR-S-03）而整套用例照绿。
  ///
  /// 传一条**假 `Connection` 不是假会话**：对端永远不说话，握手发不出也走不完
  /// —— 注意**不是"根本不会开始"**：`SSHClient` 的构造函数就会建起
  /// `SSHTransport`（其构造函数里 `_initSocket(); _startHandshake();`），
  /// 状态机确实启动了，只是对端不回答，它推进不下去。真服务端（首次询问 /
  /// 接受后落库 / 拒绝则连不上）仍然只有 Task 7 能验。
  SSHClient debugBuildClient(Connection conn, List<SSHIdentity>? identities) =>
      _createClient(ConnectionSocket(conn), identities);

  /// 构造传给 dartssh2 的主机密钥校验回调。
  ///
  /// **返回类型刻意非空**（`SSHHostkeyVerifyHandler`，不是它的 `?` 版本）：
  /// dartssh2 在回调为 null 时会把 `userVerified` 直接取 true，即接受任意
  /// 主机密钥（§13.14-1），也就是 FR-C-11 被整体旁路（NFR-S-03）。
  /// 非空返回类型让"传参点拿到 null"从一条**要人盯着的纪律**变成编译器的
  /// 静态拒绝 —— 校验关闭时返回的是恒真回调，让"校验被关掉了"在代码里
  /// 可见、可 grep、可评审，而不是藏在库的默认值里。
  SSHHostkeyVerifyHandler _buildHostKeyCallback() {
    if (!verifyHostKey) {
      // 显式的恒真回调，而不是 null。两者行为相同，但这一行可被 grep。
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
    // 入口守卫：**已关闭的会话绝不能再拨号。**
    //
    // 少了它，close() 之后再来一次 connect() 会照常向设备发起 TCP 连接，
    // 然后走下面那条 `if (_closed)` 分支正常返回 —— 一个已关闭的会话对外
    // 报"连上了"，用户切设备、关窗口之后任何一次迟到的 connect() 都会真的
    // 去连设备。放在最顶上也是为了让"私钥会不会被读"这类副作用一并免掉。
    if (_closed) return;

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

    final client = _createClient(socket, identities);
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
        // cancelOnError：与 TelnetSession 同一处写法。出错的流不会再产出，
        // 留着订阅只会让后续错误反复走同一段收尾（[_onError] 里那次
        // "记为断开"是幂等的，但没必要留着）。
        .listen(_output.add, onError: _onError, cancelOnError: true);

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
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法读取私钥文件：路径不存在。请检查设备设置里的私钥路径。\n$path',
      );
    } on UnsupportedError catch (error) {
      // dartssh2 用同一句话（`Unsupported key type: <PEM 头>`）盖住了**三种**
      // 方向完全不同的输入。实测（2026-09-24，Dart 3.12 / dartssh2 4.1.0，
      // 跑 `SSHKeyPair.fromPem`）：
      //
      //   -----BEGIN PUBLIC KEY-----            → `Unsupported key type: PUBLIC KEY`
      //   -----BEGIN PRIVATE KEY-----           → `Unsupported key type: PRIVATE KEY`
      //   -----BEGIN ENCRYPTED PRIVATE KEY----- → `Unsupported key type: ENCRYPTED PRIVATE KEY`
      //
      // 三种必须**分开说**：选错文件是用户操作错了、换一个就好；带口令是
      // 本版本缺口、得去掉口令；明文 PKCS#8 才是"格式不支持、去转格式"。
      // 混成一句"格式不支持"，用户会去反复确认自己的私钥没问题 ——
      // 与 §13.15 同一个坑。
      //
      // **判序不能反**：`ENCRYPTED PRIVATE KEY` **含有** `PRIVATE KEY` 子串，
      // 先判后者会把加密那一种吞掉，于是把一个只是带了口令的用户打发去
      // "转格式" —— 而转格式**治不好**带口令的私钥，方向是错的。
      final detail = error.message?.toString() ?? '';
      if (detail.contains('ENCRYPTED PRIVATE KEY')) {
        // 与下面 `on SSHKeyDecryptError` 那一支同一个方向、同一句话
        // （只是多带上路径）：**两处要一起改**。
        throw ConnectionFailure(
          ConnectionFailureKind.authFailed,
          '私钥已加密，本版本暂不支持带口令的私钥。'
          '请改用不带口令的私钥，或等待后续版本支持。\n$path',
        );
      }
      if (detail.contains('PUBLIC KEY')) {
        throw ConnectionFailure(
          ConnectionFailureKind.authFailed,
          '你选中的是**公钥**文件（-----BEGIN PUBLIC KEY-----），不是私钥。'
          '请改选同一目录下的私钥文件（通常是不带 .pub 后缀的那个）。\n$path',
        );
      }
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法使用这个私钥：$path\n'
        '这个私钥的格式（PKCS#8，-----BEGIN PRIVATE KEY-----）本版本暂不支持。'
        '请改用 PEM 格式的 RSA 私钥（-----BEGIN RSA PRIVATE KEY-----）。',
      );
    } on FileSystemException catch (error) {
      // `PathNotFoundException` 之上的整个家族：路径指向目录、没有读权限、
      // 设备忙/掉线…… 全是**本地配置问题**，同样不能让英文类名漏给用户。
      //
      // 实测（2026-09-24，Linux，非 root）：
      //   选到目录   → `FileSystemException`（`Is a directory, errno = 21`）
      //   chmod 000 → `PathAccessException`（`Permission denied, errno = 13`）
      // 两种都**不是** `PathNotFoundException`，也就是说都会落到兜底 ——
      // 而兜底的 `原始信息：$error` 正是那个"英文类名漏给用户"的洞。
      // 判据是"调用点不许漏"，不是"§13.19-9 那七种"：这一族在这一行是
      // 封闭的（就是 `FileSystemException` 及其子类）、可枚举、且不需要 sshd
      // 就能造出夹具。
      //
      // **顺序**：必须在 `on PathNotFoundException` **之后**（后者是
      // `FileSystemException` 的子类，先判会把它吞掉，方向就会从"路径不存在"
      // 退成"文件系统说…"），并排在 `on FormatException` 之前（I/O 一族
      // 放在一起读）。
      //
      // 只取 `osError`：`error.message` 是英文（`Cannot open file, path = …`），
      // 那正是要挡掉的东西；`osError` 没有时退回一句中文，不退回英文。
      final reason = error.osError?.message ?? '无法打开这个文件';
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法读取私钥：$path\n文件系统返回：$reason。'
        '请确认这个路径指向的是一个可读的私钥文件（不是目录，且当前用户有读权限）。',
        cause: error,
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
    } on SSHKeyDecodeError catch (error) {
      // 读不出私钥，但**不是**口令问题：密钥内容损坏 / 解析不了。实测
      // （2026-09-24，Dart 3.12 / dartssh2 4.1.0，跑 `SSHKeyPair.fromPem`）：
      //
      //   -----BEGIN RSA PRIVATE KEY----- + 一段垃圾 → `SSHKeyDecodeError(
      //       Failed to decode private key, Instance of 'ASN1Exception')`
      //   -----BEGIN RSA PRIVATE KEY----- + 空体   → `SSHKeyDecodeError(
      //       Failed to decode private key, RangeError (length): …)`
      //   -----BEGIN EC PRIVATE KEY----- + 垃圾    → 同上（`ASN1Exception`）
      //
      // 三种此前都掉进兜底，而兜底的 `原始信息：$error` 用的是
      // `SSHKeyDecodeError.toString()` = `'$runtimeType($message, $error)'`
      // （dartssh2 `lib/src/ssh_errors.dart:97-100`）—— 于是用户看到
      // `Instance of 'ASN1Exception'` 这种**英文类名**。判据是"调用点不许漏"
      // （见 [_identities] 的文档），不是"§13.19-9 那张表里的七种"。
      //
      // **这一支尤其要看紧**：上面 `PUBLIC KEY` / 明文 `PRIVATE KEY` 两句
      // 推荐的正是 `-----BEGIN RSA PRIVATE KEY-----`（PEM 格式的 RSA 私钥），
      // 也就是**这个分支接的形状** —— 用户照着本应用自己的建议去转格式，
      // 转坏一个文件，看到的那句话必须是中文，不能是 `ASN1Exception`。
      //
      // **顺序**：必须在 `on SSHKeyDecryptError` **之后** —— 后者
      // `extends SSHKeyDecodeError`（dartssh2 `ssh_errors.dart:104`），先判
      // 这一支会把"带口令"吞掉，方向就从"去掉口令"退成"文件坏了"，而用户
      // 照做也没用。这与 `connection_failure.dart:262-264` 记录的**同一处**
      // 顺序陷阱是同一个理由，只是那一边靠 `is` 判、这一边靠 `on` 判。
      //
      // 原文不丢：`cause: error` 带走整个异常对象（§13.19-1 的"永远不吞掉
      // 异常"）。不进 `message` 是因为 `message` 的契约就是"可直接展示给
      // 用户的中文说明"（connection_failure.dart:58-63）—— 认得出的形状给
      // 干净中文，认不出的才由兜底附原文。
      // （分类器里那一支给的是 `无法读取私钥：${error.message}`
      // （connection_failure.dart:275-285）—— 那里只有裸 `Object` 可用，
      // 这里知道上下文，能给得比它干净。**两处不一样是刻意的**。）
      throw ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '无法读取私钥：$path\n'
        '这个私钥文件读不出来：内容已损坏，或不是本程序认识的私钥格式。'
        '请确认它是一个完好的私钥文件（可以重新生成，或从原处再导出一次）。',
        cause: error,
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

  /// 解码后的输出流报错 —— 一次**断开**，不是一条可以忽略的日志。
  ///
  /// 只记进 `_lastError` 是错的：`session.done` 若一直不完成，会话对外
  /// **看着还是活的**，但再也不会有任何输出 —— 上层既不显示断线、也不重连，
  /// 用户的终端就那么定住。所以走与 [session.done] 相同的收尾
  /// （[_onDisconnected] 里同样带 `_closed` 守卫：主动关闭之后流上的收尾
  /// 事件不许把它再报成一次断线）。
  void _onError(Object error, StackTrace _) => _onDisconnected(error);

  /// 仅供测试：模拟解码后的输出流报错。
  ///
  /// 那条路径要在真的握完手、真的建起 shell 之后才可能触发，而这一层
  /// （Task 4）没有能连上的会话（Task 7 才有），所以只能从这个缝进来。
  void debugReportOutputError(Object error) =>
      _onError(error, StackTrace.current);

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

    // **清理必须逐步走完**：下面任何一步抛错，都不许把后面的步骤跳掉。
    // 最要命的是 `await _client?.close()`（设备刚掐了 TCP 时它会带着错误
    // 返回）：原实现是四行直笔的顺序代码，它一抛，`_socket?.dispose()` 与
    // `_output.close()` 就都不执行 —— 广播 controller 永不关闭，订阅方
    // （会话列表、终端视图）永远等不到"结束"这个信号。这与那三条空路径
    // 用例守的是同一类失败（"抛在这里应用就退不掉"），只是发生在非空路径上。
    //
    // 每一步单独接住，最后把**第一个**错误原样抛出去：吞掉异常同样是
    // 这个项目不允许的（§13.19-1）。
    Object? firstError;
    StackTrace? firstStack;
    void capture(Object error, StackTrace stack) {
      firstError ??= error;
      firstStack ??= stack;
    }

    try {
      await _decodeSub?.cancel();
    } catch (error, stack) {
      capture(error, stack);
    }
    try {
      _session?.close();
    } catch (error, stack) {
      capture(error, stack);
    }
    try {
      await _client?.close();
    } catch (error, stack) {
      capture(error, stack);
    }
    try {
      _socket?.dispose();
    } catch (error, stack) {
      capture(error, stack);
    }
    // 不 await：_output 是**广播** controller，close() 即使无人监听也会
    // 立刻完成，所以这里改成 await 也不会挂 —— 留 unawaited 只是不想在
    // 关闭路径上等一个无意义的 future。真正会永不完成的是**单订阅**
    // controller，那是 ConnectionSocket 的 _stream / _sink（§13.11），
    // 与本类无关（见类文档）。
    try {
      unawaited(_output.close());
    } catch (error, stack) {
      capture(error, stack);
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }
}
