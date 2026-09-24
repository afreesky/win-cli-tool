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
  final String message;

  /// 原始异常对象。用于日志与排查，不展示给用户。
  final Object? cause;

  @override
  String toString() => 'ConnectionFailure(${kind.name}): $message';
}

/// `ETIMEDOUT` 的 errno。**两个都要认**：POSIX（Linux/macOS）是 110，
/// Windows 是 10060（`WSAETIMEDOUT`）。
///
/// 110 是在本机连黑洞地址实测出来的（`Socket.connect(timeout:)` 到点后抛
/// `SocketException ... errno = 110`）。10060 取自 Winsock 的文档值 ——
/// 本机是 Linux，无法实测；但 Windows 是本程序的主要目标平台，漏掉它
/// 恰好会让那一边的用户看不到「超时」。
const int _etimedoutPosix = 110;
const int _etimedoutWindows = 10060;

/// 把任意异常归类成 [ConnectionFailure]。
///
/// **判据是 `SSHAuthAbortError.reason`，不是顶层类型或消息文本** ——
/// 主机密钥被拒与算法协商失败抛出的异常类型与 toString 完全相同
/// （spec §13.15），只有 reason 不同。
ConnectionFailure classifyConnectionFailure(Object error, {JumpHop? hop}) {
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
  if (error is TimeoutException) {
    // 这一支眼下是**防御性**的：dartssh2 自己在握手/认证超时时并不抛这个
    // 类型，它抛 `SSHHandshakeError('Handshake timed out')` 与
    // `SSHAuthAbortError('Authentication timed out')`（后者是它唯一一处
    // reason 为 null 的产出）。真正撑起 FR-C-13 的是下面 `SocketException`
    // 那一支的 errno 判定 —— 别把这条用例的绿色读成"超时路径已验证"。
    return ConnectionFailure(
      ConnectionFailureKind.timeout,
      '连接超时：目标设备在超时时间内没有响应',
      cause: error,
    );
  }

  // 两条顺序纪律都在这个函数里，两条都是"排错了不报错、只静默失效"：
  //   1. 若将来要加 `is SSHAuthError`，它必须排在下面
  //      `is SSHAuthAbortError` **之后** —— SSHAuthAbortError 与
  //      SSHAuthFailError 都 implements SSHAuthError（ssh_errors.dart:40/49），
  //      排在前面会一次吞掉两者。
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
      // 库自身的缺陷"（ssh_errors.dart:14-16），算法协商失败只是它承载的
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
    if (code == _etimedoutPosix || code == _etimedoutWindows) {
      return ConnectionFailure(
        ConnectionFailureKind.timeout,
        '连接超时：目标设备在超时时间内没有响应',
        cause: error,
      );
    }
    return ConnectionFailure(
      ConnectionFailureKind.unreachable,
      '主机不可达：${error.osError?.message ?? error.message}',
      cause: error,
    );
  }

  if (error is SSHKeyDecodeError) {
    // 私钥读不出来。**必须排在 `is SSHError` 之前** —— 排到后面会被它吞掉，
    // 报成"协议错误"并附上 `SSHKeyDecryptError(Private key is encrypted,
    // null)`：一个英文类名、一个字面 null，还把方向指到了协议上。
    // 带口令的私钥就走这里：V1 的 `SSHKeyPair.fromPem` 不带 passphrase。
    return ConnectionFailure(
      ConnectionFailureKind.authFailed,
      '无法读取私钥：${error.message}。'
      '若私钥设了口令，本版本暂不支持带口令的私钥。',
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
