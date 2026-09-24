# 持久化与输出管线实现计划（spec 里的「计划 4」）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 spec §8.5 里 `lib/data/` 与 `lib/render/ansi_parser.dart` 这批**还没建**的文件建起来 —— 设备/设置/草稿/已知主机密钥/日志五条持久化路径，加上 SGR 解析。

**Architecture:** 全部是**纯 Dart 层**（零 `flutter` import，与 `lib/connection/` 一致），根目录由调用方注入一个 `Directory`，因此测试用临时目录跑真文件 IO，不需要 `path_provider`，也不需要 mock 文件系统。五个 store 共用一把小工具（`json_file.dart`：读对象、原子写、0600、损坏留档）。凭据不走模型序列化，而是走 `CredentialStore` 接口在 **Map 层**替换字段（spec §13.1 / NFR-S-01）。

**Tech Stack:** Dart 3.12 / `dart:io` / `dart:convert`。测试用 `flutter test`（**不是** `dart test`）。

---

## 本计划的范围与接缝

**做：** `lib/data/` 下 7 个文件 + `lib/render/ansi_parser.dart`，以及各自的测试。

**不做（属于计划 5）：** 任何 `flutter` 界面、Riverpod、`path_provider` 取应用数据目录（那是装配层的事，计划 5 的 `app.dart` 做）。本计划的每个 store 都**收一个 `Directory`**，谁给的不关心。

**与已合并代码的接缝（三条，全部已存在）：**

1. `KnownHost` / `HostKeyStore`（`lib/connection/known_host.dart`）—— 本计划的
   `FileHostKeyStore` 实现这个接口。**条目键名 `{host, port, keyType, fingerprint}`
   由计划 2 的测试钉死，必须沿用**（spec §13.5）。
2. `DeviceProfile` / `AppSettings` / `Snippet`（`lib/models/`）—— **模型保持冻结**，
   本计划一个字段都不改。
3. `stripAnsi`（`lib/render/ansi.dart`）—— `ansi_parser.dart` 在它旁边新增，
   **不改它**。

**跳板机已整体放弃（spec §4.2.1 / §10.2，2026-09-25）。** 因此：
`JumpHost` / `DeviceProfile.jumpHostIds` 是**惰性字段**，本计划**不改不删**，
只在 `devices.json` 里**原样往返**；但**非空的 `jumpHostIds` 必须在加载时上报**
（否则手写的 id 会静默变成直连，用户以为走了堡垒机）。

**本计划不含变异证明表。** 用户于 2026-09-25 指示「停止测试，先完成剩余编码」，
那条指示的落地方式是：**计划自带的测试照写**（它们是交付物的一部分），
但**不为每条断言再补一轮变异反证**。若日后要补，按 spec §13.23 的操作规则批跑。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `lib/data/json_file.dart` | 读 JSON 对象 / 原子写 / 0600 / 损坏留档。**其余四个 store 共用** |
| `lib/data/credential_store.dart` | `CredentialStore` 接口 + V1 的明文实现（在 Map 层读写 `password`） |
| `lib/data/device_store.dart` | `devices.json` 读写：v1→v2 迁移、逐条目隔离、保序、名称唯一、加载上报 |
| `lib/data/host_key_store.dart` | `FileHostKeyStore`：已知主机密钥落盘，实现 `HostKeyStore` |
| `lib/data/settings_store.dart` | `settings.json` 读写与损坏恢复 |
| `lib/data/draft_store.dart` | 每台设备一份编辑区草稿 |
| `lib/data/log_writer.dart` | `logs/<日期>/<设备名>.log`，缓冲 + 错误容忍 |
| `lib/render/ansi_parser.dart` | SGR 解析：把带色文本切成样式片段（FR-O-03） |

---

### Task 1: `json_file.dart` —— 五个 store 共用的文件工具

**Files:**
- Create: `lib/data/json_file.dart`
- Test: `test/data/json_file_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/json_file.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_json_file_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  File f(String name) => File('${root.path}/$name');

  group('readJsonObject', () {
    test('文件不存在返回 null，而不是抛异常', () async {
      expect(await readJsonObject(f('nope.json')), isNull);
    });

    test('空文件（只有空白）返回 null', () async {
      await f('empty.json').writeAsString('   \n');
      expect(await readJsonObject(f('empty.json')), isNull);
    });

    test('正常对象读得出来', () async {
      await f('ok.json').writeAsString('{"schemaVersion": 2}');
      expect(await readJsonObject(f('ok.json')), {'schemaVersion': 2});
    });

    test('顶层是数组算损坏，抛 FormatException', () async {
      await f('arr.json').writeAsString('[1, 2]');
      expect(() => readJsonObject(f('arr.json')), throwsFormatException);
    });

    test('顶层是数字算损坏，抛 FormatException', () async {
      await f('num.json').writeAsString('7');
      expect(() => readJsonObject(f('num.json')), throwsFormatException);
    });

    test('根本不是 JSON 时抛 FormatException', () async {
      await f('junk.json').writeAsString('{oops');
      expect(() => readJsonObject(f('junk.json')), throwsFormatException);
    });
  });

  group('writeJsonObject', () {
    test('写完能读回来，且不带临时文件残留', () async {
      await writeJsonObject(f('w.json'), {'a': 1, 'b': [2, 3]});
      expect(await readJsonObject(f('w.json')), {
        'a': 1,
        'b': [2, 3],
      });
      expect(f('w.json.tmp').existsSync(), isFalse);
    });

    test('父目录不存在时自动创建', () async {
      final nested = File('${root.path}/a/b/c.json');
      await writeJsonObject(nested, {'x': true});
      expect(await readJsonObject(nested), {'x': true});
    });

    test('覆盖写不会留下旧内容', () async {
      await writeJsonObject(f('o.json'), {'n': 1});
      await writeJsonObject(f('o.json'), {'n': 2});
      expect(await readJsonObject(f('o.json')), {'n': 2});
    });

    test('输出是带缩进的 UTF-8，中文不被转义', () async {
      await writeJsonObject(f('cn.json'), {'name': '核心交换机'});
      final raw = await f('cn.json').readAsString();
      expect(raw, contains('核心交换机'));
      expect(raw, contains('\n'));
    });
  });

  group('restrictToOwner', () {
    test('Linux 上把权限收紧到 0600', () async {
      final file = f('perm.json');
      await file.writeAsString('{}');
      await restrictToOwner(file);
      final mode = (await file.stat()).mode & 0x1FF;
      expect(mode, 0x180, reason: '0600 八进制 = 0o600 = 0x180');
    });

    test('幂等：连续调用两次不报错', () async {
      final file = f('perm2.json');
      await file.writeAsString('{}');
      await restrictToOwner(file);
      await restrictToOwner(file);
      expect((await file.stat()).mode & 0x1FF, 0x180);
    });
  });

  group('quarantine', () {
    test('把文件改名留档，返回新文件', () async {
      final file = f('bad.json');
      await file.writeAsString('{oops');
      final moved = await quarantine(file, now: DateTime(2026, 9, 25, 1, 2, 3));
      expect(moved, isNotNull);
      expect(moved!.path, contains('bad.json.bad-'));
      expect(await moved.readAsString(), '{oops');
      expect(file.existsSync(), isFalse);
    });

    test('文件不存在时返回 null', () async {
      expect(await quarantine(f('none.json'), now: DateTime(2026)), isNull);
    });

    test('留档名不含冒号（Windows 上非法）', () async {
      final file = f('bad2.json');
      await file.writeAsString('x');
      final moved = await quarantine(file, now: DateTime(2026, 9, 25, 1, 2, 3));
      expect(moved!.path, isNot(contains(':')));
    });
  });

  group('jsonDecode 的往返', () {
    test('写进去的对象与读出来的对象逐键相等（含嵌套）', () async {
      final original = <String, Object?>{
        'schemaVersion': 2,
        'devices': [
          {'id': 'd1', 'port': 22, 'autoConnect': false, 'password': null},
        ],
      };
      await writeJsonObject(f('round.json'), original);
      final back = await readJsonObject(f('round.json'));
      expect(jsonEncode(back), jsonEncode(original));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/json_file_test.dart`
Expected: 编译失败 —— `Target of URI doesn't exist: 'package:win_cli_tool/data/json_file.dart'`

> **判据提醒（spec §13.23）：** 这一步的失败是**假红**（点名的是文件路径）。它只证明
> 文件还没建，不证明任何断言有效。真红的判据始终是 `[E]` 后面跟着**用例名**。

- [ ] **Step 3: Write minimal implementation**

```dart
import 'dart:convert';
import 'dart:io';

/// 五个 store 共用的 JSON 文件工具。
///
/// 抽出来的动机不是"少写几行"，而是这三件事**必须**在每个 store 里一致：
/// 损坏怎么算、写盘怎么保证不半截、权限怎么收紧。三处各写一遍就会出现
/// "设备文件留了档、设置文件没留"这种不对称，而用户只会看到其中一个。
library;

/// 读一个 JSON 对象文件。**文件不存在或内容全空白时返回 null**，不抛异常 ——
/// 首次启动就是这个形状，它必须走正常路径而不是错误路径。
///
/// 只接受顶层是 JSON 对象的文件；数组、数字、字符串一律按损坏抛
/// [FormatException]。三个格式都是对象信封（`{"schemaVersion": …}`），
/// 放行别的形状只会让后续转型在更深的地方炸，报错位置离原因更远。
Future<Map<String, Object?>?> readJsonObject(File file) async {
  if (!await file.exists()) return null;
  final text = await file.readAsString();
  if (text.trim().isEmpty) return null;
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, Object?>) {
    throw FormatException('顶层不是 JSON 对象', file.path);
  }
  return decoded;
}

/// 原子写一个 JSON 对象：先写同目录的 `.tmp`，`flush` 之后再 rename 覆盖。
///
/// **不要改回 `writeAsString` 直写。** 直写在中途失败（磁盘满、进程被杀）
/// 会留下一个被截断的文件，下次启动读到的就是"损坏的配置"—— 于是
/// NFR-R-03 的恢复路径被自己的写入方式反复触发，用户看到的是"配置又坏了"，
/// 而真正的原因在写的那一侧。同目录 rename 是原子的（同文件系统内）。
Future<void> writeJsonObject(File file, Map<String, Object?> json) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(
    const JsonEncoder.withIndent('  ').convert(json),
    flush: true,
  );
  await restrictToOwner(tmp);
  await tmp.rename(file.path);
  // rename 一般保留 inode 的权限位；但目标已存在时某些实现会先删后建，
  // 于是这里对最终路径再设一次。多一次 chmod 是廉价的。
  await restrictToOwner(file);
}

/// 把文件权限收紧到 0600（仅属主可读写）。对应 NFR-S-04。
///
/// **Windows 上是空操作，不是"尽力而为"。** Windows 没有 `chmod`，
/// 起进程调它只会拿到一个非零退出码；NFR-S-04 只要求 Linux，所以这里
/// 显式跳过，而不是在 Windows 上每次写文件都抛一个用户无法处理的异常。
Future<void> restrictToOwner(File file) async {
  if (Platform.isWindows) return;
  final result = await Process.run('chmod', ['600', file.path]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      '无法把权限收紧到 0600：${result.stderr}',
      file.path,
    );
  }
}

/// 把损坏的文件改名留档（`<文件名>.bad-<ISO 时间>`），返回留档后的文件；
/// 原文件不存在时返回 null。
///
/// **留档而不是删除。** NFR-R-03 说的是"备份损坏文件并以空配置启动"——
/// 文件里可能还有用户手写的二十台设备，只是其中一条坏了；删掉就把
/// 可恢复的数据一起扔了。留档名里的冒号要换掉，否则 Windows 上是非法文件名。
Future<File?> quarantine(File file, {required DateTime now}) async {
  if (!await file.exists()) return null;
  final stamp = now.toIso8601String().replaceAll(':', '-');
  return file.rename('${file.path}.bad-$stamp');
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/data/json_file_test.dart`
Expected: `All tests passed!`（16 条）

- [ ] **Step 5: Commit**

```bash
git add lib/data/json_file.dart test/data/json_file_test.dart
git commit -m "feat(data): JSON 文件工具（原子写 / 0600 / 损坏留档）"
```

---

### Task 2: `credential_store.dart` —— 凭据接口（NFR-S-01 的落脚点）

**Files:**
- Create: `lib/data/credential_store.dart`
- Test: `test/data/credential_store_test.dart`

**为什么是「操作 Map」而不是「操作模型」：** spec §13.1 要求凭据读写封在独立接口后，
但**模型保持冻结**。所以接口的入参是**一条设备记录的 JSON map**，不是一个
`DeviceProfile`。这样换密钥库时改的是这一个实现类，模型与 store 都不动。

**三个方法各有不可替代的作用，少一个就有一类错误：**

| 方法 | 少掉它会怎样 |
|---|---|
| `read(record)` | 读盘时拿不到密码，每台设备都变成"没配密码" |
| `write(record, password)` | 存盘时密码写不进去（或换密钥库后**仍**写进明文文件） |
| `strip(record)` | **最隐蔽的一个**：读盘路径上想"先清掉密码再交给模型"的人会顺手用 `write(record, null)` —— 而在密钥库实现下，那是**删掉用户密钥库里的条目**。读一次盘就毁一次凭据。所以"去掉凭据"必须是一个**没有副作用**的独立方法 |

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/credential_store.dart';

void main() {
  group('PlaintextCredentialStore', () {
    const store = PlaintextCredentialStore();

    test('read 取出 password 字段', () {
      expect(store.read({'id': 'd1', 'password': 'hunter2'}), 'hunter2');
    });

    test('read 在没有该字段时返回 null', () {
      expect(store.read({'id': 'd1'}), isNull);
    });

    test('read 在字段显式为 null 时返回 null', () {
      expect(store.read({'id': 'd1', 'password': null}), isNull);
    });

    test('write 一个非 null 值会写进字段', () {
      final record = <String, Object?>{'id': 'd1'};
      store.write(record, 'secret');
      expect(record['password'], 'secret');
    });

    test('write null 是**删掉字段**，不是写一个 null 进去', () {
      final record = <String, Object?>{'id': 'd1', 'password': 'old'};
      store.write(record, null);
      expect(record.containsKey('password'), isFalse,
          reason: '留一个 "password": null 会让换密钥库后的文件看起来"还是有密码"');
    });

    test('strip 去掉凭据且**不改原记录**', () {
      final record = <String, Object?>{'id': 'd1', 'password': 'p', 'port': 22};
      final stripped = store.strip(record);
      expect(stripped.containsKey('password'), isFalse);
      expect(stripped['port'], 22);
      expect(record['password'], 'p', reason: 'strip 必须无副作用');
    });

    test('strip 后返回的是副本，改它不影响原记录', () {
      final record = <String, Object?>{'id': 'd1'};
      store.strip(record)['id'] = 'changed';
      expect(record['id'], 'd1');
    });

    test('strip 对没有凭据的记录是安全的空操作', () {
      expect(store.strip({'id': 'd1'}), {'id': 'd1'});
    });
  });

  group('接口契约（用假实现验证形状）', () {
    test('一个不写文件的实现可以让存盘结果里根本没有 password 键', () {
      final vault = _FakeVault();
      final record = <String, Object?>{'id': 'd1', 'port': 22};
      vault.write(record, 'secret');
      expect(record.containsKey('password'), isFalse,
          reason: '密钥库实现把密码放在记录之外 —— 这正是接口存在的意义');
      expect(vault.secretFor('d1'), 'secret');
      expect(vault.read(record), 'secret');
    });
  });
}

/// 模拟"凭据不落在记录里"的实现，用来钉住接口形状是**够用**的。
class _FakeVault implements CredentialStore {
  final _byId = <String, String>{};

  String? secretFor(String id) => _byId[id];

  @override
  String? read(Map<String, Object?> record) => _byId[record['id'] as String?];

  @override
  void write(Map<String, Object?> record, String? password) {
    final id = record['id'] as String?;
    if (id == null) return;
    if (password == null) {
      _byId.remove(id);
    } else {
      _byId[id] = password;
    }
  }

  @override
  Map<String, Object?> strip(Map<String, Object?> record) {
    final copy = Map<String, Object?>.of(record);
    copy.remove('password');
    return copy;
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/credential_store_test.dart`
Expected: 编译失败（`Target of URI doesn't exist`）—— 假红，只证明文件还没建。

- [ ] **Step 3: Write minimal implementation**

```dart
/// 凭据存储。**NFR-S-01 的落脚点**：V1 明文存盘是被接受的决策，但"明文"
/// 必须是**一个实现类**里的细节，而不是散在 store 与模型里的字段访问。
///
/// 入参是**一条设备记录的 JSON map**，不是 `DeviceProfile` —— 模型保持冻结
/// （spec §13.1）。换成系统密钥库时，只需要换掉本接口的实现，
/// `DeviceStore` 与 `DeviceProfile` 一行都不用改。
abstract class CredentialStore {
  /// 取出这条记录的凭据。没有则返回 null。
  String? read(Map<String, Object?> record);

  /// 把凭据写进这条记录并**负责决定它落在哪里**。
  ///
  /// [password] 为 null 表示"这台设备没有凭据"。
  void write(Map<String, Object?> record, String? password);

  /// 返回一条**不含凭据**的记录副本，可以安全地交给模型或写进文件。
  ///
  /// **必须无副作用，且必须与 [write] 分开。** 读盘路径上如果图省事写成
  /// `write(record, null)`，那么在一个把凭据存进系统密钥库的实现下，
  /// 这就变成了"删掉用户密钥库里的条目"—— 读一次盘毁一次凭据，
  /// 而且用户只会看到"密码莫名其妙没了"。
  Map<String, Object?> strip(Map<String, Object?> record);
}

/// V1 实现：明文，就写在记录自己的 `password` 字段上（spec §8.6 / NFR-S-01）。
///
/// **这个类是 V1 里唯一知道凭据字段叫什么名字的地方。** 别的代码要拿密码，
/// 走 [read]；要写密码，走 [write]。
class PlaintextCredentialStore implements CredentialStore {
  const PlaintextCredentialStore();

  @override
  String? read(Map<String, Object?> record) => record['password'] as String?;

  @override
  void write(Map<String, Object?> record, String? password) {
    if (password == null) {
      // 删键而不是写 null：`"password": null` 与"没有这个键"在读取时等价，
      // 但只有删键这个形状与密钥库实现（记录里根本没有这个键）一致 ——
      // 两个实现对"没有凭据"给出同一种文件形状，往返测试才写得干净。
      record.remove('password');
    } else {
      record['password'] = password;
    }
  }

  @override
  Map<String, Object?> strip(Map<String, Object?> record) {
    final copy = Map<String, Object?>.of(record);
    copy.remove('password');
    return copy;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/data/credential_store_test.dart`
Expected: `All tests passed!`（9 条）

- [ ] **Step 5: Commit**

```bash
git add lib/data/credential_store.dart test/data/credential_store_test.dart
git commit -m "feat(data): 凭据接口与明文实现（NFR-S-01）"
```

---

### Task 3: `DeviceStore` —— 读（迁移 + 逐条目隔离 + 上报）

**Files:**
- Create: `lib/data/device_store.dart`
- Test: `test/data/device_store_load_test.dart`

**这一条要同时满足四件事，缺一个都会退化成"文件一坏就全丢"（NFR-R-03）：**

1. **逐条目隔离**：一台设备的坏记录不能让另外十九台读不出来（spec §13.3）。
2. **catch 要宽到"任何构造错误"**，不是 `on TypeError` —— 模型构造函数自己会抛
   `ArgumentError`（`KnownHost` 的空指纹、含冒号 `keyType` 都是），照字面写
   `on TypeError` 会让这一类掀掉整个文件。
3. **保序**：数组顺序就是显示顺序，读的时候不得重排（spec §13.2）。
4. **上报**：坏了哪一条、从 v1 迁过、跳板机字段被忽略，都要说出来。

- [ ] **Step 1: Write the failing test**

```dart
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
    expect(result.issues.single.message, contains('1'),
        reason: '要指出是第几条（0 基下标 1），否则用户不知道去改哪一条');
  });

  test('构造期抛 ArgumentError 的也要被逐条目隔离（不是只 catch TypeError）', () async {
    await write({
      'schemaVersion': 2,
      'jumpHosts': <Object?>[],
      'devices': [
        device('ok', name: '好的'),
        // protocol 是未知名字 -> DeviceProtocol.fromName 抛 FormatException；
        // 这里再放一条值校验型的错误：port 传字符串 -> TypeError。
        // 两条都必须只影响自己。
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
      contains(LoadIssueKind.migratedFromV1),
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
      contains(LoadIssueKind.migratedFromV1),
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/device_store_load_test.dart`
Expected: 编译失败（`Target of URI doesn't exist`）—— 假红。

- [ ] **Step 3: Write minimal implementation**

```dart
import 'dart:convert';
import 'dart:io';

import '../models/device_profile.dart';
import 'credential_store.dart';
import 'json_file.dart';

/// 当前 `devices.json` 的格式版本（spec §8.6）。
///
/// 2 的由来是新增了 `jumpHosts` 字段。跳板机已于 2026-09-25 整体放弃
/// （spec §10.2），但**版本号不降** —— 磁盘上已经有 v2 文件了，
/// 降回 1 会让它们全被当成"来自更新的版本"。
const int kDevicesSchemaVersion = 2;

/// 加载时发现的问题。**必须上报给用户**，不能只写日志：
/// 每一条都对应一件用户需要知道的事（数据没读全 / 被迁移了 / 跳板机被忽略）。
enum LoadIssueKind {
  /// 某一条设备记录坏了，已跳过。其余记录不受影响。
  corruptEntry,

  /// 整个文件坏了，已留档，按空配置启动。
  corruptFile,

  /// 文件是 v1（或缺版本号），已按 v2 语义读入。
  migratedFromV1,

  /// 这台设备写了 `jumpHostIds`，但 V1 不支持跳板机 —— 它会**直连**。
  /// 不上报的话，用户以为走了堡垒机，实际没走，而且看不出来（spec §8.6）。
  jumpHostIgnored,

  /// 文件的 `schemaVersion` 比本程序认识的新。仍然按 v2 语义读，
  /// 但可能读错 —— 沉默地读错比报错更糟。
  newerSchema,
}

/// 一条加载问题。[message] 面向用户，必须能直接展示。
class LoadIssue {
  const LoadIssue(this.kind, this.message);

  final LoadIssueKind kind;
  final String message;

  @override
  String toString() => 'LoadIssue(${kind.name}): $message';
}

/// [DeviceStore.load] 的结果。
///
/// 返回一个结果对象而不是只返回列表，是因为**问题本身是结果的一部分**：
/// 只返回 `List<DeviceProfile>` 的话，"文件坏了"和"本来就没有设备"
/// 在调用方看来一模一样，而这两者要给用户看的东西完全不同。
class DeviceLoadResult {
  const DeviceLoadResult({required this.devices, required this.issues});

  final List<DeviceProfile> devices;
  final List<LoadIssue> issues;
}

/// `devices.json` 的读写（FR-D-10、NFR-R-03、NFR-R-04）。
class DeviceStore {
  DeviceStore({required this.file, required this.credentials});

  final File file;
  final CredentialStore credentials;

  /// 上一次读到的 `jumpHosts` 原文，存盘时**原样写回**。
  ///
  /// 跳板机已放弃（spec §10.2），V1 既不解释也不修改这个字段；留着的唯一目的是
  /// **不丢用户数据** —— 手写的 `jumpHosts` 不该被本程序的一次保存抹掉。
  List<Object?> _rawJumpHosts = const [];

  /// 读盘。
  ///
  /// 三层容错，从外到内：整个文件坏 → 留档 + 空配置；某一条坏 → 跳过该条；
  /// 字段级问题（v1 缺字段、跳板机 id）→ 补默认值 + 上报。
  Future<DeviceLoadResult> load() async {
    final issues = <LoadIssue>[];

    Map<String, Object?>? raw;
    try {
      raw = await readJsonObject(file);
    } on FormatException catch (e) {
      await quarantine(file, now: DateTime.now());
      return DeviceLoadResult(
        devices: const [],
        issues: [
          LoadIssue(
            LoadIssueKind.corruptFile,
            '设备配置文件无法解析（$e）。已把原文件留档，本次以空配置启动。',
          ),
        ],
      );
    }

    if (raw == null) {
      return const DeviceLoadResult(devices: [], issues: []);
    }

    final version = raw['schemaVersion'];
    if (version == null || version == 1) {
      issues.add(
        const LoadIssue(
          LoadIssueKind.migratedFromV1,
          '设备配置是老版本格式，已按新格式读入（补齐跳板机相关字段）。',
        ),
      );
    } else if (version is int && version > kDevicesSchemaVersion) {
      issues.add(
        LoadIssue(
          LoadIssueKind.newerSchema,
          '设备配置来自更新版本的程序（schemaVersion=$version），'
          '按当前版本读入，可能有字段没读懂。',
        ),
      );
    }

    _rawJumpHosts = (raw['jumpHosts'] as List<Object?>?) ?? const [];

    final rawDevices = raw['devices'];
    if (rawDevices is! List<Object?>) {
      return DeviceLoadResult(
        devices: const [],
        issues: [
          ...issues,
          const LoadIssue(
            LoadIssueKind.corruptFile,
            '设备配置里没有 devices 数组，本次以空配置启动。',
          ),
        ],
      );
    }

    final devices = <DeviceProfile>[];
    for (var i = 0; i < rawDevices.length; i++) {
      final entry = rawDevices[i];
      try {
        if (entry is! Map) {
          throw FormatException('第 $i 条不是 JSON 对象');
        }
        // `.from` 是**立即**拷贝并校验键类型；`.cast` 是惰性视图，
        // 会把错误推迟到后面某次读取，报错位置离原因更远（spec §13.6）。
        final record = Map<String, Object?>.from(entry);
        final password = credentials.read(record);
        final profile =
            DeviceProfile.fromJson(credentials.strip(record)).copyWith(
          password: password,
        );
        devices.add(profile);

        if (profile.jumpHostIds.isNotEmpty) {
          issues.add(
            LoadIssue(
              LoadIssueKind.jumpHostIgnored,
              '设备「${profile.name}」配置了跳板机，但当前版本不支持跳板机，'
              '将直接连接。',
            ),
          );
        }
      } catch (e) {
        // catch 的宽度是「构造一条记录时抛出的**任何**错误」，不是 on TypeError：
        // 模型自己会做值校验并抛 ArgumentError（§13.3）。
        issues.add(
          LoadIssue(
            LoadIssueKind.corruptEntry,
            '第 $i 条设备记录无法读取，已跳过：$e',
          ),
        );
      }
    }

    return DeviceLoadResult(devices: devices, issues: issues);
  }
}
```

> **`save()` 在 Task 4。** 本步只做到能读 —— 这样"读"这一半的错误恢复逻辑
> 可以独立测完再动写路径。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/data/device_store_load_test.dart`
Expected: `All tests passed!`（15 条）

- [ ] **Step 5: Commit**

```bash
git add lib/data/device_store.dart test/data/device_store_load_test.dart
git commit -m "feat(data): DeviceStore 读路径（迁移 / 逐条目隔离 / 加载上报）"
```

---
