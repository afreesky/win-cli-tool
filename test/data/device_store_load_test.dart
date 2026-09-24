import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/credential_store.dart';
import 'package:win_cli_tool/data/device_store.dart';

void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_device_load_');
    file = File('${root.path}/devices.json');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  DeviceStore store({CredentialStore? credentials}) => DeviceStore(
        file: file,
        credentials: credentials ?? const PlaintextCredentialStore(),
      );

  Future<void> write(Map<String, Object?> json) =>
      file.writeAsString(jsonEncode(json));

  Map<String, Object?> device(String id, {String? name, List<String>? hops}) => {
        'id': id,
        'name': name ?? '设备$id',
        'protocol': 'ssh',
        'host': '10.0.0.1',
        'port': 22,
        'username': 'admin',
        'password': null,
        'privateKeyPath': null,
        'jumpHostIds': hops ?? const <String>[],
        'lineEnding': '\n',
        'promptRegex': null,
        'postLoginCommands': const <String>[],
        'autoConnect': false,
        'snippets': const <Object?>[],
      };

  test('文件不存在时返回空列表、无 issue', () async {
    final result = await store().load();
    expect(result.devices, isEmpty);
    expect(result.issues, isEmpty);
  });

  test('正常文件全读出来，顺序与文件一致', () async {
    await write({
      'schemaVersion': 2,
      'jumpHosts': <Object?>[],
      'devices': [device('b', name: 'B'), device('a', name: 'A')],
    });
    final result = await store().load();
    expect(result.devices.map((d) => d.name), ['B', 'A'],
        reason: '数组顺序就是显示顺序（§13.2），不得重排');
    expect(result.issues, isEmpty);
  });

  test('坏了一条不影响其他条，且指出是哪一条', () async {
    await write({
      'schemaVersion': 2,
      'jumpHosts': <Object?>[],
      'devices': [
        device('ok1', name: '好的1'),
        {'id': 'bad', 'name': '坏的'}, // 缺 port 等必填
        device('ok2', name: '好的2'),
      ],
    });
    final result = await store().load();
    expect(result.devices.map((d) => d.name), ['好的1', '好的2']);
    expect(result.issues, hasLength(1));
    expect(result.issues.single.kind, LoadIssueKind.corruptEntry);
    expect(result.issues.single.message, contains('第 1 条'),
        reason: '要指出是第几条（0 基下标 1），否则用户不知道去改哪一条');
  });

  test('构造期抛出的 FormatException 与 TypeError 都要被逐条目隔离', () async {
    await write({
      'schemaVersion': 2,
      'jumpHosts': <Object?>[],
      'devices': [
        device('ok', name: '好的'),
        // protocol 是未知名字 -> DeviceProtocol.fromName 抛 FormatException；
        // port 传字符串 -> 模型里 `as int` 抛 TypeError。两条都必须只影响自己。
        // 这条用例真正钉住的是 catch 的**宽度**：写成 `on TypeError`，上面那条
        // FormatException 就会逃出整个 load()，下面的 hasLength(2) 立刻变红。
        {...device('badproto'), 'protocol': '不存在的协议'},
        {...device('badport'), 'port': '22'},
      ],
    });
    final result = await store().load();
    expect(result.devices.map((d) => d.name), ['好的']);
    expect(result.issues, hasLength(2));
  });

  test('条目不是对象（是字符串）时也只丢这一条', () async {
    await write({
      'schemaVersion': 2,
      'jumpHosts': <Object?>[],
      'devices': ['我不是对象', device('ok', name: '好的')],
    });
    final result = await store().load();
    expect(result.devices.map((d) => d.name), ['好的']);
    expect(result.issues.single.kind, LoadIssueKind.corruptEntry);
  });

  test('整个文件不是 JSON：留档、按空配置启动、上报', () async {
    await file.writeAsString('{这不是 JSON');
    final result = await store().load();
    expect(result.devices, isEmpty);
    expect(result.issues.single.kind, LoadIssueKind.corruptFile);
    expect(file.existsSync(), isFalse, reason: '损坏文件已留档改名');
    final leftovers = root
        .listSync()
        .where((e) => e.path.contains('.bad-'))
        .toList();
    expect(leftovers, hasLength(1), reason: '留档而不是删除（NFR-R-03）');
  });

  test('顶层是数组也算整个文件损坏', () async {
    await file.writeAsString('[1,2,3]');
    final result = await store().load();
    expect(result.issues.single.kind, LoadIssueKind.corruptFile);
  });

  test('v1 文件被迁移：补齐 jumpHosts 与 jumpHostIds，并上报', () async {
    await write({
      'schemaVersion': 1,
      'devices': [
        {
          'id': 'd1',
          'name': '老设备',
          'protocol': 'telnet',
          'host': '10.0.0.9',
          'port': 23,
          'username': 'u',
        },
      ],
    });
    final result = await store().load();
    expect(result.devices.single.name, '老设备');
    expect(result.devices.single.port, 23);
    expect(result.devices.single.jumpHostIds, isEmpty);
    expect(
      result.issues.map((i) => i.kind),
      contains(LoadIssueKind.migrated),
    );
  });

  test('缺 schemaVersion 视为 v1 并迁移', () async {
    await write({
      'devices': [device('d1', name: '无版本')],
    });
    final result = await store().load();
    expect(result.devices.single.name, '无版本');
    expect(
      result.issues.map((i) => i.kind),
      contains(LoadIssueKind.migrated),
    );
  });

  test('比当前更新的 schemaVersion：仍然读，但上报', () async {
    await write({
      'schemaVersion': 99,
      'jumpHosts': <Object?>[],
      'devices': [device('d1', name: '来自未来')],
    });
    final result = await store().load();
    expect(result.devices.single.name, '来自未来');
    expect(
      result.issues.map((i) => i.kind),
      contains(LoadIssueKind.newerSchema),
      reason: '沉默地按 v2 语义读一个 v3 文件，是"看起来正常但其实读错了"',
    );
  });

  test('非空 jumpHostIds 必须上报（跳板机已放弃，见 spec §8.6）', () async {
    await write({
      'schemaVersion': 2,
      'jumpHosts': [
        {'id': 'j1', 'name': '堡垒机', 'host': 'h', 'port': 22, 'username': 'u'},
      ],
      'devices': [device('d1', name: '走堡垒机的', hops: ['j1'])],
    });
    final result = await store().load();
    expect(result.devices.single.jumpHostIds, ['j1'],
        reason: '字段原样读出来，不静默抹掉');
    final issue = result.issues.singleWhere(
      (i) => i.kind == LoadIssueKind.jumpHostIgnored,
    );
    expect(issue.message, contains('走堡垒机的'),
        reason: '要指名是哪台设备 —— 否则用户不知道该改哪一个');
  });

  test('空 jumpHostIds 不上报（那是默认值，不是用户意图）', () async {
    await write({
      'schemaVersion': 2,
      'jumpHosts': <Object?>[],
      'devices': [device('d1')],
    });
    final result = await store().load();
    expect(
      result.issues.where((i) => i.kind == LoadIssueKind.jumpHostIgnored),
      isEmpty,
    );
  });

  test('读盘时凭据走接口，不直接读 JSON 字段', () async {
    await write({
      'schemaVersion': 2,
      'jumpHosts': <Object?>[],
      'devices': [device('d1', name: '有密码的')],
    });
    final vault = _Vault();
    final result = await store(credentials: vault).load();
    // 上面文件里没有 password 字段；假密钥库按 id 供密码。
    expect(result.devices.single.password, '来自密钥库');
    expect(vault.readIds, contains('d1'));
  });

  test('JSON 里的明文密码不会被模型读到 —— 凭据只从接口来', () async {
    await write({
      'schemaVersion': 2,
      'jumpHosts': <Object?>[],
      'devices': [{...device('d1'), 'password': '明文密码'}],
    });
    final result = await store(credentials: _Vault()).load();
    expect(result.devices.single.password, '来自密钥库',
        reason: 'JSON 里那串明文密码不应被模型读到 —— 凭据只从接口来');
  });

  test('密钥库返回 null 时设备照常读出来，password 为 null', () async {
    await write({
      'schemaVersion': 2,
      'jumpHosts': <Object?>[],
      'devices': [device('d1', name: '没密码的')],
    });
    final result = await store(credentials: _EmptyVault()).load();
    expect(result.devices.single.name, '没密码的');
    expect(result.devices.single.password, isNull);
    expect(result.issues, isEmpty);
  });

  test('jumpHosts 形状不对时不让整次加载崩掉（NFR-R-03）', () async {
    await write({
      'schemaVersion': 2,
      // 手改坏的一个键。**不能**让它把 load() 掀翻 —— 那样调用方拿不到
      // DeviceLoadResult、文件也不会被留档，于是**每次启动都崩**。
      'jumpHosts': '不是数组',
      'devices': [device('d1')],
    });
    final result = await store().load();
    expect(result.devices.single.id, 'd1');
  });

  // 两个字段都要钉：`postLoginCommands` 是**连接时**被 ConnectionManager 遍历的，
  // `jumpHostIds` 则是在**存盘**时被 `toJson` + `jsonEncode` 遍历的 —— 两根都不在
  // 本函数的 try 里，只有加载期把惰性视图收掉才能拦住。
  for (final field in ['postLoginCommands', 'jumpHostIds']) {
    test('惰性 .cast 的坏元素（$field）在加载期就被逮住，该条被跳过', () async {
      final bad = device('d2')..[field] = [5];
      await write({
        'schemaVersion': 2,
        'jumpHosts': <Object?>[],
        'devices': [device('d1'), bad],
      });
      final result = await store().load();
      expect(result.devices.map((d) => d.id), ['d1'],
          reason: '坏记录必须被跳过 —— 报告了 corruptEntry 却还留在列表里更难查');
      expect(result.issues.single.kind, LoadIssueKind.corruptEntry);
    });
  }
}

/// 假密钥库：**记录里没有 password 字段也拿得到密码**。这是"接口真的被用上了"
/// 的判别器 —— 若 DeviceStore 绕过接口直接读 JSON，上面两条会读到明文或 null，
/// 而不是 `'来自密钥库'`。
class _Vault implements CredentialStore {
  final readIds = <String>[];

  @override
  String? read(Map<String, Object?> record) {
    readIds.add(record['id']! as String);
    return '来自密钥库';
  }

  @override
  void write(Map<String, Object?> record, String? password) {}

  @override
  Map<String, Object?> strip(Map<String, Object?> record) {
    final copy = Map<String, Object?>.of(record);
    copy.remove('password');
    return copy;
  }
}

/// 什么都查不到的密钥库。
class _EmptyVault implements CredentialStore {
  @override
  String? read(Map<String, Object?> record) => null;

  @override
  void write(Map<String, Object?> record, String? password) {}

  @override
  Map<String, Object?> strip(Map<String, Object?> record) {
    final copy = Map<String, Object?>.of(record);
    copy.remove('password');
    return copy;
  }
}
