import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/known_host.dart';

KnownHost _k({
  String host = '10.0.0.1',
  int port = 22,
  String keyType = 'ssh-ed25519',
  String fingerprint = 'SHA256:abc123',
}) => KnownHost(
  host: host,
  port: port,
  keyType: keyType,
  fingerprint: fingerprint,
);

void main() {
  test('往返 JSON 一致', () {
    final k = _k();

    final back = KnownHost.fromJson(k.toJson());

    expect(back.host, '10.0.0.1');
    expect(back.port, 22);
    expect(back.keyType, 'ssh-ed25519');
    expect(back.fingerprint, 'SHA256:abc123');
  });

  test('toJson 的键名是持久化格式，不得随手改名', () {
    // 计划 4 会把这些键写进磁盘。改名不会报错，只会让已存的文件读不出来 ——
    // 于是每台设备都被当成"首次连接"，FR-C-11 的确认形同虚设，而且**已经
    // 变过密钥的主机也会被重新 TOFU 接受**。所以钉死键名，而不只是钉住往返。
    expect(_k().toJson(), {
      'host': '10.0.0.1',
      'port': 22,
      'keyType': 'ssh-ed25519',
      'fingerprint': 'SHA256:abc123',
    });
  });

  test('identity 由 host/port/keyType 三者共同决定', () {
    final a = _k(host: 'h', keyType: 'ssh-ed25519', fingerprint: 'SHA256:x');
    final b = _k(host: 'h', keyType: 'ssh-rsa', fingerprint: 'SHA256:y');

    // 同一主机、不同算法 → 身份证不同，因此互不覆盖，
    // 也不会把算法变更误报成"密钥变了"。
    expect(a.identity, isNot(b.identity));
  });

  test('同一主机同一算法重新保存会覆盖（identity 相同）', () {
    final a = _k(host: 'h', keyType: 'ssh-ed25519', fingerprint: 'SHA256:old');
    final b = _k(host: 'h', keyType: 'ssh-ed25519', fingerprint: 'SHA256:new');

    expect(a.identity, b.identity);
  });

  test('指纹为 null 以外的空串是非法值，构造时拒绝', () {
    // 空指纹会让"指纹不匹配"永远为真，从而把每一次连接都判成
    // 主机密钥变更 —— 必须在这里挡住，而不是让它在比较时才发作。
    expect(() => _k(fingerprint: ''), throwsArgumentError);
  });

  test('空仓库里 find 返回 null', () async {
    final store = InMemoryHostKeyStore();

    expect(await store.find('10.0.0.1', 22, 'ssh-ed25519'), isNull);
  });

  test('save 之后 find 能取回同一条（identity 与 find 的键必须一致）', () async {
    // 这条守的是一个**跨类不变式**：KnownHost.identity 拼出的键，
    // 必须和 InMemoryHostKeyStore.find 自己拼的键一模一样。两边一旦各改各的，
    // find 会永远返回 null —— 于是每次连接都被当成"首次连接"，不仅反复弹
    // 确认，更糟的是**已经变过密钥的主机也会被重新接受**。
    final store = InMemoryHostKeyStore();
    final k = _k();

    await store.save(k);

    final got = await store.find(k.host, k.port, k.keyType);
    expect(got, isNotNull);
    expect(got!.fingerprint, 'SHA256:abc123');
  });

  test('同一 identity 再次 save 是覆盖，不是追加', () async {
    final store = InMemoryHostKeyStore();

    await store.save(_k(fingerprint: 'SHA256:old'));
    await store.save(_k(fingerprint: 'SHA256:new'));

    expect(store.all, hasLength(1));
    expect((await store.find('10.0.0.1', 22, 'ssh-ed25519'))!.fingerprint,
        'SHA256:new');
  });

  test('同一主机不同算法各自成条，互不覆盖', () async {
    // 这正是本 Task 按 keyType 分别存储的理由：只按 host:port 存的话，
    // 设备换一种算法协商就会被判成"主机密钥变了" ——
    // 一个正常的算法协商被报成疑似中间人攻击。
    final store = InMemoryHostKeyStore();

    await store.save(_k(keyType: 'ssh-ed25519', fingerprint: 'SHA256:x'));
    await store.save(_k(keyType: 'rsa-sha2-256', fingerprint: 'SHA256:y'));

    expect(store.all, hasLength(2));
    expect((await store.find('10.0.0.1', 22, 'rsa-sha2-256'))!.fingerprint,
        'SHA256:y');
  });

  test('all 是不可变快照，改不动仓库', () async {
    final store = InMemoryHostKeyStore();
    await store.save(_k());

    expect(() => store.all.add(_k(host: 'other')), throwsUnsupportedError);
    expect(store.all, hasLength(1));
  });
}
