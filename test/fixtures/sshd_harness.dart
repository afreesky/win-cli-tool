import 'dart:io';

/// 一个真实的本地 sshd，用于 SSH 集成测试。
///
/// spec §9.3：dartssh2 不提供 SSH 服务端，因此用真 sshd 起回环连接。
/// 不可用时（Windows、CI）所有用例应跳过而非失败。
class SshdHarness {
  SshdHarness._(this.port, this._dir, this._pid);

  final int port;
  final Directory _dir;
  final int _pid;

  /// 本机是否具备运行条件。**同步**判断，因为 `skip:` 参数需要同步求值。
  static String? get unavailableReason {
    if (!File('/usr/sbin/sshd').existsSync()) {
      return '本机没有 /usr/sbin/sshd（Windows 或精简环境下跳过）';
    }
    if (!File('/usr/bin/ssh-keygen').existsSync()) {
      return '本机没有 ssh-keygen';
    }
    return null;
  }

  static bool get isAvailable => unavailableReason == null;

  /// 起一个只监听回环、只接受公钥认证的 sshd。
  static Future<SshdHarness> start() async {
    final dir = Directory.systemTemp.createTempSync('wct-sshd-');
    final user = Platform.environment['USER'] ?? 'tester';

    String run(String exe, List<String> args) {
      final r = Process.runSync(exe, args, workingDirectory: dir.path);
      if (r.exitCode != 0) {
        throw StateError('$exe ${args.join(' ')} 失败: ${r.stderr}');
      }
      return r.stdout as String;
    }

    // 主机密钥
    run('/usr/bin/ssh-keygen', ['-q', '-t', 'ed25519', '-f', 'hostkey', '-N', '']);
    // 用户密钥
    run('/usr/bin/ssh-keygen', ['-q', '-t', 'ed25519', '-f', 'userkey', '-N', '']);

    File('${dir.path}/authorized_keys')
        .writeAsStringSync(File('${dir.path}/userkey.pub').readAsStringSync());

    // 找一个空闲高位端口：先绑 0 拿到端口号再释放。
    // ServerSocket 没有 bindSync，这里 await —— start() 本来就是异步的。
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final config = '''
Port $port
ListenAddress 127.0.0.1
HostKey ${dir.path}/hostkey
PidFile ${dir.path}/sshd.pid
AuthorizedKeysFile ${dir.path}/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
UsePAM no
StrictModes no
LogLevel ERROR
''';
    File('${dir.path}/sshd_config').writeAsStringSync(config);

    final r = Process.runSync(
      '/usr/sbin/sshd',
      ['-f', '${dir.path}/sshd_config', '-E', '${dir.path}/sshd.log'],
    );
    if (r.exitCode != 0) {
      throw StateError('sshd 启动失败: ${r.stderr}');
    }

    final pid = int.parse(File('${dir.path}/sshd.pid').readAsStringSync().trim());

    // 等端口真正可连
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final s = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(milliseconds: 200));
        s.destroy();
        break;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    final h = SshdHarness._(port, dir, pid);
    h.user = user;
    h.privateKeyPath = '${dir.path}/userkey';
    return h;
  }

  late final String user;
  late final String privateKeyPath;

  /// 主机密钥指纹，形如 `SHA256:...`。
  String hostFingerprint() {
    final out = Process.runSync('/usr/bin/ssh-keygen', [
      '-lf', '${_dir.path}/hostkey',
    ]).stdout as String;
    // 输出形如 "256 SHA256:xxxx no comment (ED25519)"
    return out.split(' ')[1];
  }

  Future<void> stop() async {
    Process.runSync('kill', ['$_pid']);
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 清理失败不影响测试结论
    }
  }
}
