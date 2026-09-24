import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/data/host_key_store.dart';

void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_hostkey_');
    file = File('${root.path}/known_hosts.json');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  FileHostKeyStore store() => FileHostKeyStore(file: file);

  KnownHost host({
    String h = '10.0.0.1',
    int port = 22,
    String type = 'ssh-ed25519',
    String fp = 'SHA256:aaa',
  }) =>
      KnownHost(host: h, port: port, keyType: type, fingerprint: fp);

  test('文件不存在时 find 返回 null，all 为空', () async {
    expect(await store().find('10.0.0.1', 22, 'ssh-ed25519'), isNull);
    expect(await store().all(), isEmpty);
  });

  test('save 之后 find 拿得到', () async {
    await store().save(host());
    final found = await store().find('10.0.0.1', 22, 'ssh-ed25519');
    expect(found!.fingerprint, 'SHA256:aaa');
  });

  test('真的落盘了：换一个实例也读得到', () async {
    await store().save(host(fp: 'SHA256:bbb'));
    final other = store();
    expect((await other.find('10.0.0.1', 22, 'ssh-ed25519'))!.fingerprint,
        'SHA256:bbb');
  });

  test('同一 host 的两种算法各存一条，互不覆盖', () async {
    final s = store();
    await s.save(host(type: 'ssh-ed25519', fp: 'SHA256:ed'));
    await s.save(host(type: 'rsa-sha2-256', fp: 'SHA256:rsa'));
    expect((await s.find('10.0.0.1', 22, 'ssh-ed25519'))!.fingerprint,
        'SHA256:ed');
    expect((await s.find('10.0.0.1', 22, 'rsa-sha2-256'))!.fingerprint,
        'SHA256:rsa');
    expect(await s.all(), hasLength(2));
  });

  test('同一 host 同一算法再存 = 覆盖', () async {
    final s = store();
    await s.save(host(fp: 'SHA256:old'));
    await s.save(host(fp: 'SHA256:new'));
    expect((await s.all()).single.fingerprint, 'SHA256:new');
  });

  test('端口不同的两条互不影响（拼接键最容易在这里出错）', () async {
    final s = store();
    await s.save(host(port: 22, fp: 'SHA256:p22'));
    await s.save(host(port: 2222, fp: 'SHA256:p2222'));
    expect((await s.find('10.0.0.1', 22, 'ssh-ed25519'))!.fingerprint,
        'SHA256:p22');
    expect((await s.find('10.0.0.1', 2222, 'ssh-ed25519'))!.fingerprint,
        'SHA256:p2222');
  });

  test('主机名里含冒号（IPv6 字面量）不会串到别的记录', () async {
    final s = store();
    await s.save(host(h: '::1', fp: 'SHA256:v6'));
    await s.save(host(h: ':', port: 1, fp: 'SHA256:weird'));
    expect((await s.find('::1', 22, 'ssh-ed25519'))!.fingerprint, 'SHA256:v6');
    expect((await s.find(':', 1, 'ssh-ed25519'))!.fingerprint, 'SHA256:weird');
  });

  test('remove 删掉该条，其余不受影响', () async {
    final s = store();
    await s.save(host(type: 'ssh-ed25519'));
    await s.save(host(type: 'rsa-sha2-256'));
    await s.remove('10.0.0.1', 22, 'ssh-ed25519');
    expect(await s.find('10.0.0.1', 22, 'ssh-ed25519'), isNull);
    expect(await s.find('10.0.0.1', 22, 'rsa-sha2-256'), isNotNull);
  });

  test('remove 不存在的记录不抛，且不改动文件内容', () async {
    final s = store();
    await s.save(host());
    // **前态必须是本 store 自己写不出来的形状。** 这里原本是"存一条、把文件内容
    // 读出来当基准"，那条断言**永远不会红**：`writeJsonObject` 是确定性的，把没变过
    // 的 map 重写一遍得到逐字节相同的文件（实测过 —— 把空操作改成无条件 `_persist`，
    // 用例照样绿，只有 ctime 变了）。手写一段带 `note` 的 JSON 塞进去就不一样了：
    // 此时 `s` 的缓存里已经有记录，一旦它重写，写出来的是缓存（规范形态），
    // 绝不会是这段手写文本。
    const handWritten = '{"schemaVersion": 1, "hosts": [], "note": "手写"}';
    await file.writeAsString(handWritten);
    await s.remove('10.0.0.9', 22, 'ssh-ed25519');
    expect(await file.readAsString(), handWritten,
        reason: '空操作不该重写文件 —— 无谓的写盘会放大"写失败"的窗口');
  });

  test('写盘失败时，本实例不留下"文件里没有"的记录（缓存不领先于文件）', () async {
    // 父路径是一个**普通文件**，所以写盘必定失败，且与 uid 无关（chmod 挡不住
    // root，这个形状挡得住）。要钉的是顺序：`save` 必须先写盘、成功之后才换缓存。
    // 反过来的话，失败之后本实例会声称这条记录存在 —— 设置界面（FR-G-01）把它
    // 列出来，`find` 把它当已知主机放行，而重启之后它就消失了。已知主机记录
    // **悄悄消失**正是 [FileHostKeyStore._load] 那段注释最想避免的结局。
    final blocker = File('${root.path}/blocker')..writeAsStringSync('not a dir');
    final s = FileHostKeyStore(file: File('${blocker.path}/known_hosts.json'));

    await expectLater(s.save(host()), throwsA(isA<FileSystemException>()));

    expect(await s.find('10.0.0.1', 22, 'ssh-ed25519'), isNull,
        reason: '写盘失败后本实例不得声称这条记录存在 —— 否则重启后它就不见了');
  });

  test('remove 之后新实例也读不到（真的删了盘上的）', () async {
    await store().save(host());
    await store().remove('10.0.0.1', 22, 'ssh-ed25519');
    expect(await store().find('10.0.0.1', 22, 'ssh-ed25519'), isNull);
  });

  test('文件里的条目键名就是 {host, port, keyType, fingerprint}', () async {
    await store().save(host());
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final entry = (raw['hosts']! as List<Object?>).single! as Map<String, Object?>;
    expect(entry.keys.toSet(), {'host', 'port', 'keyType', 'fingerprint'},
        reason: '计划 2 的测试钉死了这四个键，改名会让已存文件读不出来（§13.5）');
  });

  test('文件里的 keyType 含冒号时抛 ArgumentError（不静默接受）', () async {
    await file.writeAsString(jsonEncode({
      'schemaVersion': 1,
      'hosts': [
        {
          'host': '10.0.0.1',
          'port': 22,
          'keyType': 'a:b',
          'fingerprint': 'SHA256:x',
        },
      ],
    }));
    expect(() => store().find('10.0.0.1', 22, 'a:b'), throwsArgumentError);
  });

  test('文件里的指纹为空串时抛 ArgumentError（不静默接受）', () async {
    await file.writeAsString(jsonEncode({
      'schemaVersion': 1,
      'hosts': [
        {'host': 'h', 'port': 22, 'keyType': 'ssh-ed25519', 'fingerprint': ''},
      ],
    }));
    expect(() => store().find('h', 22, 'ssh-ed25519'), throwsArgumentError);
  });

  test('条目不是对象时抛 FormatException', () async {
    await file.writeAsString(jsonEncode({
      'schemaVersion': 1,
      'hosts': ['我不是对象'],
    }));
    expect(() => store().find('h', 22, 'k'), throwsFormatException);
  });

  test('没有 hosts 数组时抛 FormatException', () async {
    await file.writeAsString(jsonEncode({'schemaVersion': 1}));
    expect(() => store().find('h', 22, 'k'), throwsFormatException);
  });

  test('落盘文件权限是 0600（NFR-S-04）', () async {
    await store().save(host());
    expect((await file.stat()).mode & 0x1FF, 0x180);
  });

  test('跨类不变式：本 store 的查键与 KnownHost.identity 指的是同一条记录', () async {
    final s = store();
    final h = host();
    await s.save(h);
    // identity 是给人看的字符串；本 store 内部用元组。这条钉住的是 `save` 与
    // `find`/`remove` **用的是同一个键的形状** —— 只改一半（比如把 `save` 的键
    // 写成 `(host.keyType, host.port, host.host)`）会让 `find` 找不到，下面的
    // `!` 立刻抛。
    // **它不是在钉"内部必须用元组"**：`KnownHost` 的构造函数已经拒绝含冒号的
    // keyType，所以拼接键其实也撞不了，两种写法在行为上无法区分（实测过：把六处
    // 键全换成拼接串，整个文件照样全绿）。元组是纵深防御，不是可观测行为。
    expect((await s.find(h.host, h.port, h.keyType))!.identity, h.identity);
    await s.remove(h.host, h.port, h.keyType);
    expect(await s.all(), isEmpty);
  });
}
