import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

/// 失败原因分类。前五项对应 FR-C-06 列举的原因，[hostKey] 是 §13.15
/// 要求单独区分出来的项。
enum ConnectionFailureKind {
  /// 连接超时（FR-C-13，默认 15s）。
  timeout,

  /// 认证失败：口令或密钥不对。
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
    return ConnectionFailure(
      ConnectionFailureKind.timeout,
      '连接超时：目标设备在超时时间内没有响应',
      cause: error,
    );
  }

  // 注意：这里**没有** `is SSHAuthError` 分支，所以眼下不存在顺序问题。
  // 将来若加，必须排在本分支之后 —— SSHAuthAbortError 与 SSHAuthFailError
  // 都 implements SSHAuthError（ssh_errors.dart:40/49），`is SSHAuthError`
  // 会把两者一起吞掉。
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
    return ConnectionFailure(
      ConnectionFailureKind.unreachable,
      '主机不可达：${error.osError?.message ?? error.message}',
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
