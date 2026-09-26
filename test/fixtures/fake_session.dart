import 'dart:async';

import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/connection/session.dart';
import 'package:win_cli_tool/connection/session_factory.dart';
import 'package:win_cli_tool/models/device_profile.dart';

/// 状态层测试用的会话夹具。
///
/// 与 `test/connection/connection_manager_test.dart` 里那个私有夹具**目的不同**：
/// 那个要验证连接语义（订阅所有权、拆除顺序、退避），带着一段承重的注释；
/// 这个只验证"接线接对了没有"，所以刻意做小 —— 只有吐数据、断线、记下发过什么。
class FakeSession implements Session {
  FakeSession(this.profile, {this.failConnect = false, this.failError});

  final DeviceProfile profile;
  final bool failConnect;

  /// 建连失败时抛哪个异常。null 表示用默认的 [FakeConnectFailure]。
  ///
  /// 存在的理由：验证 FR-C-06 的"原因**变了**就必须重新报"这一条，需要
  /// **两种不同**的失败原因，而默认夹具只会抛同一种。
  final Object? failError;

  final _output = StreamController<String>.broadcast();
  final _done = Completer<void>();
  final written = <String>[];
  var connectCalls = 0;
  var closed = false;

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Object? lastError;

  @override
  Future<void> connect() async {
    connectCalls++;
    if (failConnect) throw failError ?? const FakeConnectFailure();
  }

  @override
  void write(String text) => written.add(text);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    // 与真实实现一致：close() 不结束 output、也不触发 done
    // （`Session` 的契约没有承诺前者，两个真实实现都这么做，但那是实现细节）。
  }

  /// 模拟对端吐数据。
  void emit(String s) {
    if (!_output.isClosed) _output.add(s);
  }

  /// 模拟对端断开。
  void drop([Object? error]) {
    if (error != null) lastError = error;
    if (!_done.isCompleted) _done.complete();
  }
}

/// 建连失败。用自定义类型避免依赖 dart:io。
class FakeConnectFailure implements Exception {
  const FakeConnectFailure();

  @override
  String toString() => 'connect failed';
}

/// **第二种**建连失败，与 [FakeConnectFailure] 的可读原因不同。
///
/// 只为 FR-C-06 的"原因变了就必须重新报"那一条存在 —— 用同一种异常测不出
/// 它与"重复的同一条原因"的区别。
class FakeConnectFailure2 implements Exception {
  const FakeConnectFailure2();

  @override
  String toString() => 'connect failed differently';
}

class FakeSessionFactory implements SessionFactory {
  FakeSessionFactory({this.failConnect = false, this.failError});

  bool failConnect;

  /// 每一条新造的会话都用它建连失败。**可变**：用例可以在重试之间换掉它，
  /// 以验证"失败原因变了"这条路径（见 [FakeSession.failError]）。
  Object? failError;

  final sessions = <FakeSession>[];

  @override
  Session create(DeviceProfile profile) {
    final s = FakeSession(profile, failConnect: failConnect, failError: failError);
    sessions.add(s);
    return s;
  }

  @override
  HostKeyStore get hostKeyStore => InMemoryHostKeyStore();

  @override
  ConnectorResolver get connectorResolver => (p) => throw UnimplementedError();

  @override
  Duration get connectTimeout => const Duration(seconds: 15);

  @override
  bool get verifyHostKey => true;

  @override
  Future<bool> Function(KnownHost)? get onUnknownHostKey => null;
}

/// 一台测试设备。默认 `postLoginCommands` 为空 —— 状态层测试不关心 FR-C-08，
/// 让它空着才不会把"自动下发的命令"混进 `written` 的断言里。
DeviceProfile fakeProfile({
  String id = 'd1',
  String name = '核心交换机',
  String host = '10.0.0.1',
  int port = 22,
  bool autoConnect = false,
  List<String> postLogin = const [],
}) => DeviceProfile(
  id: id,
  name: name,
  protocol: DeviceProtocol.ssh,
  host: host,
  port: port,
  username: 'admin',
  postLoginCommands: postLogin,
  autoConnect: autoConnect,
);
