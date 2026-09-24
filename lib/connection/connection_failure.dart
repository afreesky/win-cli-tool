import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

/// 失败原因分类。FR-C-06 列举的五种原因都在这里（连接超时 / 认证失败 /
/// 主机不可达 / 协议错误 / 跳板机失败），[hostKey] 是 §13.15 额外要求单独
/// 区分出来的第六种，[unknown] 是兜底。
enum ConnectionFailureKind {
  /// 连接超时（FR-C-13，默认 15s）。
  ///
  /// **两个来源都要认。** `Socket.connect(timeout:)` 到点后抛的是
  /// `SocketException`（errno ETIMEDOUT）—— 那才是 FR-C-13 在真实网络上的
  /// 形态；`TimeoutException` 是另一个来源。只认后者的话，最常见的那条
  /// 失败路径会被归成 [unreachable]，还会把英文原文当成中文说明交给用户。
  /// 详见 `_classify` 里 `SocketException` 那一支。
  timeout,

  /// 认证失败：口令或密钥不对，或私钥根本读不出来
  /// （见 `_classify` 的 `SSHKeyDecodeError` 分支）。
  authFailed,

  /// 主机密钥未通过校验：指纹与已知记录不一致，或用户拒绝了首次确认。
  ///
  /// **与 [authFailed] 分开是必须的** —— 用户对这两者的处理完全不同：
  /// 前者要去确认指纹（或警惕中间人），后者才要去查口令。
  hostKey,

  /// 主机不可达：拒绝连接、DNS 解析失败、路由不可达。
  unreachable,

  /// 协议错误：版本协商失败、算法协商失败（含设备只提供已被淘汰的算法）。
  protocolError,

  /// 跳板机失败。message 中会指明是第几跳（FR-J-05）。
  jumpHostFailed,

  /// 未归类的异常。**永远不会把异常吞掉** —— 原始对象在 [ConnectionFailure.cause]。
  unknown,
}

/// 跳板机上下文。用于把失败定位到具体某一跳（FR-J-05）。
///
/// [index] 从 1 开始，与用户看到的「第 1 跳」一致。
class JumpHop {
  const JumpHop({required this.index, required this.name});

  final int index;
  final String name;
}

/// 一次可读的连接失败。
class ConnectionFailure implements Exception {
  const ConnectionFailure(this.kind, this.message, {this.cause});

  final ConnectionFailureKind kind;

  /// 可直接展示给用户的中文说明。
  ///
  /// **例外：[ConnectionFailureKind.unknown]。** 那一种按设计就是原始异常的
  /// `$error`（英文、带 Dart 类名）：对一个没预料到的异常，细节编不出来，
  /// 而 §13.19-1 要求"永远不吞掉异常"。原文同时也留在 [cause] 里。
  final String message;

  /// 原始异常对象。用于日志与排查，不展示给用户。
  final Object? cause;

  @override
  String toString() => 'ConnectionFailure(${kind.name}): $message';
}

/// `ETIMEDOUT` 的 errno。**Linux 是 110，Windows 是 10060（`WSAETIMEDOUT`）。**
///
/// 110 是在本机（Linux）连黑洞地址实测出来的（`Socket.connect(timeout:)` 到点后
/// 抛 `SocketException ... errno = 110`，**不是** `TimeoutException`），并与
/// `/usr/include/asm-generic/errno.h:93` 一致。10060 取自 Winsock 的文档值 ——
/// 本机是 Linux，无法实测；但 Windows 是本程序的主要目标平台，漏掉它恰好会让
/// 那一边的用户看不到「超时」。
///
/// **这个常数不叫 `_etimedoutPosix`，是故意的。** macOS/Darwin 的 `ETIMEDOUT`
/// 是 60（XNU 头文件值，**文档来源，本机无法实测**），叫 POSIX 会让人以为 110
/// 是所有 POSIX 系统的值。macOS 不在 NFR-P-01 的目标平台里（Windows + Linux），
/// 所以这里不认 60 —— 但**别把这条读成"POSIX 通用"**。
const int _etimedoutLinux = 110;
const int _etimedoutWindows = 10060;

/// 超时文案。**只写一份**：`TimeoutException` 与 `SocketException` 的 errno
/// 判定两条路径都要用它，复制两份就会有一天悄悄不一致 —— 同一种失败，
/// 用户看到两种说法（实测过：只改其中一份，26 条用例全绿）。
const String _timeoutMessage = '连接超时：目标设备在超时时间内没有响应';

/// 把任意异常归类成 [ConnectionFailure]。
///
/// **判据是 `SSHAuthAbortError.reason`，不是顶层类型或消息文本** ——
/// 主机密钥被拒与算法协商失败抛出的异常类型与 toString 完全相同
/// （spec §13.15），只有 reason 不同。
ConnectionFailure classifyConnectionFailure(Object error, {JumpHop? hop}) {
  // **幂等。** 调用点可能比分类器更清楚上下文（例如 `SshSession` 读私钥
  // 文件时，它知道失败发生在"加载私钥"，而分类器只拿到一个裸
  // `FileSystemException`，无从判断）。那就允许它直接构造好
  // [ConnectionFailure] 再抛出来，这里原样返回 —— 不再包一层。
  // 少了这一支，那个对象会掉进 `unknown`，变成
  // 「连接失败：ConnectionFailure(authFailed): 无法读取私钥…」，
  // 用户看到两层面具，而且第一层是英文。
  if (error is ConnectionFailure) {
    if (hop == null) return error;
    // 跳板机的失败发生在哪一跳，仍然优先于内层原因（FR-J-05）。
    return ConnectionFailure(
      ConnectionFailureKind.jumpHostFailed,
      '第 ${hop.index} 跳 ${hop.name} 失败：${error.message}',
      cause: error,
    );
  }

  final inner = _classify(error);

  // 跳板机上下文优先：无论内层是什么原因，只要失败发生在某一跳上，
  // 用户首先要看到的是"哪一跳"，其次才是原因（FR-J-05）。
  if (hop != null) {
    return ConnectionFailure(
      ConnectionFailureKind.jumpHostFailed,
      '第 ${hop.index} 跳 ${hop.name} 失败：${inner.message}',
      cause: error,
    );
  }
  return ConnectionFailure(inner.kind, inner.message, cause: error);
}

ConnectionFailure _classify(Object error) {
  // **幂等要在这里再判一次。** 下面 `is SSHSocketError` 那一支会**递归**回
  // 本函数（`_classify(error.error)`），那次递归不经过
  // [classifyConnectionFailure] 顶部的幂等判断。少了这一处，
  // `SSHSocketError(ConnectionFailure(authFailed, …))` 会重新掉进 `unknown`，
  // 得到「连接失败：ConnectionFailure(authFailed): …」—— 正是幂等分支要
  // 避免的双层面具。今天 `DirectConnector` 只抛 `SocketException`，所以还
  // 够不到；但计划 3 的隧道/跳板机连接器就会产出这个形状（实测过）。
  if (error is ConnectionFailure) return error;

  if (error is TimeoutException) {
    // 这一支是**防御性**的，而且比原先写的更"死"。原先这里说 dartssh2 在
    // 握手/认证超时时抛 `SSHHandshakeError('Handshake timed out')` 与
    // `SSHAuthAbortError('Authentication timed out')` —— 但那两条只在 dartssh2
    // **自己设了超时定时器**时才成立，而 `handshakeTimeout` 与 `authTimeout`
    // 的默认值都是 null（ssh_client.dart:299-302），V1 的 `lib/` 里**没有任何
    // 一处**设过它们（grep 零命中）。所以那两条路径今天都到不了。
    //
    // 真正撑起 FR-C-13 的只有下面 `SocketException` 那一支的 errno 判定 ——
    // 别把这一支的绿色读成"超时路径已验证"。
    //
    // **给将来动手的人：** 谁要是给 `SSHClient` 设了 `handshakeTimeout`，超时就会
    // 变成 `SSHHandshakeError('Handshake timed out')`，落进下面
    // `is SSHHandshakeError` 那一支 → 报成 `protocolError`，文案说"对端可能不是
    // SSH 服务" —— 那正是 §13.15 要防的"把超时说成协议问题"。设之前先在这里补一支。
    //
    // `reason` 为 null 的来源有两处：:1126（认证超时，需要上面那个定时器）与
    // :964 配 :321 的 `_handleTransportClosed(null)`（认证前对端干净地关掉 TCP）。
    // **后一种是今天唯一活的。** 两者都落到下面"认不出的 reason"那条兜底。
    return ConnectionFailure(
      ConnectionFailureKind.timeout,
      _timeoutMessage,
      cause: error,
    );
  }

  // 两条顺序纪律都在这个函数里，两条都是"排错了不报错、只静默失效"：
  //   1. 若将来要加 `is SSHAuthError`，它必须排在 `is SSHAuthAbortError` 与
  //      `is SSHAuthFailError` **两者之后**。只说"排在 Abort 之后"是不够的 ——
  //      排在两者**之间**同样会静默吞掉 Fail（它俩是各自独立的类，都
  //      implements SSHAuthError：ssh_errors.dart:40 是 Fail、:49 是 Abort，
  //      别按 40/49 的顺序记）。
  //   2. `is SSHError` 是**兜底**，必须始终排在最后。任何新的
  //      `is <某个 SSHError>` 分支排到它后面就是死代码：编译器不报错，
  //      测试也不会红。下面的 `SSHKeyDecodeError` 分支正是为此特意插在
  //      它前面的。
  if (error is SSHAuthAbortError) {
    final reason = error.reason;

    if (reason is SSHHostkeyError) {
      return ConnectionFailure(
        ConnectionFailureKind.hostKey,
        '主机密钥校验未通过：'
        '这把密钥与已保存的指纹不一致，或你拒绝了本次确认。'
        '若设备确实刚更换过密钥，请在设置中清除该主机的记录后重连。',
        cause: error,
      );
    }
    if (reason is SSHInternalError) {
      // 文案不能断言成因。dartssh2 对这个类的自述是"不该发生的错误，多半是
      // 库自身的缺陷"（ssh_errors.dart:14-15），算法协商失败只是它承载的
      // **其中**一种情况。若一口咬定"与该设备协商加密参数失败"，一个库缺陷
      // 就会被说成设备的算法问题 —— 用户跑去翻设备的 SSH 配置，而那正是
      // §13.15 要避免的"把人指向错误的方向"。所以两种成因并列，并始终附原文。
      return ConnectionFailure(
        ConnectionFailureKind.protocolError,
        '协议错误：SSH 协议层报错。两种常见原因：设备只提供已被淘汰的 SSH '
        '算法（ssh-rsa/SHA-1、aes-cbc、hmac-md5 等，V1 暂不支持），'
        '或本程序/对端实现自身的缺陷。原始信息：${reason.error}',
        cause: error,
      );
    }
    // 认不出的 reason：降级为协议错误，但**附上原文**，不吞掉。
    return ConnectionFailure(
      ConnectionFailureKind.protocolError,
      '协议错误：连接在认证完成前中断。原始信息：'
      '${reason ?? error.message}',
      cause: error,
    );
  }

  if (error is SSHAuthFailError) {
    return ConnectionFailure(
      ConnectionFailureKind.authFailed,
      '认证失败：用户名、口令或私钥不正确',
      cause: error,
    );
  }

  if (error is SSHHandshakeError) {
    return ConnectionFailure(
      ConnectionFailureKind.protocolError,
      '协议错误：SSH 握手失败。对端可能不是 SSH 服务，'
      '或使用了不兼容的版本。原始信息：${error.message}',
      cause: error,
    );
  }

  if (error is SSHSocketError) {
    // 底层 socket 的错误被包了一层，拆开才能区分"拒绝连接"与"超时"。
    return _classify(error.error);
  }

  if (error is SocketException) {
    // **FR-C-13 的 15s 超时走的是这里，不是 TimeoutException。**
    // `Socket.connect(timeout:)` 到点后抛 SocketException，errno 为
    // ETIMEDOUT —— 实测过（连 192.0.2.1:22 与 10.255.255.1:22 两个黑洞
    // 地址，两次都得到 `SocketException: Connection timed out ... errno = 110`，
    // 不是 TimeoutException）。不认这个 errno 的话，最常见的失败会被归成
    // "主机不可达"，并把英文「Connection timed out」当中文说明交给用户。
    final int? code = error.osError?.errorCode;
    if (code == _etimedoutLinux || code == _etimedoutWindows) {
      return ConnectionFailure(
        ConnectionFailureKind.timeout,
        _timeoutMessage,
        cause: error,
      );
    }
    return ConnectionFailure(
      ConnectionFailureKind.unreachable,
      '主机不可达：${error.osError?.message ?? error.message}',
      cause: error,
    );
  }

  if (error is SSHKeyDecryptError) {
    // 私钥带口令。**必须排在 `is SSHError` 之前**，也必须排在下面的
    // `SSHKeyDecodeError` 之前 —— 它是后者的子类，排到后面就到不了这里。
    // 单独一支的价值在于：只有这一支能给出**确定且可操作**的方向
    // （去掉口令即可），另一支只能说他文件读不出来。
    return ConnectionFailure(
      ConnectionFailureKind.authFailed,
      '私钥已加密，本版本暂不支持带口令的私钥。'
      '请改用不带口令的私钥，或等待后续版本支持。',
      cause: error,
    );
  }

  if (error is SSHKeyDecodeError) {
    // 读不出私钥，但**不是**口令问题（内容损坏、格式不认识等）。
    // 文案不能假定口令：对一个文件损坏的用户说"若私钥设了口令…"，
    // 就是让他去翻一个根本不存在的口令 —— 与 §13.15 同一个坑，
    // 只是轻一些（原文仍然附在后面）。
    return ConnectionFailure(
      ConnectionFailureKind.authFailed,
      '无法读取私钥：${error.message}',
      cause: error,
    );
  }

  if (error is SSHError) {
    return ConnectionFailure(
      ConnectionFailureKind.protocolError,
      '协议错误：$error',
      cause: error,
    );
  }

  return ConnectionFailure(
    ConnectionFailureKind.unknown,
    '连接失败：$error',
    cause: error,
  );
}
