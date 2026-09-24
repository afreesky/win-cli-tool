import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_failure.dart';

void main() {
  group('FR-C-06 的五种原因', () {
    test('连接超时', () {
      final f = classifyConnectionFailure(
        TimeoutException('timed out'),
      );
      expect(f.kind, ConnectionFailureKind.timeout);
    });

    test('主机不可达（SocketException，拒绝连接）', () {
      final f = classifyConnectionFailure(
        const SocketException('Connection refused'),
      );
      expect(f.kind, ConnectionFailureKind.unreachable);
    });

    test('认证失败（所有认证方式都试过了）', () {
      final f = classifyConnectionFailure(SSHAuthFailError('all failed'));
      expect(f.kind, ConnectionFailureKind.authFailed);
    });

    test('协议错误（握手失败）', () {
      final f = classifyConnectionFailure(
        SSHHandshakeError('Invalid version: HTTP/1.1 200 OK'),
      );
      expect(f.kind, ConnectionFailureKind.protocolError);
    });

    test('跳板机失败会指明是第几跳', () {
      final f = classifyConnectionFailure(
        const SocketException('Connection refused'),
        hop: const JumpHop(index: 1, name: '堡垒机-A'),
      );
      expect(f.kind, ConnectionFailureKind.jumpHostFailed);
      expect(f.message, contains('第 1 跳'));
      expect(f.message, contains('堡垒机-A'));
    });
  });

  group('§13.15：必须区分主机密钥与算法协商', () {
    test('主机密钥被用户拒绝 → hostKey', () {
      final f = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHHostkeyError('Hostkey verification failed'),
        ),
      );
      expect(f.kind, ConnectionFailureKind.hostKey);
    });

    test('算法协商失败 → protocolError，而不是 authFailed', () {
      // 这是 §10.2「V1 不支持旧算法」这个决定的实际表现形态。
      final f = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHInternalError(StateError('Bad state: No matching key exchange algorithm')),
        ),
      );
      expect(f.kind, ConnectionFailureKind.protocolError);
      expect(f.kind, isNot(ConnectionFailureKind.authFailed));
    });

    test('两者必须分类不同 —— 这是本 Task 的回归测试', () {
      final hostkey = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHHostkeyError('Hostkey verification failed'),
        ),
      );
      final algo = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHInternalError(StateError('Bad state: No matching key exchange algorithm')),
        ),
      );

      // 两者的异常类型与 toString 完全相同，唯一区别在 .reason。
      expect(hostkey.kind, isNot(algo.kind));
    });

    test('认不出的 reason 优雅降级为 protocolError 并附上原文', () {
      // **输入必须是真正认不出的 reason。** 这里原先是
      // `SSHInternalError(StateError('something new'))` —— 那是一个**认得出**的
      // reason，走的是上面那条 SSHInternalError 分支，根本碰不到兜底。于是
      // 把兜底改成 `throw` 之后这条测试照样绿（实测过），而兜底恰恰是本 Task
      // 点名要求的那条「优雅降级」。用一个非 hostkey、非 internal 的 SSHError
      // 才能真正走到兜底。
      final f = classifyConnectionFailure(
        SSHAuthAbortError('boom', SSHAuthFailError('weird')),
      );
      expect(f.kind, ConnectionFailureKind.protocolError);
      expect(f.message, contains('weird'));
    });

    test('reason 为 null 时同样降级，并附上 abort 自己的消息', () {
      final f = classifyConnectionFailure(SSHAuthAbortError('boom'));

      expect(f.kind, ConnectionFailureKind.protocolError);
      expect(f.message, contains('boom'));
    });
  });

  group('SSHSocketError 必须拆开按内层分类', () {
    test('拒绝连接 → unreachable，超时 → timeout（不拆开就分不出这两者）', () {
      // 守的是 `_classify` 里 `if (error is SSHSocketError) return
      // _classify(error.error);` 那一支。它此前零覆盖 —— 把它改成 `throw`，
      // 12 条用例照样全绿（实测过）。而这正是那句注释所声称的作用。
      expect(
        classifyConnectionFailure(
          SSHSocketError(const SocketException('Connection refused')),
        ).kind,
        ConnectionFailureKind.unreachable,
      );
      expect(
        classifyConnectionFailure(SSHSocketError(TimeoutException('timed out')))
            .kind,
        ConnectionFailureKind.timeout,
      );
    });
  });

  group('message 必须是可读中文，且带原始信息', () {
    test('每种 kind 都有非空的中文说明', () {
      for (final e in <Object>[
        TimeoutException('t'),
        const SocketException('r'),
        SSHAuthFailError('a'),
        SSHHandshakeError('h'),
      ]) {
        final f = classifyConnectionFailure(e);
        expect(f.message, isNotEmpty);
        expect(f.message, isNot(contains('null')));
      }
    });

    test('cause 保留原始异常，供日志使用', () {
      final original = const SocketException('Connection refused');
      final f = classifyConnectionFailure(original);

      expect(f.cause, same(original));
    });

    test('非 SSHError 的意外异常不会漏出去', () {
      final f = classifyConnectionFailure(ArgumentError('unexpected'));
      expect(f.kind, ConnectionFailureKind.unknown);
      expect(f.message, isNotEmpty);
    });
  });

  group('文案必须把人指向正确的地方（§13.15 的理由整个就在文案上）', () {
    // 这个 group 守的**不是 kind，而是文案本身**，因为 FR-C-06 的交付物
    // 就是「在输出区给出可读的失败原因」。
    //
    // 实测过的两个漏洞形态，两者都让本文件全绿：
    //   1. 把主机密钥那条消息换成「认证失败：用户名、口令或私钥不正确」——
    //      kind 仍是 hostKey，14 条用例照绿，而用户去反复检查一个根本没问题
    //      的口令。这正是 §13.15 存在的唯一理由。
    //   2. 把 `is SSHInternalError` 整支删掉 —— 兜底分支返回的 kind 一样，
    //      只有文案退化成「连接在认证完成前中断」，同样全绿。
    // 所以下面钉的是"文案把人指向哪里"，不是逐字文本。

    test('主机密钥的文案指向指纹，不指向口令', () {
      final f = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHHostkeyError('Hostkey verification failed'),
        ),
      );

      expect(f.message, contains('指纹'));
      expect(f.message, isNot(contains('口令')));
      expect(f.message, isNot(contains('密码')));
    });

    test('算法协商失败的文案指向算法，同样不指向口令', () {
      // §13.15 表格的第 2 行：老设备只提供 ssh-rsa/SHA-1 等。
      // 它与第 1 行抛出的异常类型和 toString 完全一样。
      final f = classifyConnectionFailure(
        SSHAuthAbortError(
          'Connection closed before authentication',
          SSHInternalError(
            StateError('Bad state: No matching key exchange algorithm'),
          ),
        ),
      );

      expect(f.kind, ConnectionFailureKind.protocolError);
      expect(f.message, contains('算法'));
      expect(f.message, isNot(contains('口令')));
      expect(f.message, isNot(contains('密码')));
    });

    test('SSHError 兜底归 protocolError，不归 unknown', () {
      // §13.15：catch 以 SSHError 为主，unknown 只留给**非** SSHError 的意外。
      // 删掉 `is SSHError` 那一支，SSHStateError 会掉进 unknown —— 于是
      // 「协议层出错」和「我们没预料到的东西」在报告里再也分不开。
      // SSHStateError 是活会话的终态错误（ssh_client.dart:969），不是假形态。
      final f = classifyConnectionFailure(SSHStateError('SSH connection closed'));

      expect(f.kind, ConnectionFailureKind.protocolError);
    });
  });
}
