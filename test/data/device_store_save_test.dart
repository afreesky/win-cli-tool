import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/credential_store.dart';
import 'package:win_cli_tool/data/device_store.dart';
import 'package:win_cli_tool/models/device_profile.dart';

void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_device_save_');
    file = File('${root.path}/devices.json');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  DeviceStore store({CredentialStore? credentials}) => DeviceStore(
        file: file,
        credentials: credentials ?? const PlaintextCredentialStore(),
      );

  DeviceProfile profile(
    String id, {
    String? name,
    String? password,
    List<String> hops = const [],
    List<Snippet> snippets = const [],
  }) =>
      DeviceProfile(
        id: id,
        name: name ?? '设备$id',
        protocol: DeviceProtocol.ssh,
        host: '10.0.0.1',
        port: 22,
        username: 'admin',
        password: password,
        jumpHostIds: hops,
        postLoginCommands: const ['enable'],
        snippets: snippets,
      );

  test('存盘后读回来逐字段一致', () async {
    final original = profile(
      'd1',
      name: '核心交换机',
      password: 'pw',
      snippets: const [Snippet(id: 's1', name: '保存', content: 'save\nY')],
    );
    await store().save([original]);

    final back = (await store().load()).devices.single;
    expect(back.id, original.id);
    expect(back.name, original.name);
    expect(back.protocol, DeviceProtocol.ssh);
    expect(back.host, original.host);
    expect(back.port, 22);
    expect(back.username, original.username);
    expect(back.password, 'pw');
    expect(back.postLoginCommands, ['enable']);
    expect(back.snippets.single.content, 'save\nY');
    expect(back.snippets.single.name, '保存');
  });

  test('保序：写进去什么顺序，读出来什么顺序', () async {
    await store().save([
      profile('c', name: 'C'),
      profile('a', name: 'A'),
      profile('b', name: 'B'),
    ]);
    final back = await store().load();
    expect(back.devices.map((d) => d.name), ['C', 'A', 'B'],
        reason: '数组顺序就是显示顺序，store 不得排序（§13.2）');
  });

  test('名称重复时抛 DuplicateDeviceNameError，且**文件根本没被创建**', () async {
    await expectLater(
      store().save([profile('a', name: '同名'), profile('b', name: '同名')]),
      throwsA(isA<DuplicateDeviceNameError>()),
    );
    expect(file.existsSync(), isFalse,
        reason: '校验必须在写之前 —— 写到一半抛出会留下半更新状态');
  });

  test('已有文件时，重名抛出不会破坏原文件内容', () async {
    await store().save([profile('a', name: '好设备')]);
    final before = await file.readAsString();
    await expectLater(
      store().save([profile('a', name: '新名'), profile('b', name: '新名')]),
      throwsA(isA<DuplicateDeviceNameError>()),
    );
    expect(await file.readAsString(), before);
  });

  test('明文实现：密码出现在文件里（V1 已接受的明文存储）', () async {
    await store().save([profile('d1', password: 'hunter2')]);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final devices = raw['devices']! as List<Object?>;
    final first = devices.single! as Map<String, Object?>;
    expect(first['password'], 'hunter2');
  });

  test('密钥库实现：文件里根本没有 password 键', () async {
    await store(credentials: _Vault()).save([profile('d1', password: 'secret')]);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final devices = raw['devices']! as List<Object?>;
    final first = devices.single! as Map<String, Object?>;
    expect(first.containsKey('password'), isFalse,
        reason: '凭据落在记录之外 —— 这正是 NFR-S-01 要的接缝');
  });

  test('没有密码时文件里也不留 "password": null', () async {
    await store().save([profile('d1')]);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final first = (raw['devices']! as List<Object?>).single! as Map<String, Object?>;
    expect(first.containsKey('password'), isFalse);
  });

  test('jumpHosts 原文原样写回（跳板机已放弃，但不得丢用户数据）', () async {
    await file.writeAsString(jsonEncode({
      'schemaVersion': 2,
      'jumpHosts': [
        {'id': 'j1', 'name': '堡垒机', 'host': 'h', 'port': 22, 'username': 'u'},
      ],
      'devices': <Object?>[],
    }));
    // **必须用同一个 store 实例。** `_rawJumpHosts` 是**每个 DeviceStore 各自的**
    // 状态，只有 `load()` 会填它；而 `store()` 辅助函数每次调用都新建一个。写成
    // `store().load()` + `store().save(...)` 就是"一个实例读、另一个实例写" ——
    // 写的那边从没读过盘，只会写回空数组，这条用例必红（实测过，Actual: []）。
    // 要钉的是"**读过的那个实例**写回时不丢用户手写的 jumpHosts"。
    // 顺带记住这条设计对计划 5 的含义：别对同一个文件建两个 store，一个读一个写。
    final s = store();
    final loaded = await s.load();
    await s.save(loaded.devices);

    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['jumpHosts'], [
      {'id': 'j1', 'name': '堡垒机', 'host': 'h', 'port': 22, 'username': 'u'},
    ]);
  });

  test('没读过盘就存盘：jumpHosts 写成空数组，不是 null', () async {
    await store().save([profile('d1')]);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['jumpHosts'], isEmpty);
  });

  test('schemaVersion 写成 2', () async {
    await store().save([profile('d1')]);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['schemaVersion'], 2);
  });

  test('存盘后文件权限是 0600（NFR-S-04）', () async {
    await store().save([profile('d1')]);
    expect((await file.stat()).mode & 0x1FF, 0x180);
  });

  test('空列表也是合法的存盘内容', () async {
    await store().save(const []);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['devices'], isEmpty);
    expect((await store().load()).devices, isEmpty);
  });
}

class _Vault implements CredentialStore {
  @override
  String? read(Map<String, Object?> record) => '来自密钥库';

  @override
  void write(Map<String, Object?> record, String? password) {}

  @override
  Map<String, Object?> strip(Map<String, Object?> record) {
    final copy = Map<String, Object?>.of(record);
    copy.remove('password');
    return copy;
  }
}
