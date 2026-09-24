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

**两条书写约定（Task 1 执行后按实测更正）：**

- **各任务 Step 2 写的"假红"判据是"点名的是文件路径"**，不是某句固定的编译器原文。
  实测（Task 1）CFE 说的是
  `Error when reading 'lib/data/json_file.dart': No such file or directory`
  外加若干条 `Method not found: '…'`，**不是**计划原先预写的
  `Target of URI doesn't exist`。判据看性质（红在文件上），别去比对字面。
- **提交信息末尾统一附 `Co-Authored-By: Claude Code <noreply@anthropic.com>`**，
  与 `c965f31` / `b0ff29d` / `e8adc08` 一致。下面各 Step 5 里只写了主题行。
- **Task 2~9 的围栏在写计划时已预跑过一遍**（`dart analyze` + `flutter test`）。
  做这件事的原因就是 Task 1：它的围栏自己有编译错误
  （`library;` 写在 `import` 后面），到实现阶段才暴露，白跑一个来回。
  **但别把它读成"每条中间提交的 `dart analyze` 都是干净的"** —— Task 3 就是反例：
  它的围栏带着一个 `unused_field` 警告（`_rawJumpHosts` 要到 Task 4 的 `save()`
  才被读）。那是**知情的**中间状态，不是漏改。门槛是**九条全做完之后 analyze 干净**，
  不是每条提交都干净。
  **这不改变 Step 2 的做法** —— Step 2 的假红证明的是"文件还不存在"，
  与围栏本身对不对是两件事，仍然要跑、仍然要按假红判据读。
  各 Step 4 的**条数是实测值**，不是估的；对不上就是改动引入了偏差。

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
Expected: 编译失败 —— 假红。实测原文是
`Error when reading 'lib/data/json_file.dart': No such file or directory`，
外加 46 条 `Method not found: 'readJsonObject' …`（四个函数各若干处调用点）。

> **判据提醒（spec §13.23）：** 这一步的失败是**假红**（点名的是文件路径）。它只证明
> 文件还没建，不证明任何断言有效。真红的判据始终是 `[E]` 后面跟着**用例名**。

- [ ] **Step 3: Write minimal implementation**

```dart
/// 五个 store 共用的 JSON 文件工具。
///
/// 抽出来的动机不是"少写几行"，而是这三件事**必须**在每个 store 里一致：
/// 损坏怎么算、写盘怎么保证不半截、权限怎么收紧。三处各写一遍就会出现
/// "设备文件留了档、设置文件没留"这种不对称，而用户只会看到其中一个。
///
/// （`library;` 与它的文档注释必须在 `import` **之前**：Dart 要求库指令先于
/// 所有其它指令，放在后面是编译错误 `library_directive_not_first`。）
library;

import 'dart:convert';
import 'dart:io';

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
Expected: 编译失败（假红：点名的是文件路径）—— 假红，只证明文件还没建。

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
/// **字段名 `password` 不是本类的私事，而是与模型共享的契约**：`DeviceProfile`
/// 的 `toJson` 写出这个键、`fromJson` 也从它读回来。所以 [strip] 必须删掉的
/// 正是**模型写出的那个键** —— 别把这里改成一个"不那么显眼"的名字。在明文
/// 实现下改它只是让往返测试变红；在密钥库实现下，[strip] 就删不掉模型的
/// `password`，明文**照旧落进 devices.json**，而那正是 NFR-S-01 要防的泄露。
///
/// 本类唯一决定的是**凭据落在哪里**（就地写进 record）。别的代码要拿密码，
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
- Create: `lib/data/load_issue.dart`
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/device_store_load_test.dart`
Expected: 编译失败（假红：点名的是文件路径）—— 假红。

- [ ] **Step 3: Write minimal implementation**

先建 `lib/data/load_issue.dart`（`DeviceStore` 与后面的 `SettingsStore` 共用）：

```dart
/// 持久化层加载时发现的问题。**必须上报给用户**，不能只写日志：
/// 每一条都对应一件用户需要知道的事（数据没读全 / 被迁移 / 某个意图被忽略）。
///
/// 放在独立文件里而不是各自的 store 里，是因为 `DeviceStore` 与
/// `SettingsStore` 都要用它。两个 store 各自定义一份的话，「整个文件坏了」
/// 在两处的含义会慢慢漂开，而用户看到的是同一类提示。
enum LoadIssueKind {
  /// 某一条记录坏了，已跳过。其余记录不受影响。
  corruptEntry,

  /// 整个文件读不出设备，按空配置启动。
  ///
  /// **留档与否取决于是哪一步发现的**，别照字面读成"一定留了档"：解析失败那条路
  /// 会 `quarantine()`；`devices` 数组缺失或形状不对那条路**不留档** —— 那种文件是
  /// **可以手改修好的**（键名写成 `Devices` 就是这样），改名留档反而先把用户的原件
  /// 挪走了。代价是它可能被下一次 `save()` 覆盖掉，这是知情的取舍，不是疏忽。
  corruptFile,

  /// 文件是更老的版本（或没有版本号），已按当前语义读入。
  migrated,

  /// 这台设备写了 `jumpHostIds`，但 V1 不支持跳板机 —— 它会**直连**。
  /// 不上报的话，用户以为走了堡垒机，实际没走，而且看不出来（spec §8.6）。
  jumpHostIgnored,

  /// 文件的 `schemaVersion` 比本程序认识的新。仍然按当前语义读，
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
```

再建 `lib/data/device_store.dart`：

```dart
import 'dart:io';

import '../models/device_profile.dart';
import 'credential_store.dart';
import 'json_file.dart';
import 'load_issue.dart';

// 让只 import device_store.dart 的调用方也能拿到问题类型 —— 它们是
// load() 返回值的一部分，要求调用方多 import 一个文件是没道理的。
export 'load_issue.dart';

/// 当前 `devices.json` 的格式版本（spec §8.6）。
///
/// 2 的由来是新增了 `jumpHosts` 字段。跳板机已于 2026-09-25 整体放弃
/// （spec §10.2），但**版本号不降** —— 磁盘上已经有 v2 文件了，
/// 降回 1 会让它们全被当成"来自更新的版本"。
const int kDevicesSchemaVersion = 2;

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
  ///
  /// **但"原样写回"是有前提的，别读成无条件的**：写回的是**本实例 `load()` 记下的
  /// 那一份**。没在本实例上 `load()` 过就直接 `save()`，这里还是初始的 `const []`，
  /// 于是文件里手写的 `jumpHosts` **会被抹成空数组**（实测过，有测试钉着这个行为）。
  /// 所以：**同一个文件不要建两个 store，一个读一个写** —— 计划 5 尤其注意。
  List<Object?> _rawJumpHosts = const [];

  /// 读盘。
  ///
  /// 三层容错，从外到内：整个文件读不出设备 → 空配置（**解析失败时先留档**，
  /// 见 [LoadIssueKind.corruptFile] 对两种情况的区分）；某一条坏 → 跳过该条；
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
          LoadIssueKind.migrated,
          '设备配置是老版本格式，已按新格式读入（补齐跳板机相关字段）。',
        ),
      );
      // `is! int` 那一半是必须的：`"schemaVersion": "3"`（手改出来的，或将来某个
      // 写入方当字符串写）否则会**静默**按当前语义读入 —— 而 load_issue.dart 自己
      // 就说"沉默地读错比报错更糟"。
    } else if (version is! int || version > kDevicesSchemaVersion) {
      issues.add(
        LoadIssue(
          LoadIssueKind.newerSchema,
          '设备配置来自更新版本的程序（schemaVersion=$version），'
          '按当前版本读入，可能有字段没读懂。',
        ),
      );
    }

    // 与下面 `devices` 的判法一致：**先查形状，不硬转**。`jumpHosts` 在 V1 里
    // 只剩"原样写回"一个用途（跳板机已放弃支持），所以形状不对时退回空数组就够了。
    // 但**绝不能**写成 `as List<Object?>?` —— 那是一个没有任何 try 兜着的强转，
    // 一个手改坏的 `"jumpHosts": "x"` 会让 load() 抛 _TypeError 出去：调用方拿不到
    // DeviceLoadResult、文件也不会被留档，于是**每次启动都崩**，正是 NFR-R-03 要防的。
    final rawJumpHosts = raw['jumpHosts'];
    _rawJumpHosts = rawJumpHosts is List<Object?> ? rawJumpHosts : const [];

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
        // **把惰性视图收一遍，而且必须在 add 之前。** 模型里 `postLoginCommands`
        // 与 `jumpHostIds` 用的是 `.cast<String>()`（spec §13.6）—— 那是惰性校验
        // 视图，坏元素要到有人**第一次遍历它**时才抛，而那时早已离开这个 try：
        // `postLoginCommands` 是在连接时被 `ConnectionManager` 入队才遍历的，
        // 用户看到的是"连不上"而不是"第 N 条设备记录坏了，已跳过"。
        //
        // **收在 add 之后是错的**（实测过）：那样这一条已经进了 devices，catch 只
        // 补一条 corruptEntry，坏记录**照样留在列表里** —— 症状从"连接时崩"变成
        // "加载时报告坏了、却还是用它"，比原来更难查。抛在 add 之前，它才真的被跳过。
        // （与 settings_store.dart 收 `morePromptPatterns` 是同一个理由。）
        profile.postLoginCommands.toList(growable: false);
        profile.jumpHostIds.toList(growable: false);

        // 跳板机提示也放在 add **之前**，理由同上：这里读的同样是模型的惰性
        // `.cast<String>()`。今天 `isNotEmpty` 只看长度、不遍历元素，所以安全；
        // 但哪天有人把这条消息改成列举跳板机 id，遍历就会抛在 add 之后，
        // 又变回"报告了坏、却还留着"。
        if (profile.jumpHostIds.isNotEmpty) {
          issues.add(
            LoadIssue(
              LoadIssueKind.jumpHostIgnored,
              '设备「${profile.name}」配置了跳板机，但当前版本不支持跳板机，'
              '将直接连接。',
            ),
          );
        }

        devices.add(profile);
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
Expected: `All tests passed!`（18 条）

- [ ] **Step 5: Commit**

```bash
git add lib/data/load_issue.dart lib/data/device_store.dart test/data/device_store_load_test.dart
git commit -m "feat(data): DeviceStore 读路径（迁移 / 逐条目隔离 / 加载上报）"
```

---

### Task 4: `DeviceStore` —— 写（保序 + 名称唯一 + 凭据剥离）

**Files:**
- Modify: `lib/data/device_store.dart`（在 `DeviceStore` 类里加 `save`，并新增 `DuplicateDeviceNameError`）
- Test: `test/data/device_store_save_test.dart`

**两条不变量必须在**写之前**校验，而不是写完再检查：**

- **顺序**：数组顺序就是显示顺序（§13.2）。`save` 只是逐条编码，**不得排序** ——
  计划 5 的拖拽排序（FR-D-07）靠重写数组实现。
- **名称唯一**（FR-D-04）：单看一个 profile 判断不了唯一性，必须看整个列表，
  所以校验点在 store 而不是模型。**先全校验再动文件**：写到一半发现重名而抛出，
  文件就停在一个半更新的状态。

- [ ] **Step 1: Write the failing test**

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/device_store_save_test.dart`
Expected: 编译失败 —— `The method 'save' isn't defined for the type 'DeviceStore'`，以及
`DuplicateDeviceNameError` 未定义。假红，只证明还没实现。

- [ ] **Step 3: Write minimal implementation**

在 `lib/data/device_store.dart` 的 `DeviceProfile` import 之后、`DeviceStore` 类之前插入：

```dart
/// 设备名称重复（FR-D-04：名称在列表内必须唯一）。
///
/// **在存盘时抛出，而不是提供一个 `bool isNameTaken` 让调用方自己判断。**
/// 唯一性是**文件级**不变量：单看一个 profile 判断不了，必须看整个列表；
/// 让调用方自己判，就总有那么一条路径忘了判，而后果是写出一个读不回来
/// （或读回来两台同名）的文件。
class DuplicateDeviceNameError implements Exception {
  const DuplicateDeviceNameError(this.name);

  final String name;

  /// 可直接展示给用户的中文说明。与 [LoadIssue.message] 以及
  /// `ConnectionFailure.message` 一致 —— 界面对这三者的渲染方式应该是同一种，
  /// 别让计划 5 去 `'$e'`（那会把异常的 `toString()` 直接摆给用户）。
  String get message => '设备名称重复：$name';

  @override
  String toString() => message;
}
```

在 `DeviceStore` 类里、`load()` 之后加：

```dart
  /// 存盘。**先全校验，再动文件**（原因见 [DuplicateDeviceNameError]）。
  ///
  /// 顺序即显示顺序（§13.2）：本方法逐条编码，**不排序**。
  ///
  /// **只校验名称唯一，不校验 id。** id 由计划 5 生成，唯一性归它管 —— 这里是
  /// **有意的留白，不是漏了**；真出现两个同 id，密钥库实现会把两者的凭据串起来。
  ///
  /// 另见 [_rawJumpHosts]：`jumpHosts` 只对**在本实例上 load() 过**的文件才是原样写回。
  Future<void> save(List<DeviceProfile> devices) async {
    final seen = <String>{};
    for (final device in devices) {
      if (!seen.add(device.name)) {
        throw DuplicateDeviceNameError(device.name);
      }
    }

    final encoded = <Object?>[];
    for (final device in devices) {
      // 凭据**只**经由接口进出（NFR-S-01）：先剥掉模型吐出来的凭据字段，
      // 再让接口决定它落在哪里 —— 明文实现会写回同一个字段，
      // 密钥库实现则什么都不写，于是文件里没有凭据。
      final record = credentials.strip(device.toJson());
      credentials.write(record, device.password);
      encoded.add(record);
    }

    await writeJsonObject(file, {
      'schemaVersion': kDevicesSchemaVersion,
      // 原样搬运，不解释也不修改 —— 跳板机已放弃（spec §10.2），
      // 这里唯一的目的就是别把用户手写的数据抹掉。
      'jumpHosts': _rawJumpHosts,
      'devices': encoded,
    });
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/data/device_store_save_test.dart`
Expected: `All tests passed!`（12 条）

再跑一次读路径的测试，确认没被改坏：
Run: `flutter test test/data/device_store_load_test.dart`
Expected: `All tests passed!`（18 条）

- [ ] **Step 5: Commit**

```bash
git add lib/data/device_store.dart test/data/device_store_save_test.dart
git commit -m "feat(data): DeviceStore 写路径（保序 / 名称唯一 / 凭据经接口）"
```

---

### Task 5: `host_key_store.dart` —— 已知主机密钥落盘

**Files:**
- Create: `lib/data/host_key_store.dart`
- Test: `test/data/host_key_store_test.dart`

**这一条实现了计划 2 冻结的 `HostKeyStore` 接口**（`lib/connection/known_host.dart`）。
三条要点：

1. **条目键名 `{host, port, keyType, fingerprint}` 由计划 2 的测试钉死，必须沿用**
   （spec §13.5）—— 改名不会报错，只会让已存的文件读不出来，于是每台设备
   都被当成"首次连接"，**已经变过密钥的主机也会被重新 TOFU 接受**。
2. **内存里的键用元组 `(host, port, keyType)`**，不是拼接串。这是 spec §13.5
   两个修法里明确推荐的那一个：碰撞从"被守卫挡住"变成**结构上不可能**。
3. **读盘时**不**逐条隔离**（与 `DeviceStore` 相反）。丢一条已知主机密钥 = 那台
   主机退回"首次连接"，用户会在**没被告知记录丢过**的情况下重新确认指纹 ——
   而那正是最不该被训练成习惯的动作。所以这里坏了就响亮地失败，
   由装配层留档并告诉用户（计划 5）。

- [ ] **Step 1: Write the failing test**

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/host_key_store_test.dart`
Expected: 编译失败（假红：点名的是文件路径）—— 假红。

- [ ] **Step 3: Write minimal implementation**

```dart
import 'dart:io';

import '../connection/known_host.dart';
import 'json_file.dart';

/// 已知主机密钥的落盘实现（FR-C-11「首次连接确认后保存」）。
///
/// 实现的是计划 2 冻结的 [HostKeyStore] 接口，条目形状也与计划 2 的测试
/// 一致 —— 见 spec §13.5。文件形状是本计划定的：
/// `{"schemaVersion": 1, "hosts": [ {host, port, keyType, fingerprint} ]}`。
class FileHostKeyStore implements HostKeyStore {
  FileHostKeyStore({required this.file});

  final File file;

  /// 内存索引：`(host, port, keyType)` → 记录。
  ///
  /// **键是元组，不是 `'$host:$port:$keyType'` 拼接串。** spec §13.5 给了两个
  /// 修法，这里选的是"结构上不可能碰撞"那一个：拼接串的不变式要靠**三处**
  /// 同时成立才守得住（构造函数拒绝含冒号的 keyType + find/remove 不校验 +
  /// identity 的拼法），而这三处已经出现过一处不设防的形状。元组把它变成
  /// 类型系统的事。
  ///
  /// **缓存只会保存"已经落盘"的内容，而且不会失效。** `save`/`remove` 都是
  /// **写盘成功之后**才换缓存，所以进程内的状态永远不会领先于文件 —— 写盘失败时
  /// 抛出去的东西与磁盘是一致的（见 [save]）。代价有两个，与 `DeviceStore` 的
  /// 同款警告是一回事：**同一个文件不要建两个实例**（后写的会盖掉先写的），
  /// 以及一个长命实例的 [all] 是快照、文件被外部改了它不会重读。计划 5 的装配
  /// 只建一个，别改。
  Map<(String, int, String), KnownHost>? _cache;

  @override
  Future<KnownHost?> find(String host, int port, String keyType) async =>
      (await _load())[(host, port, keyType)];

  /// **先写盘，成功了才换缓存**（顺序不能反）。
  ///
  /// 反过来写（先改 `_cache` 再 `_persist`）在写盘失败时会留下一条"进程内说有、
  /// 文件里没有"的记录：`find` 会把它当已知主机直接放行，设置界面（FR-G-01）也会
  /// 把它列出来，而**重启之后它就不见了**。已知主机记录悄悄消失正是本类最想避免
  /// 的结局（见 [_load] 里那段），所以宁可让缓存晚一步。
  @override
  Future<void> save(KnownHost host) async {
    // 拷一份再改：`_load()` 可能返回的就是 `_cache` 本身，就地改就等于先动了缓存。
    final next = Map.of(await _load())
      ..[(host.host, host.port, host.keyType)] = host;
    await _persist(next);
    _cache = next;
  }

  /// 同样**先写盘，成功了才换缓存**，理由见 [save]。
  ///
  /// 删除失败却换了缓存的话，用户以为已经清掉了那把密钥、文件里却还在 ——
  /// 而"清掉一条已知主机密钥"正是用户遇到真的密钥变更时唯一的出路
  /// （`known_host.dart` 里 [HostKeyStore.remove] 的文档）。
  @override
  Future<void> remove(String host, int port, String keyType) async {
    final map = await _load();
    if (!map.containsKey((host, port, keyType))) return;
    final next = Map.of(map)..remove((host, port, keyType));
    await _persist(next);
    _cache = next;
  }

  /// 全部记录，供 FR-G-01 的「已知主机密钥记录的查看与逐条清除」使用。
  ///
  /// **刻意只加在这个具体类上，没有加到 [HostKeyStore] 接口里。**
  /// 加接口就要改计划 2 已冻结的 `known_host.dart` 与它的围栏，而
  /// "枚举"只有设置界面需要 —— 计划 5 的组合根本来就直接构造这个具体类型，
  /// 拿到的方法是具体类型上的，不涉及向下转型（spec §13.5 的要求是
  /// "别让设置界面去 downcast 具体类型"，从具体类型上直接调用不算）。
  Future<List<KnownHost>> all() async =>
      List.unmodifiable((await _load()).values);

  Future<Map<(String, int, String), KnownHost>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;

    final map = <(String, int, String), KnownHost>{};
    final raw = await readJsonObject(file);
    if (raw != null) {
      final hosts = raw['hosts'];
      if (hosts is! List<Object?>) {
        throw FormatException('已知主机密钥文件里没有 hosts 数组', file.path);
      }
      for (var i = 0; i < hosts.length; i++) {
        final entry = hosts[i];
        if (entry is! Map) {
          throw FormatException('已知主机密钥第 $i 条不是 JSON 对象', file.path);
        }
        // **这里刻意不逐条隔离**（与 DeviceStore 的读路径相反）。
        // 丢一条已知主机密钥，等于让那台主机退回"首次连接"：用户会在
        // **根本没被告知记录丢过**的情况下重新确认一个指纹 —— 而那正是
        // 最不该被训练成习惯的动作（spec §13.5）。所以文件有问题就响亮地
        // 失败，由装配层留档并告诉用户。
        final host = KnownHost.fromJson(Map<String, Object?>.from(entry));
        map[(host.host, host.port, host.keyType)] = host;
      }
    }
    _cache = map;
    return map;
  }

  Future<void> _persist(Map<(String, int, String), KnownHost> map) async {
    await writeJsonObject(file, {
      'schemaVersion': 1,
      'hosts': map.values.map((h) => h.toJson()).toList(growable: false),
    });
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/data/host_key_store_test.dart`
Expected: `All tests passed!`（18 条）

- [ ] **Step 5: Commit**

```bash
git add lib/data/host_key_store.dart test/data/host_key_store_test.dart
git commit -m "feat(data): 已知主机密钥落盘（元组键 / 不逐条隔离 / 0600）"
```

---

### Task 6: `settings_store.dart`

**Files:**
- Create: `lib/data/settings_store.dart`
- Test: `test/data/settings_store_test.dart`

**一个容易漏的点：`AppSettings.fromJson` 里 `morePromptPatterns` 用的是
`.cast<String>()`，那是惰性校验视图（spec §13.6）。** 坏元素要到界面第一次
遍历它时才抛，而那时早已离开加载期的 try/catch —— 用户看到的是运行时崩溃
而不是"设置文件坏了，已用默认值"。所以加载时必须**主动收一遍**。

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/load_issue.dart';
import 'package:win_cli_tool/data/settings_store.dart';
import 'package:win_cli_tool/models/app_settings.dart';

void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_settings_');
    file = File('${root.path}/settings.json');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  SettingsStore store() => SettingsStore(file: file);

  test('文件不存在时给全默认值，无 issue', () async {
    final result = await store().load();
    expect(result.settings.commandTimeoutMs, 10000);
    expect(result.settings.promptDebounceMs, 120);
    expect(result.settings.connectTimeoutMs, 15000);
    expect(result.settings.verifySshHostKey, isTrue);
    expect(result.settings.logEnabled, isTrue);
    expect(result.settings.logDir, isNull);
    expect(result.settings.theme, AppTheme.system);
    expect(result.settings.outputBufferLines, 5000);
    expect(result.issues, isEmpty);
  });

  test('存盘后读回来逐字段一致', () async {
    const original = AppSettings(
      commandTimeoutMs: 3000,
      promptDebounceMs: 50,
      defaultPromptRegex: r'[$#]\s*$',
      morePromptPatterns: ['--More--'],
      logEnabled: false,
      logDir: '/tmp/wct-logs',
      verifySshHostKey: false,
      theme: AppTheme.dark,
      editorSplitRatio: 0.6,
      outputBufferLines: 100,
    );
    await store().save(original);

    final back = (await store().load()).settings;
    expect(back.commandTimeoutMs, 3000);
    expect(back.promptDebounceMs, 50);
    expect(back.defaultPromptRegex, r'[$#]\s*$');
    expect(back.morePromptPatterns, ['--More--']);
    expect(back.logEnabled, isFalse);
    expect(back.logDir, '/tmp/wct-logs');
    expect(back.verifySshHostKey, isFalse);
    expect(back.theme, AppTheme.dark);
    expect(back.editorSplitRatio, 0.6);
    expect(back.outputBufferLines, 100);
  });

  test('schemaVersion 写成 1', () async {
    await store().save(const AppSettings());
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['schemaVersion'], 1);
  });

  test('整个文件不是 JSON：留档 + 默认值 + 上报', () async {
    await file.writeAsString('{坏了');
    final result = await store().load();
    expect(result.settings.commandTimeoutMs, 10000);
    expect(result.issues.single.kind, LoadIssueKind.corruptFile);
    expect(file.existsSync(), isFalse);
    expect(
      root.listSync().where((e) => e.path.contains('.bad-')),
      hasLength(1),
    );
  });

  test('缺少 schemaVersion：读得出来，但上报 migrated', () async {
    await file.writeAsString(jsonEncode({'commandTimeoutMs': 7000}));
    final result = await store().load();
    expect(result.settings.commandTimeoutMs, 7000);
    expect(result.issues.single.kind, LoadIssueKind.migrated);
  });

  test('比当前更新的 schemaVersion：仍然读，但上报 newerSchema', () async {
    await file.writeAsString(
      jsonEncode({'schemaVersion': 99, 'commandTimeoutMs': 7000}),
    );
    final result = await store().load();
    expect(result.settings.commandTimeoutMs, 7000);
    expect(result.issues.single.kind, LoadIssueKind.newerSchema);
  });

  test('翻页模式里有非字符串：留档 + 默认值（惰性视图必须被强制求值）', () async {
    await file.writeAsString(jsonEncode({
      'schemaVersion': 1,
      'morePromptPatterns': ['--More--', 42],
    }));
    final result = await store().load();
    expect(result.settings.morePromptPatterns, ['---- More ----', '--More--', '<--- More --->'],
        reason: '不炸、用默认值 —— 而不是留一个会在界面遍历时炸的惰性视图');
    expect(result.issues.single.kind, LoadIssueKind.corruptFile);
    expect(file.existsSync(), isFalse, reason: '坏文件已留档');
  });

  test('未知主题名降级为跟随系统，不算损坏', () async {
    await file.writeAsString(
      jsonEncode({'schemaVersion': 1, 'theme': '未来主题'}),
    );
    final result = await store().load();
    expect(result.settings.theme, AppTheme.system);
    expect(result.issues, isEmpty, reason: 'AppTheme.fromName 的兜底是既定的，不是损坏');
  });

  test('存盘后文件权限是 0600（NFR-S-04）', () async {
    await store().save(const AppSettings());
    expect((await file.stat()).mode & 0x1FF, 0x180);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/settings_store_test.dart`
Expected: 编译失败（假红：点名的是文件路径）—— 假红。

- [ ] **Step 3: Write minimal implementation**

```dart
import 'dart:io';

import '../models/app_settings.dart';
import 'json_file.dart';
import 'load_issue.dart';

/// 当前 `settings.json` 的格式版本（spec §8.6）。
const int kSettingsSchemaVersion = 1;

/// [SettingsStore.load] 的结果。[issues] 与 `DeviceStore` 用同一套类型。
class SettingsLoadResult {
  const SettingsLoadResult({required this.settings, required this.issues});

  final AppSettings settings;
  final List<LoadIssue> issues;
}

/// `settings.json` 的读写（FR-G-02、NFR-R-03、NFR-R-04）。
class SettingsStore {
  SettingsStore({required this.file});

  final File file;

  /// 读盘。**任何形式的坏都给全默认值 + 上报**，绝不半读：
  /// 设置项之间没有依赖，用一半旧值一半默认值比全默认更让人困惑
  /// （用户会以为"我明明改过"）。
  Future<SettingsLoadResult> load() async {
    Map<String, Object?>? raw;
    try {
      raw = await readJsonObject(file);
    } on FormatException catch (e) {
      await quarantine(file, now: DateTime.now());
      return SettingsLoadResult(
        settings: const AppSettings(),
        issues: [
          LoadIssue(
            LoadIssueKind.corruptFile,
            '设置文件无法解析（$e）。已把原文件留档，本次使用默认设置。',
          ),
        ],
      );
    }

    if (raw == null) {
      return const SettingsLoadResult(settings: AppSettings(), issues: []);
    }

    final issues = <LoadIssue>[];
    final version = raw['schemaVersion'];
    if (version == null) {
      issues.add(
        const LoadIssue(LoadIssueKind.migrated, '设置文件没有版本号，已按当前格式读入。'),
      );
    } else if (version is int && version > kSettingsSchemaVersion) {
      issues.add(
        LoadIssue(
          LoadIssueKind.newerSchema,
          '设置来自更新版本的程序（schemaVersion=$version），'
          '按当前版本读入，可能有设置项没读懂。',
        ),
      );
    }

    try {
      final settings = AppSettings.fromJson(raw);
      // **强制求值一次。** `fromJson` 里 `morePromptPatterns` 用的是
      // `.cast<String>()`：那是惰性校验视图（spec §13.6），坏元素要到界面
      // 第一次遍历它时才抛 —— 而那时早已离开这个 try，用户看到的是崩溃
      // 而不是"设置文件坏了，已用默认值"。收一遍就把失败提到了加载期。
      settings.morePromptPatterns.toList(growable: false);
      return SettingsLoadResult(settings: settings, issues: issues);
    } catch (e) {
      await quarantine(file, now: DateTime.now());
      return SettingsLoadResult(
        settings: const AppSettings(),
        issues: [
          ...issues,
          LoadIssue(
            LoadIssueKind.corruptFile,
            '设置文件里的字段无法读取（$e）。已把原文件留档，本次使用默认设置。',
          ),
        ],
      );
    }
  }

  Future<void> save(AppSettings settings) async {
    await writeJsonObject(file, {
      'schemaVersion': kSettingsSchemaVersion,
      ...settings.toJson(),
    });
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/data/settings_store_test.dart`
Expected: `All tests passed!`（9 条）

- [ ] **Step 5: Commit**

```bash
git add lib/data/settings_store.dart test/data/settings_store_test.dart
git commit -m "feat(data): SettingsStore（默认值兜底 / 惰性视图强制求值）"
```

---

### Task 7: `draft_store.dart` —— 编辑区草稿

**Files:**
- Create: `lib/data/draft_store.dart`
- Test: `test/data/draft_store_test.dart`

**为什么是「一台设备一个纯文本文件」而不是一个 JSON 信封：**

- **文件内容就是编辑区内容。** 落盘/恢复（FR-E-04）就是 `readAsString` /
  `writeAsString`，没有转义、没有换行符往返问题 —— 而草稿里必然有换行符。
- FR-E-17（同步给另一台设备）就是「读 A 写 B」，`read` + `write` 两步。
- **文件名用 `Uri.encodeComponent`**，不是"把 `/ \ : * ? " < > |` 换成下划线"
  （那是 FR-L-05 给**日志文件名**定的规则）。原因是这里要的是一条更强的性质：
  **两个不同的设备 id 必须落到两个不同的文件**。替换式净化会把 `a/b` 和 `a_b`
  映到同一个名字，于是两台设备共用一份草稿 —— 而 FR-E-03 要求的恰恰是
  "按设备独立保存"。`Uri.encodeComponent` 把 `/` 编成 `%2F`（单文件名字符，
  不含分隔符），**既是单射又没有路径穿越**，且它是内建的，不用自己维护一张表。

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/draft_store.dart';

void main() {
  late Directory root;
  late Directory dir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_drafts_');
    dir = Directory('${root.path}/drafts');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  DraftStore store() => DraftStore(dir: dir);

  test('没写过时返回空串（首次启动就是这个形状，不是错误路径）', () async {
    expect(await store().read('d1'), '');
  });

  test('写进去什么，读回来什么（多行 / CRLF / 中文 / 首尾空行）', () async {
    const text = 'sys\ninterface Vlanif1\n description 核心链路\r\n\n';
    await store().write('d1', text);
    expect(await store().read('d1'), text);
  });

  test('真的落盘了：换一个实例也读得到', () async {
    await store().write('d1', 'save');
    expect(await store().read('d1'), 'save');
  });

  test('两台设备互不干扰（FR-E-03）', () async {
    final s = store();
    await s.write('d1', '给第一台');
    await s.write('d2', '给第二台');
    expect(await s.read('d1'), '给第一台');
    expect(await s.read('d2'), '给第二台');
  });

  test('写空串 = 清空草稿，读回来是空串（不是"没写过"）', () async {
    final s = store();
    await s.write('d1', '有内容');
    await s.write('d1', '');
    expect(await s.read('d1'), '');
    expect(Directory(dir.path).listSync(), hasLength(1));
  });

  test('delete 之后文件真的没了，read 回到空串', () async {
    final s = store();
    await s.write('d1', '内容');
    await s.delete('d1');
    expect(await s.read('d1'), '');
    expect(dir.listSync(), isEmpty);
  });

  test('delete 不存在的设备不抛', () async {
    await store().delete('从来没有过');
  });

  test('id 里的 / 与 \\ 不会让文件跑到草稿目录外面去', () async {
    final s = store();
    await s.write('../evil', '穿越');
    await s.write(r'a\b', '穿越2');
    await s.write('/etc/passwd', '穿越3');

    expect(dir.listSync(), hasLength(3), reason: '三个都落在 drafts/ 里');
    expect(File('${root.path}/evil.txt').existsSync(), isFalse);
    expect(File('/etc/passwd.txt').existsSync(), isFalse);
    // 目录名保持不变，没有被 "../" 顶掉
    expect(Directory(dir.path).existsSync(), isTrue);
  });

  test('两个会碰撞的 id 落到两个不同的文件（FR-E-03 的独立性）', () async {
    final s = store();
    await s.write('a/b', '斜杠那份');
    await s.write('a_b', '下划线那份');
    expect(dir.listSync(), hasLength(2));
    expect(await s.read('a/b'), '斜杠那份');
    expect(await s.read('a_b'), '下划线那份');
  });

  test('id 是 ".." 也不会顶到上级目录（文件名后缀挡住了）', () async {
    final s = store();
    await s.write('..', '内容');
    expect(dir.listSync(), hasLength(1));
    expect(await s.read('..'), '内容');
    expect(root.listSync().map((e) => e.path.split('/').last).toSet(),
        {'drafts'});
  });

  test('草稿文件不是 UTF-8 时抛 DraftUnreadableException，而不是静默给空串', () async {
    Directory(dir.path).createSync(recursive: true);
    await File('${dir.path}/d1.txt').writeAsBytes([0xFF, 0xFE, 0x41]);
    expect(
      () => store().read('d1'),
      throwsA(
        isA<DraftUnreadableException>().having((e) => e.deviceId, 'deviceId', 'd1'),
      ),
    );
  });

  test('落盘文件权限是 0600（NFR-S-04）', () async {
    await store().write('d1', '内容');
    expect((await File('${dir.path}/d1.txt').stat()).mode & 0x1FF, 0x180);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/draft_store_test.dart`
Expected: 编译失败（假红：点名的是文件路径）。

- [ ] **Step 3: Write minimal implementation**

```dart
import 'dart:convert';
import 'dart:io';

import 'json_file.dart';

/// 草稿文件读不出来（不是 UTF-8，或读盘失败）。
///
/// **不降级成空串**：空串会让用户以为"草稿没了"，而其实文件还在、只是编码
/// 不对 —— 那时用户已经把它重打了。宁可让调用方（计划 5）catch 住并提示。
class DraftUnreadableException implements Exception {
  const DraftUnreadableException(this.deviceId, this.cause);

  final String deviceId;
  final Object cause;

  @override
  String toString() => '草稿「$deviceId」读不出来：$cause';
}

/// 编辑区草稿（FR-E-03 / FR-E-04 / FR-D-06）。
///
/// 一台设备一个纯文本文件，文件内容**就是**编辑区内容。理由见计划里这一段
/// 开头的说明：草稿里必然有换行符，任何信封格式都要处理换行的转义往返，
/// 而这里不需要信封 —— 按设备分文件已经把"这是谁的草稿"表达完了。
class DraftStore {
  DraftStore({required this.dir});

  /// `drafts/` 目录。**不必预先存在**，第一次写会建。
  final Directory dir;

  /// 文件名 = `Uri.encodeComponent(deviceId)` + `.txt`。
  ///
  /// 不用 FR-L-05 那种"替换危险字符为下划线"的净化：那会把 `a/b` 与 `a_b`
  /// 映到同一个名字（两台设备共用一份草稿，破坏 FR-E-03）。百分号编码把 `/`
  /// 编成 `%2F`（单个文件名字符），**既单射又不含路径分隔符**。
  /// `..` 这类名字也被 `.txt` 后缀挡住（`...txt` 是普通文件名）。
  File _fileFor(String deviceId) =>
      File('${dir.path}/${Uri.encodeComponent(deviceId)}.txt');

  Future<String> read(String deviceId) async {
    final file = _fileFor(deviceId);
    if (!await file.exists()) return '';
    final bytes = await file.readAsBytes();
    // 自己 decode 而不是 readAsString()：后者在解码失败时抛
    // FileSystemException，那是文件系统的语言（带路径、带编码名），
    // 而调用方需要的是一个能指名"是哪台设备的草稿"的错误。
    try {
      return utf8.decode(bytes);
    } on FormatException catch (e) {
      throw DraftUnreadableException(deviceId, e);
    } catch (e) {
      throw DraftUnreadableException(deviceId, e);
    }
  }

  Future<void> write(String deviceId, String text) async {
    final file = _fileFor(deviceId);
    await file.parent.create(recursive: true);
    // 与 writeJsonObject 同一套原子写：先写临时文件、收紧权限、再改名。
    // 草稿不是关键数据，但"关掉程序时正好写了一半"会让下次启动读到一个
    // 截断的草稿 —— 而用户的第一反应是"这软件把我的配置弄丢了"。
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await restrictToOwner(tmp);
    await tmp.rename(file.path);
    await restrictToOwner(file);
  }

  /// 删除某台设备的草稿（FR-D-06：删除设备时一并删除其草稿）。
  Future<void> delete(String deviceId) async {
    final file = _fileFor(deviceId);
    if (await file.exists()) await file.delete();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/data/draft_store_test.dart`
Expected: `All tests passed!`（12 条）

- [ ] **Step 5: Commit**

```bash
git add lib/data/draft_store.dart test/data/draft_store_test.dart
git commit -m "feat(data): 编辑区草稿（按设备分文件 / 单射文件名 / 原子写）"
```

---

### Task 8: `log_writer.dart` —— 日志落盘

**Files:**
- Create: `lib/data/log_writer.dart`
- Test: `test/data/log_writer_test.dart`

**格式完全照 spec §5.6 抄，包括一处不对称**：`===== 会话开始 … =====` 这一行
**没有** `[时间戳] ` 前缀，而断线 / 重连 / 会话结束三行**有**。别"顺手统一"。

```
===== 会话开始 2026-09-24 14:30:12.001 (ssh admin@10.0.0.1:22) =====
[2026-09-24 14:30:12.340] [CoreSW]
[2026-09-24 14:31:02.114] !!! 连接断开 2026-09-24 14:31:02.114 ！！！
[2026-09-24 14:31:05.221] === 重连成功 2026-09-24 14:31:05.221 ===
[2026-09-24 14:33:44.550] ===== 会话结束 2026-09-24 14:33:44.550 =====
```

**三条决定：**

1. **时间源用 `clock.now()`**（与 `ConnectionManager` 一致），测试用 `withClock`。
2. **日期目录在 `start()` 那一刻定死。** 一次会话跨过午夜也只写同一个文件 ——
   否则一次操作会被劈成两个文件，而用户找日志时记的是"那次变更发生在哪天"。
3. **`write()` 自己调 `stripAnsi`。** §5.6 要求日志记的是"与输出区所见一致"的
   文本。把剥离放在这里而不是放在调用方，是为了让那条要求**由代码保证**
   而不是由约定保证 —— 调用方少调一次，日志里就会混进控制序列。
   FR-L-07（设置里关日志）是计划 5 的事：不构造 `LogWriter` 就没有日志。

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/log_writer.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_logs_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  final t0 = DateTime(2026, 9, 24, 14, 30, 12, 1);

  LogWriter writer({
    String deviceName = 'CoreSW',
    void Function(Object)? onError,
    int flushEveryLines = 32,
  }) =>
      LogWriter(
        rootDir: root,
        deviceName: deviceName,
        onError: onError,
        flushEveryLines: flushEveryLines,
      );

  Future<String> logged(LogWriter w) async => (await w.file!.readAsString());

  test('会话开始行的形状与 §5.6 一致，且**没有** [时间戳] 前缀', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.end();
      final text = await logged(w);
      expect(
        text.split('\n').first,
        '===== 会话开始 2026-09-24 14:30:12.001 (ssh admin@10.0.0.1:22) =====',
      );
    });
  });

  test('路径是 <root>/logs 由调用方给，内部是 <日期>/<设备名>.log（FR-L-02）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      expect(w.file!.path, '${root.path}/2026-09-24/CoreSW.log');
    });
  });

  test('write 每行一个 [时间戳] 前缀，末尾换行不产生空行', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('[CoreSW]\n');
      await w.write('Enter system view, return user view with Ctrl+Z.\n');
      await w.end();
      final lines = (await logged(w)).split('\n');
      expect(lines[1], '[2026-09-24 14:30:12.001] [CoreSW]');
      expect(lines[2],
          '[2026-09-24 14:30:12.001] Enter system view, return user view with Ctrl+Z.');
      expect(lines[3], startsWith('[2026-09-24 14:30:12.001] ===== 会话结束'));
    });
  });

  test('中间的空行按原样保留（不静默丢内容）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('a\n\nb');
      await w.end();
      final lines = (await logged(w)).split('\n');
      expect(lines[1], '[2026-09-24 14:30:12.001] a');
      expect(lines[2], '[2026-09-24 14:30:12.001] ');
      expect(lines[3], '[2026-09-24 14:30:12.001] b');
    });
  });

  test('日志里落的是剥离控制符后的文本（§5.6「与输出区所见一致」）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('\x1b[1m[CoreSW]\x1b[0m\r\n');
      await w.end();
      final lines = (await logged(w)).split('\n');
      expect(lines[1], '[2026-09-24 14:30:12.001] [CoreSW]',
          reason: 'SGR 与 \\r 都不该出现在日志里');
    });
  });

  test('断线行与重连行的形状（前缀时间戳与正文时间戳相同）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.disconnected();
      await w.reconnected();
      await w.end();
      final lines = (await logged(w)).split('\n');
      expect(lines[1],
          '[2026-09-24 14:30:12.001] !!! 连接断开 2026-09-24 14:30:12.001 ！！！');
      expect(lines[2],
          '[2026-09-24 14:30:12.001] === 重连成功 2026-09-24 14:30:12.001 ===');
    });
  });

  test('日期目录在 start 定死：跨过午夜仍是同一个文件', () async {
    var now = t0;
    await withClock(Clock(() => now), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      final path = w.file!.path;
      now = DateTime(2026, 9, 25, 0, 0, 1);
      await w.write('午夜之后的内容');
      await w.end();
      expect(w.file!.path, path);
      expect(path, contains('/2026-09-24/'));
      expect(await logged(w), contains('午夜之后的内容'));
    });
  });

  test('start 之前 write 不写任何东西，也不建文件', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.write('还没开始');
      await w.disconnected();
      expect(w.file, isNull);
      expect(root.listSync(), isEmpty);
    });
  });

  test('end 之后的 write / disconnected 不再追加', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.end();
      final after = await logged(w);
      await w.write('结束之后');
      await w.disconnected();
      expect(await logged(w), after);
    });
  });

  test('缓冲：写完但没到阈值时磁盘上还没有，end 之后全都在', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer(flushEveryLines: 32);
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('第一行\n第二行');
      expect(await w.file!.exists(), isFalse, reason: '还没 flush（FR-L-06 的缓冲）');
      await w.end();
      final text = await logged(w);
      expect(text, contains('第一行'));
      expect(text, contains('第二行'));
      expect(text, contains('===== 会话结束'));
    });
  });

  test('缓冲：写到阈值立即落盘', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer(flushEveryLines: 3);
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('1\n2\n3');
      expect(await w.file!.exists(), isTrue);
      expect(await logged(w), contains('3'));
    });
  });

  test('同一文件被两次会话追加，第一段不被覆盖', () async {
    await withClock(Clock.fixed(t0), () async {
      final first = writer();
      await first.start('ssh admin@10.0.0.1:22');
      await first.write('第一段\n');
      await first.end();

      final second = writer();
      await second.start('ssh admin@10.0.0.1:22');
      await second.write('第二段\n');
      await second.end();

      final text = await logged(second);
      expect(text, contains('第一段'));
      expect(text, contains('第二段'));
      expect('===== 会话开始'.allMatches(text).length, 2);
    });
  });

  test('落盘文件权限是 0600（NFR-S-04）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.end();
      expect((await w.file!.stat()).mode & 0x1FF, 0x180);
    });
  });

  test('写盘失败：不抛、不阻塞会话，且 onError 只回调一次（FR-L-06）', () async {
    // 用一个同名**文件**占住目录位置，让 parent.create 必然失败。
    final blocked = File('${root.path}/blocked');
    await blocked.writeAsString('我不是目录');
    final failures = <Object>[];
    final w = LogWriter(
      rootDir: Directory(blocked.path),
      deviceName: 'CoreSW',
      onError: failures.add,
      flushEveryLines: 1,
    );
    await withClock(Clock.fixed(t0), () async {
      await w.start('ssh admin@10.0.0.1:22');
      for (var i = 0; i < 10; i++) {
        await w.write('第 $i 行');
      }
      await w.end();
    });
    expect(failures, hasLength(1),
        reason: '失败一次就够 —— 每行回调一次会把输出区刷爆');
  });

  test('文件名净化：危险字符替换为下划线，首尾空白与点号去掉（FR-L-05）', () {
    expect(sanitizeLogFileName('a/b:c*d?e"f<g>h|i\\j'), 'a_b_c_d_e_f_g_h_i_j');
    expect(sanitizeLogFileName('  核心交换机  '), '核心交换机');
    expect(sanitizeLogFileName('...core...'), 'core');
  });

  test('文件名净化：截断到 64，且截断后不留尾部点号（FR-L-05）', () {
    final long = 'x' * 100;
    expect(sanitizeLogFileName(long).length, 64);
    // 第 64 个字符恰好是点号：截断后会留一个尾点，Windows 上建不出文件。
    final tricky = '${'a' * 63}.${'b' * 10}';
    final got = sanitizeLogFileName(tricky);
    expect(got.endsWith('.'), isFalse);
    expect(got.length, lessThanOrEqualTo(64));
  });

  test('文件名净化：整名被去空之后兜底，不会产生空文件名', () {
    expect(sanitizeLogFileName('   '), '未命名设备');
    expect(sanitizeLogFileName('...'), '未命名设备');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/log_writer_test.dart`
Expected: 编译失败（假红：点名的是文件路径）。

- [ ] **Step 3: Write minimal implementation**

```dart
import 'dart:io';

import 'package:clock/clock.dart';

import '../render/ansi.dart';
import 'json_file.dart';

/// 日志文件名的净化（FR-L-05）。**替换 → 去首尾空白与点号 → 截断到 64。**
///
/// 截断之后再修一次尾点：FR-L-05 把截断排在最后，而"第 64 个字符恰好是点号"
/// 是可能的（`'a'*63 + '.' + 'b'*10`）—— 那时 Windows 会把这个尾点吃掉，
/// 落盘的文件名与 `file.path` 对不上。修完仍然 ≤64，两条要求都满足。
String sanitizeLogFileName(String deviceName) {
  var name = deviceName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  name = name.replaceAll(RegExp(r'^[\s.]+'), '').replaceAll(RegExp(r'[\s.]+$'), '');
  if (name.length > 64) name = name.substring(0, 64);
  name = name.replaceAll(RegExp(r'[\s.]+$'), '');
  return name.isEmpty ? '未命名设备' : name;
}

/// `YYYY-MM-DD HH:mm:ss.SSS`，本地时间（§5.6）。
String _stamp(DateTime t) {
  String p(int n, int width) => n.toString().padLeft(width, '0');
  return '${t.year}-${p(t.month, 2)}-${p(t.day, 2)} '
      '${p(t.hour, 2)}:${p(t.minute, 2)}:${p(t.second, 2)}.'
      '${p(t.millisecond, 3)}';
}

/// 一次会话的日志（FR-L-01~07）。
///
/// **一次会话一个实例**，会话结束调 [end]。FR-L-07（设置里关日志）由调用方
/// 决定要不要构造 —— 本类不做开关。
class LogWriter {
  LogWriter({
    required this.rootDir,
    required this.deviceName,
    this.onError,
    this.flushEveryLines = 32,
  });

  /// 日志根目录（计划 5 从设置里取，见 FR-L-02 的"根目录为应用数据目录"）。
  final Directory rootDir;

  final String deviceName;

  /// 写盘失败时调用**一次**（FR-L-06 的"失败时在输出区提示一次"）。
  final void Function(Object error)? onError;

  /// 攒够多少行就落盘。可注入是为了让测试不必写 32 行才能观察缓冲。
  final int flushEveryLines;

  final _buffer = <String>[];
  File? _file;
  bool _started = false;
  bool _closed = false;
  bool _failed = false;

  /// 日志文件。`start()` 之前为 null。
  File? get file => _file;

  /// 会话开始（FR-L-04）。**日期目录在这一刻定死** —— 一次会话跨过午夜也只写
  /// 同一个文件，否则一次操作会被劈成两半。
  Future<void> start(String description) async {
    if (_started || _closed) return;
    _started = true;
    final at = clock.now();
    _file = File(
      '${rootDir.path}/${_stamp(at).substring(0, 10)}/'
      '${sanitizeLogFileName(deviceName)}.log',
    );
    // 这一行**没有** `[时间戳] ` 前缀，与 §5.6 逐字一致 —— 别顺手统一。
    _buffer.add('===== 会话开始 ${_stamp(at)} ($description) =====');
    await _flush();
  }

  /// 会话输出。文本会先剥离控制符（§5.6：日志与输出区所见一致）。
  Future<void> write(String text) async {
    if (!_started || _closed) return;
    final clean = stripAnsi(text);
    if (clean.isEmpty) return;
    // 末尾换行会在 split 后留下一个空尾元素，那只是行尾符的产物，丢掉它；
    // 中间的空白行是真实内容，保留。
    final parts = clean.split('\n');
    if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
    final prefix = '[${_stamp(clock.now())}] ';
    for (final line in parts) {
      _buffer.add('$prefix$line');
    }
    await _flush();
  }

  /// 连接断开（FR-L-04）。
  Future<void> disconnected() async {
    if (!_started || _closed) return;
    final at = _stamp(clock.now());
    _buffer.add('[$at] !!! 连接断开 $at ！！！');
    await _flush();
  }

  /// 重连成功（FR-L-04）。
  Future<void> reconnected() async {
    if (!_started || _closed) return;
    final at = _stamp(clock.now());
    _buffer.add('[$at] === 重连成功 $at ===');
    await _flush();
  }

  /// 会话结束，并把缓冲全部落盘。
  Future<void> end() async {
    if (!_started || _closed) return;
    _closed = true;
    final at = _stamp(clock.now());
    _buffer.add('[$at] ===== 会话结束 $at =====');
    await _flush(force: true);
  }

  /// 落盘。**默认只在攒够 [flushEveryLines] 行时真写**（FR-L-06 的缓冲）。
  ///
  /// 唯一的强制点是 [end]：会话结束必须把剩下的全写出去。注意 [start] **不是**
  /// 强制点 —— 一次会话只发了一行头就被杀掉时磁盘上什么都没有，这正是"带缓冲"
  /// 的代价，spec 选了缓冲就必须接受它。别为了"头一行马上可见"把 start 改成
  /// 强制，那会让"缓冲"退化成"逐行 flush"。
  Future<void> _flush({bool force = false}) async {
    if (!force && _buffer.length < flushEveryLines) return;
    final target = _file;
    if (_buffer.isEmpty || target == null || _failed) {
      _buffer.clear();
      return;
    }
    final lines = List<String>.of(_buffer);
    _buffer.clear();
    try {
      final existed = await target.exists();
      await target.parent.create(recursive: true);
      await target.writeAsString(
        '${lines.join('\n')}\n',
        mode: FileMode.append,
        flush: true,
      );
      // 只在文件是这次新建的时候收紧权限（NFR-S-04）。每次追加都 chmod 就是
      // 每次 flush 起一个进程 —— 一次长时间的会话能起几万个。文件被外部删掉
      // 再重建的边角情况由 existed 兜住。
      if (!existed) await restrictToOwner(target);
    } catch (e) {
      // **一次失败就停**（FR-L-06）：磁盘满 / 无权限会一直失败，每行回调一次
      // 会把输出区刷爆，而用户从第一条提示就已经知道了。停掉之后本类不再碰
      // 磁盘，会话照常跑 —— 日志坏掉绝不能拖垮会话。
      _failed = true;
      onError?.call(e);
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/data/log_writer_test.dart`
Expected: `All tests passed!`（17 条）

- [ ] **Step 5: Commit**

```bash
git add lib/data/log_writer.dart test/data/log_writer_test.dart
git commit -m "feat(data): 日志落盘（§5.6 格式 / 缓冲 / 失败只报一次）"
```

---

### Task 9: `ansi_parser.dart` —— SGR 解析（FR-O-03）

**Files:**
- Create: `lib/render/ansi_parser.dart`
- Test: `test/render/ansi_parser_test.dart`
- Modify（Step 6）: `lib/data/log_writer.dart` —— 让它改用与输出区**同一套**剥离规则

**核心约束：日志与输出区必须给出同一份文本。** §5.6 要求「日志记录剥离控制符后
的文本，**与输出区所见一致**」。做法是**让两者用同一个函数**：输出区要颜色所以调
`parseAnsi`，日志只要文本所以调 `stripToPlainText`（它的实现就是 `parseAnsi` 的
拼接）。Step 6 把 `LogWriter` 从 `stripAnsi` 切过来，一致性因此是**构造上成立**的。

**为什么不继续用 `stripAnsi`（`lib/render/ansi.dart`，计划 1 已冻结）：**
它和"逐字符扫描"的解析器在两类输入上会分叉（下面有实测数字），而 `stripAnsi`
只有命令层（`PromptDetector` / `MorePager`）在用。选"日志跟输出区一致"而不是
"日志跟命令层一致"，是因为 §5.6 明说的是前者。

**实测的两类分叉**（2026-09-25，200000 条随机差分 + 24 条现实语料）：

1. **不含 ESC 时 `stripAnsi` 不删 `\r`。** 它的 `\r` 清理写在
   `if (!input.contains('\x1b')) return input;` 这个提前返回**之后**，所以一段
   没有控制序列的设备输出（`[CoreSW]sys\r\n…`）会带着 `\r` 原样返回，而解析器
   一律删。**这一类在现实输入上就会出现**，是本节最要紧的一条。
2. **退化输入里"删掉一条序列后新拼出一条"。** `stripAnsi` 是三次全串
   `replaceAll`，删完 CSI 之后 `\x1b` 与后面的 `\` 可能新拼成一条两字节序列；
   逐字符扫描看不到这种"事后拼出来"的序列。实测只在
   `\x1b\x1b[…` 这类相邻/嵌套的畸形输入上出现（随机差分里含 ESC 的 44 条
   全部是这一形状），**设备不会这样发**。

**语料对拍用例（Step 1 的最后一组）因此只覆盖现实输入**，它是一道防漂移的闸：
两者对良构控制序列必须给出同样的文本。**若哪条对拍失败，先怀疑解析器**
（`stripAnsi` 是冻结的、命令层依赖的那一份），但**上面两类分叉不算失败** ——
它们各有一条专门的用例把现状钉住，改它们要连着改期望。

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/render/ansi.dart';
import 'package:win_cli_tool/render/ansi_parser.dart';

void main() {
  /// 把片段拼回纯文本。与日志用的是同一个出口。
  String textOf(String input) => stripToPlainText(input);

  group('基本形状', () {
    test('纯文本就是一个 none 样式的片段', () {
      final spans = parseAnsi('interface Vlanif1');
      expect(spans, hasLength(1));
      expect(spans.single.text, 'interface Vlanif1');
      expect(spans.single.style, AnsiStyle.none);
    });

    test('空串没有任何片段', () {
      expect(parseAnsi(''), isEmpty);
    });

    test('只有 SGR 时也没有片段（不产生空 span）', () {
      expect(parseAnsi('\x1b[31m\x1b[0m'), isEmpty);
    });
  });

  group('SGR', () {
    test('前景色 30–37', () {
      final spans = parseAnsi('\x1b[31m红\x1b[0m');
      expect(spans, hasLength(1));
      expect(spans.single.text, '红');
      expect(spans.single.style.foreground, const AnsiBasic(1));
    });

    test('组合参数 1;31;44', () {
      final style = parseAnsi('\x1b[1;31;44mx').single.style;
      expect(style.bold, isTrue);
      expect(style.foreground, const AnsiBasic(1));
      expect(style.background, const AnsiBasic(4));
    });

    test('ESC[m 等价于 ESC[0m（空参数就是 0）', () {
      expect(parseAnsi('\x1b[1mA\x1b[mB').last.style, AnsiStyle.none);
    });

    test('22 / 24 / 27 各自只关掉自己那一项', () {
      final s = parseAnsi('\x1b[1;4;7mA\x1b[22mB\x1b[24mC\x1b[27mD');
      expect(s[0].style.bold && s[0].style.underline && s[0].style.reverse,
          isTrue);
      expect(s[1].style.bold, isFalse);
      expect(s[1].style.underline, isTrue);
      expect(s[2].style.underline, isFalse);
      expect(s[2].style.reverse, isTrue);
      expect(s[3].style.reverse, isFalse);
    });

    test('39 / 49 恢复默认色而不是留下一个"淡色"', () {
      final s = parseAnsi('\x1b[31;44mA\x1b[39mB\x1b[49mC');
      expect(s[0].style.foreground, const AnsiBasic(1));
      expect(s[0].style.background, const AnsiBasic(4));
      expect(s[1].style.foreground, isNull);
      expect(s[1].style.background, const AnsiBasic(4));
      expect(s[2].style.background, isNull);
    });

    test('90–97 是亮前景，100–107 是亮背景', () {
      expect(parseAnsi('\x1b[90mA').single.style.foreground,
          const AnsiBasic(8));
      expect(parseAnsi('\x1b[97mA').single.style.foreground,
          const AnsiBasic(15));
      expect(parseAnsi('\x1b[100mA').single.style.background,
          const AnsiBasic(8));
      expect(parseAnsi('\x1b[107mA').single.style.background,
          const AnsiBasic(15));
    });

    test('38;5;n 是 256 色索引', () {
      expect(parseAnsi('\x1b[38;5;196mA').single.style.foreground,
          const Ansi256(196));
      expect(parseAnsi('\x1b[48;5;17mA').single.style.background,
          const Ansi256(17));
    });

    test('38;2;r;g;b 是真彩', () {
      expect(parseAnsi('\x1b[38;2;10;20;30mA').single.style.foreground,
          const AnsiRgb(10, 20, 30));
      expect(parseAnsi('\x1b[48;2;1;2;3mA').single.style.background,
          const AnsiRgb(1, 2, 3));
    });

    test('写残的扩展色不抛，也不把后面的数字当成颜色', () {
      for (final bad in [
        '\x1b[38;5;mA',
        '\x1b[38;5;300mA',
        '\x1b[38;2;1;2mA',
        '\x1b[38;2;1;2;999mA',
      ]) {
        final spans = parseAnsi(bad);
        expect(spans, hasLength(1), reason: bad);
        expect(spans.single.text, 'A', reason: bad);
        expect(spans.single.style, AnsiStyle.none, reason: bad);
      }
    });

    test('认不出的数字参数被忽略，而不是当成 0（0 会把样式清空）', () {
      final style = parseAnsi('\x1b[1;99999999999999999999mA').single.style;
      expect(style.bold, isTrue);
    });

    test('不支持的 SGR（闪烁、隐藏）静默忽略，文本照常', () {
      final spans = parseAnsi('\x1b[5;8mA');
      expect(spans.single.text, 'A');
      expect(spans.single.style, AnsiStyle.none);
    });
  });

  group('非 SGR 的控制序列被剥离', () {
    test('光标移动 / 擦除 / 定位', () {
      expect(textOf('\x1b[2J\x1b[H\x1b[10;20H清屏'), '清屏');
      expect(textOf('\x1b[K清行尾\x1b[1A上移'), '清行尾上移');
      expect(textOf('\x1b[?25l隐藏\x1b[?25h'), '隐藏');
    });

    test('OSC 标题序列，BEL 与 ST 两种终止符', () {
      expect(textOf('\x1b]0;标题\x07正文'), '正文');
      expect(textOf('\x1b]0;标题\x1b\\正文'), '正文');
    });

    test('\\r 一律被丢掉', () {
      expect(textOf('a\r\nb'), 'a\nb');
      expect(parseAnsi('a\r\nb').single.text, 'a\nb');
      // 与 stripAnsi 不同：它只在输入含 ESC 时才走到 \\r 清理那一步
      // （见「与 stripAnsi 对拍」那组里的分叉用例）。
      expect(stripAnsi('a\r\nb'), 'a\r\nb');
    });
  });

  group('边界', () {
    test('残缺的 ESC 序列不抛异常', () {
      expect(textOf('\x1b'), '\x1b');
      expect(textOf('\x1b[31'), '\x1b[31');
      expect(textOf('\x1b['), '\x1b[');
      expect(textOf('尾部\x1b'), '尾部\x1b');
    });

    test('没终止符的 OSC：ESC 与 ] 被两字节规则吃掉（与 stripAnsi 一致）', () {
      // 这条是"优先级顺序"的钉子：先试 CSI、再试 OSC、再试两字节，
      // 最后才当普通字符。顺序错了这条就红。
      expect(textOf('\x1b]0;未终止'), '0;未终止');
      expect(stripAnsi('\x1b]0;未终止'), '0;未终止');
    });

    test('选择字符集 ESC ( B 在两边都不被剥离（既有行为，见计划说明）', () {
      expect(textOf('\x1b(B字符集'), '\x1b(B字符集');
      expect(stripAnsi('\x1b(B字符集'), '\x1b(B字符集');
    });

    test('相邻同样式的片段合并成一个', () {
      final spans = parseAnsi('a\x1b[0mb');
      expect(spans, hasLength(1));
      expect(spans.single.text, 'ab');
    });

    test('任意字节流都不抛', () {
      const garbage = '\x1b\x1b\x1b[;\x1b]0\x07\x1b[999;;;m\x1b(\x00\x1bZ';
      expect(() => parseAnsi(garbage), returnsNormally);
      expect(() => stripToPlainText(garbage), returnsNormally);
      expect(() => stripAnsi(garbage), returnsNormally);
    });
  });

  group('颜色到 RGB', () {
    test('前 16 色的表', () {
      expect(const AnsiBasic(0).rgb, (0, 0, 0));
      expect(const AnsiBasic(1).rgb, (205, 0, 0));
      expect(const AnsiBasic(7).rgb, (229, 229, 229));
      expect(const AnsiBasic(9).rgb, (255, 0, 0));
      expect(const AnsiBasic(15).rgb, (255, 255, 255));
    });

    test('256 色表的三段：0–15 同基本色、16–231 是 6×6×6、232–255 是灰阶', () {
      expect(const Ansi256(0).rgb, (0, 0, 0));
      expect(const Ansi256(196).rgb, (255, 0, 0));
      expect(const Ansi256(21).rgb, (0, 0, 255));
      expect(const Ansi256(240).rgb, (88, 88, 88));
      expect(const Ansi256(255).rgb, (238, 238, 238));
    });

    test('真彩原样返回', () {
      expect(const AnsiRgb(10, 20, 30).rgb, (10, 20, 30));
    });
  });

  group('与 stripAnsi 对拍（只覆盖现实输入）', () {
    // 语料里**不放**"没有 ESC 却带 \r"的输入：那种输入两边必然不同，
    // 见下面「分叉一」。这里要的是"对良构控制序列两边给同一份文本"。
    const corpus = <String>[
      '',
      '普通文本',
      '\x1b[31m红\x1b[0m',
      '\x1b[1;31;44m粗\x1b[22m体',
      '\x1b[38;5;196m索引\x1b[39m',
      '\x1b[38;2;10;20;30m真彩\x1b[49m',
      '\x1b[2J\x1b[H\x1b[10;20H清屏',
      '\x1b]0;标题\x07正文',
      '\x1b]0;标题\x1b\\正文',
      '\x1b[?25l隐藏\x1b[?25h',
      '\x1b(B字符集',
      '\x1b[31',
      '\x1b',
      '\x1b[0m',
      '\x1b[7m反显\x1b[27m',
      '中文\x1b[90m亮黑\x1b[100m亮黑底\x1b[0m',
      '\x1b[K清行尾\x1b[1A上移',
      '\x1b]0;未终止',
      '\x1bZ',
      '尾部\x1b',
      '\x1b[1m\x1b[31m两层\x1b[0m',
      '\x1b[2J\x1b]0;标题\x07\x1b[1m[CoreSW]\x1b[0m\r\n',
    ];

    test('每一条的纯文本都与 stripAnsi 相同', () {
      for (final input in corpus) {
        expect(
          stripToPlainText(input),
          stripAnsi(input),
          reason:
              '对拍失败：${input.codeUnits.map((c) => c.toRadixString(16)).join(' ')}',
        );
      }
    });

    test('分叉一：不含 ESC 时 stripAnsi 不删 \\r，本解析器一律删', () {
      // stripAnsi 的 \r 清理写在 `if (!input.contains('\x1b')) return input;`
      // 之后 —— 没有 ESC 就提前返回了，\r 原样留下。**现实输入会撞上**：
      // 一段不带颜色的纯回显就是这个形状。
      const plain = '[CoreSW]sys\r\nEnter system view\r\n[CoreSW]';
      expect(stripAnsi(plain), plain);
      expect(stripToPlainText(plain), '[CoreSW]sys\nEnter system view\n[CoreSW]');
      // 同一段只要带上任意一条 ESC，两边就都删 \r 了 —— 分叉只在"这一整段
      // 没有任何控制序列"时出现。
      expect(stripAnsi('\x1b[0m\r\n'), '\n');
      expect(stripToPlainText('\x1b[0m\r\n'), '\n');
    });

    test('分叉二：退化输入里"删掉一条序列后新拼出一条"，两边不同（不改）', () {
      // stripAnsi 是三次全串 replaceAll：删掉 `\x1b[\` 之后，最前面那个孤立的
      // ESC 与后面的 `\` 新拼成一条两字节序列，于是被吃掉。逐字符扫描看不到
      // 这种"事后拼出来"的序列。实测只在 `\x1b\x1b[…` 这类相邻/嵌套的畸形
      // 输入上出现，设备不会这样发。
      const degenerate = '\x1b\x1b[\\\\]]';
      expect(stripAnsi(degenerate), ']]');
      expect(stripToPlainText(degenerate), '\x1b\\]]');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/render/ansi_parser_test.dart`
Expected: 编译失败（假红：点名的是文件路径）。

- [ ] **Step 3: Write minimal implementation**

```dart
/// SGR 颜色。三档：16 色、256 色索引、24 位真彩。
///
/// 声明为 `sealed`：计划 5 要按颜色算 Flutter 的 `Color`，穷尽的 switch 会让
/// "将来新增一档颜色"成为**编译错误**，而不是某个分支悄悄不着色。
sealed class AnsiColor {
  const AnsiColor();

  /// 渲染用的 24 位 RGB。
  ///
  /// **换算放在这一层，不留给调用方。** 256 色表的构成（前 16 色沿用基本色、
  /// 16–231 是 6×6×6 色立方、232–255 是 24 级灰阶）是 ANSI 的一部分，不是界面
  /// 的一部分；留出去就等于让"这一段算得对不对"没有测试可钉。
  (int, int, int) get rgb;
}

/// 前 16 色（SGR 30–37 / 90–97 / 40–47 / 100–107）。
final class AnsiBasic extends AnsiColor {
  const AnsiBasic(this.index) : assert(index >= 0 && index < 16);

  /// 0–7 是标准色，8–15 是亮色。
  final int index;

  @override
  (int, int, int) get rgb => _basicRgb[index];

  @override
  bool operator ==(Object other) => other is AnsiBasic && other.index == index;

  @override
  int get hashCode => index;

  @override
  String toString() => 'AnsiBasic($index)';
}

/// 256 色索引（SGR `38;5;n` / `48;5;n`）。
final class Ansi256 extends AnsiColor {
  const Ansi256(this.index) : assert(index >= 0 && index < 256);

  final int index;

  @override
  (int, int, int) get rgb {
    if (index < 16) return _basicRgb[index];
    if (index < 232) {
      // 6×6×6 色立方，每轴 6 级：0 与 55+40k（k=1..5）→ 0,95,135,175,215,255。
      final n = index - 16;
      int level(int v) => v == 0 ? 0 : 55 + v * 40;
      return (level(n ~/ 36), level((n ~/ 6) % 6), level(n % 6));
    }
    // 24 级灰阶：8, 18, …, 238。
    final gray = 8 + (index - 232) * 10;
    return (gray, gray, gray);
  }

  @override
  bool operator ==(Object other) => other is Ansi256 && other.index == index;

  @override
  int get hashCode => index;

  @override
  String toString() => 'Ansi256($index)';
}

/// 24 位真彩（SGR `38;2;r;g;b` / `48;2;r;g;b`）。
final class AnsiRgb extends AnsiColor {
  const AnsiRgb(this.r, this.g, this.b);

  final int r;
  final int g;
  final int b;

  @override
  (int, int, int) get rgb => (r, g, b);

  @override
  bool operator ==(Object other) =>
      other is AnsiRgb && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => 'AnsiRgb($r, $g, $b)';
}

/// 标准 xterm 的前 16 色。
const List<(int, int, int)> _basicRgb = [
  (0, 0, 0), // 0 黑
  (205, 0, 0), // 1 红
  (0, 205, 0), // 2 绿
  (205, 205, 0), // 3 黄
  (0, 0, 238), // 4 蓝
  (205, 0, 205), // 5 品红
  (0, 205, 205), // 6 青
  (229, 229, 229), // 7 白
  (127, 127, 127), // 8 亮黑（灰）
  (255, 0, 0), // 9 亮红
  (0, 255, 0), // 10 亮绿
  (255, 255, 0), // 11 亮黄
  (92, 92, 255), // 12 亮蓝
  (255, 0, 255), // 13 亮品红
  (0, 255, 255), // 14 亮青
  (255, 255, 255), // 15 亮白
];

/// 一段文本的显示样式。默认（[none]）表示不着色、不加粗。
class AnsiStyle {
  const AnsiStyle({
    this.foreground,
    this.background,
    this.bold = false,
    this.underline = false,
    this.reverse = false,
  });

  final AnsiColor? foreground;
  final AnsiColor? background;
  final bool bold;
  final bool underline;
  final bool reverse;

  static const AnsiStyle none = AnsiStyle();

  /// 与 `AppSettings.copyWith` 同一个 `_unset` 哨兵模式：`foreground` /
  /// `background` 是**可空**字段，用 `?? this.foreground` 就永远没法把它们设回
  /// null，而 SGR 39 / 49 恰恰就是"恢复默认色"。
  AnsiStyle copyWith({
    Object? foreground = _unset,
    Object? background = _unset,
    bool? bold,
    bool? underline,
    bool? reverse,
  }) =>
      AnsiStyle(
        foreground: identical(foreground, _unset)
            ? this.foreground
            : foreground as AnsiColor?,
        background: identical(background, _unset)
            ? this.background
            : background as AnsiColor?,
        bold: bold ?? this.bold,
        underline: underline ?? this.underline,
        reverse: reverse ?? this.reverse,
      );

  @override
  bool operator ==(Object other) =>
      other is AnsiStyle &&
      other.foreground == foreground &&
      other.background == background &&
      other.bold == bold &&
      other.underline == underline &&
      other.reverse == reverse;

  @override
  int get hashCode =>
      Object.hash(foreground, background, bold, underline, reverse);

  @override
  String toString() => 'AnsiStyle(fg: $foreground, bg: $background, '
      'bold: $bold, underline: $underline, reverse: $reverse)';
}

const Object _unset = Object();

/// 一段同样式的文本。计划 5 把它逐个映射成 Flutter 的 `TextSpan`。
class AnsiSpan {
  const AnsiSpan(this.text, this.style);

  final String text;
  final AnsiStyle style;

  @override
  bool operator ==(Object other) =>
      other is AnsiSpan && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);

  @override
  String toString() => 'AnsiSpan(${text.length} 字, $style)';
}

/// 把带控制序列的文本切成样式片段（FR-O-03）。
///
/// **输出区用它，日志用 [stripToPlainText]**（就是它的拼接），所以 §5.6 的
/// 「日志与输出区所见一致」是构造上成立的，不靠约定。
///
/// 与 `lib/render/ansi.dart` 的 `stripAnsi`（命令层在用）有两处**已实测、
/// 刻意不改**的分叉，各有一条用例钉着：
///
/// 1. **不含 ESC 时 `stripAnsi` 不删 `\r`**（它的 `\r` 清理在提前返回之后），
///    这里一律删。现实输入会撞上，所以日志/输出区都走这里才干净。
/// 2. **退化输入里"删掉一条序列后新拼出一条"**：`stripAnsi` 是三次全串
///    `replaceAll`，删完 CSI 后孤立 ESC 可能与后面的 `\` 新拼成两字节序列；
///    逐字符扫描看不到。只在 `\x1b\x1b[…` 这类畸形输入上出现。
///
/// 另有一个**两边共有**的缺陷：`ESC ( B`（选择字符集，三字节）都不被剥离 ——
/// 它不属于两字节规则覆盖的范围。修它要动已冻结的 `ansi.dart`，本计划不改
/// （见计划末尾「本计划发现的既有问题」）。
List<AnsiSpan> parseAnsi(String input, {AnsiStyle initial = AnsiStyle.none}) {
  final spans = <AnsiSpan>[];
  final buffer = StringBuffer();
  var style = initial;

  void flush() {
    if (buffer.isEmpty) return;
    final text = buffer.toString();
    buffer.clear();
    // 相邻同样式合并。`a\x1b[0mb` 必须是一个片段：不合并的话每个 SGR 边界
    // 都会切一刀，计划 5 的 TextSpan 会碎成一地，而且"样式没变"这件事在
    // 结果里看不出来。
    if (spans.isNotEmpty && spans.last.style == style) {
      final last = spans.removeLast();
      spans.add(AnsiSpan(last.text + text, style));
    } else {
      spans.add(AnsiSpan(text, style));
    }
  }

  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch != '\x1b') {
      // `\r` 丢掉，与 stripAnsi 一致。**已知代价**：设备用 `\r` 重画进度行时
      // 这里会把两次内容首尾相接显示，而不是只留最后一次 —— 与 stripAnsi 同样
      // 的取舍，让两条路径一致比单方面"更对"更重要。
      if (ch != '\r') buffer.write(ch);
      i++;
      continue;
    }

    // **优先级顺序是承重的**：先试 CSI，再试 OSC，再试两字节，最后才把 ESC
    // 当普通字符。顺序错了 `\x1b]0;未终止` 这类输入就会与 stripAnsi 分道扬镳
    // （stripAnsi 的两字节规则会吃掉 `\x1b]`）。
    if (i + 1 < input.length && input[i + 1] == '[') {
      final csi = _matchCsi(input, i);
      if (csi != null) {
        final (paramEnd, finalAt) = csi;
        if (input[finalAt] == 'm') {
          flush();
          style = _applySgr(style, input.substring(i + 2, paramEnd));
        }
        i = finalAt + 1;
        continue;
      }
    } else if (i + 1 < input.length && input[i + 1] == ']') {
      final afterOsc = _matchOsc(input, i);
      if (afterOsc != null) {
        i = afterOsc;
        continue;
      }
    }

    if (i + 1 < input.length && _isTwoByteFinal(input.codeUnitAt(i + 1))) {
      i += 2;
      continue;
    }

    // 什么都不匹配：ESC 就是普通字符，原样留下（stripAnsi 也会留下它）。
    buffer.write('\x1b');
    i++;
  }

  flush();
  return spans;
}

/// 剥离控制符，只留文本。**日志用它，输出区用 [parseAnsi]** —— 两条路径共用
/// 一套规则，§5.6 的「与输出区所见一致」因此是构造上成立的。
String stripToPlainText(String input) =>
    parseAnsi(input).map((span) => span.text).join();

/// 从 `\x1b`（位置 [i]）起匹配一条 CSI，返回 `(参数结束位置, 终止字节位置)`。
/// 字符范围与 `ansi.dart` 的 `_csi` 逐段对应。
(int, int)? _matchCsi(String input, int i) {
  var j = i + 2;
  while (j < input.length && _isCsiParam(input.codeUnitAt(j))) {
    j++;
  }
  final paramEnd = j;
  while (j < input.length && _isCsiIntermediate(input.codeUnitAt(j))) {
    j++;
  }
  if (j >= input.length) return null; // 没有终止字节 = 不成立
  if (!_isCsiFinal(input.codeUnitAt(j))) return null;
  return (paramEnd, j);
}

/// 从 `\x1b]`（位置 [i]）起匹配一条 OSC，返回**终止符之后**的位置；不成立返回
/// null（终止符是 BEL，或 ST 的 `\x1b\`）。
int? _matchOsc(String input, int i) {
  var j = i + 2;
  while (j < input.length && input[j] != '\x07' && input[j] != '\x1b') {
    j++;
  }
  if (j >= input.length) return null;
  if (input[j] == '\x07') return j + 1;
  if (j + 1 < input.length && input[j + 1] == '\\') return j + 2;
  return null;
}

bool _isCsiParam(int c) =>
    (c >= 0x30 && c <= 0x39) || c == 0x3B || c == 0x3F;

bool _isCsiIntermediate(int c) => c >= 0x20 && c <= 0x2F;

bool _isCsiFinal(int c) => c >= 0x40 && c <= 0x7E;

/// `stripAnsi` 的两字节规则：ESC + `@-Z` 或 `\]^_`。
/// **`[` 与 `]` 的分工不是笔误**：`[`(0x5B) 被排除是因为它由 CSI 分支负责，
/// `]`(0x5D) 在 `\]^_` 里 —— 所以 OSC 匹配失败时会退到这一支吃掉 `\x1b]`。
bool _isTwoByteFinal(int c) =>
    (c >= 0x40 && c <= 0x5A) || (c >= 0x5C && c <= 0x5F);

AnsiStyle _applySgr(AnsiStyle style, String params) {
  // `ESC[m` 与 `ESC[0m` 等价：空参数就是 0。
  if (params.isEmpty) return AnsiStyle.none;

  final parts = params.split(';');
  var i = 0;
  while (i < parts.length) {
    final part = parts[i];
    // 空串是 0（ANSI 如此，`ESC[;31m` 的第一个参数就是 0）；
    // **但解析不出来的数字参数要忽略，不能当 0** —— 当 0 就是一次意外的
    // 全样式清空，而那个数字很可能只是设备吐出的垃圾。
    final int? code = part.isEmpty ? 0 : int.tryParse(part);
    if (code == null) {
      i++;
      continue;
    }

    if (code == 0) {
      style = AnsiStyle.none;
    } else if (code == 1) {
      style = style.copyWith(bold: true);
    } else if (code == 4) {
      style = style.copyWith(underline: true);
    } else if (code == 7) {
      style = style.copyWith(reverse: true);
    } else if (code == 22) {
      style = style.copyWith(bold: false);
    } else if (code == 24) {
      style = style.copyWith(underline: false);
    } else if (code == 27) {
      style = style.copyWith(reverse: false);
    } else if (code == 39) {
      style = style.copyWith(foreground: null);
    } else if (code == 49) {
      style = style.copyWith(background: null);
    } else if (code >= 30 && code <= 37) {
      style = style.copyWith(foreground: AnsiBasic(code - 30));
    } else if (code >= 40 && code <= 47) {
      style = style.copyWith(background: AnsiBasic(code - 40));
    } else if (code >= 90 && code <= 97) {
      style = style.copyWith(foreground: AnsiBasic(code - 90 + 8));
    } else if (code >= 100 && code <= 107) {
      style = style.copyWith(background: AnsiBasic(code - 100 + 8));
    } else if (code == 38 || code == 48) {
      final extended = _readExtendedColor(parts, i + 1);
      if (extended == null) {
        // 写残了（截断、越界）。**丢掉这条 SGR 剩下的部分**，不去猜后面的
        // 数字属于谁 —— 猜错就是把一个随机数字当成颜色。
        return style;
      }
      style = code == 38
          ? style.copyWith(foreground: extended.color)
          : style.copyWith(background: extended.color);
      i = extended.next;
      continue;
    }
    // 其余（字体、闪烁、隐藏…）V1 不支持，**静默忽略**：它们只影响外观，
    // 忽略的代价是少一种装饰；而在这里抛异常会让一条设备输出把整个输出区搞挂。
    i++;
  }
  return style;
}

/// 读 `38`/`48` 之后的扩展颜色，返回 `(颜色, 下一个待处理参数下标)`。
({AnsiColor color, int next})? _readExtendedColor(List<String> parts, int start) {
  if (start >= parts.length) return null;
  final mode = int.tryParse(parts[start]);
  if (mode == 5) {
    if (start + 1 >= parts.length) return null;
    final n = int.tryParse(parts[start + 1]);
    if (n == null || n < 0 || n > 255) return null;
    return (color: Ansi256(n), next: start + 2);
  }
  if (mode == 2) {
    if (start + 3 >= parts.length) return null;
    final r = int.tryParse(parts[start + 1]);
    final g = int.tryParse(parts[start + 2]);
    final b = int.tryParse(parts[start + 3]);
    bool inByte(int? v) => v != null && v >= 0 && v <= 255;
    if (!inByte(r) || !inByte(g) || !inByte(b)) return null;
    return (color: AnsiRgb(r!, g!, b!), next: start + 4);
  }
  return null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/render/ansi_parser_test.dart`
Expected: `All tests passed!`（28 条）

- [ ] **Step 5: Commit**

```bash
git add lib/render/ansi_parser.dart test/render/ansi_parser_test.dart
git commit -m "feat(render): SGR 解析（样式片段 / 256 色与真彩 / 与 stripAnsi 对拍）"
```

- [ ] **Step 6: 让 `LogWriter` 改用同一套规则**

到这一步两条路径的剥离规则才对齐。改的是 `lib/data/log_writer.dart` 的两行，
**不动它的任何断言** —— 现有那条「日志里落的是剥离控制符后的文本」在改前改后
都必须绿。

在 `test/data/log_writer_test.dart` 的末尾（`}` 之前）加一条：

```dart
  test('日志的剥离规则与输出区是同一套（§5.6「与输出区所见一致」）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      // 这条输入里三种控制序列都有：CSI 擦除、OSC 标题、两字节转义。
      await w.write('\x1b[2J\x1b]0;标题\x07\x1b[1m[CoreSW]\x1b[0m\r\n');
      await w.end();
      final line = (await logged(w)).split('\n')[1];
      expect(line, '[2026-09-24 14:30:12.001] [CoreSW]');
    });
  });
```

改 `lib/data/log_writer.dart`：

```dart
// 改 import：删掉 '../render/ansi.dart',加上 '../render/ansi_parser.dart'
import '../render/ansi_parser.dart';
```

```dart
// write() 里：把 stripAnsi(text) 换成 stripToPlainText(text)
    final clean = stripToPlainText(text);
```

同时把 `write()` 上方的文档注释按事实改一句：现在剥离规则来自
`ansi_parser.dart`，与输出区同源（原来的注释只说"§5.6 要求一致"，没说怎么保证）。

跑两个文件确认都没坏：

```bash
flutter test test/data/log_writer_test.dart
flutter test test/render/ansi_parser_test.dart
```

Expected: 前一个 `All tests passed!`（18 条），后一个 `All tests passed!`（28 条）。

```bash
git add lib/data/log_writer.dart test/data/log_writer_test.dart
git commit -m "refactor(data): 日志的剥离规则改用 ansi_parser（与输出区同源）"
```

---

## 收尾

九个任务跑完之后：

```bash
dart analyze
flutter test
```

两条都必须干净。`flutter test` 是**整仓**跑（前三个计划留下的用例也在内），
**不要**同时起第二个 `flutter test`（spec §13.23 的锁竞争会把两边都拖死）。

---

## 本计划发现的既有问题（**记录，不在本计划修**）

沿用 spec §13.24 的口径：这些都在**已冻结**的代码里（每处都有字节精确的计划围栏），
改一个词就是净增的工作量，而且会把"计划 1/2 的产物"重新搅动一遍。

| 位置 | 问题 | 什么时候修 |
|---|---|---|
| `lib/render/ansi.dart:9` | `_twoByte` 的字符类是 `@-Z\]^_`，**不含 `(`**，所以 `ESC ( B`（选择字符集，三字节）不会被剥离 —— 而它自己那行注释恰好拿 `ESC ( B` 当例子。三字节序列本来就不是两字节规则能覆盖的，缺的是一条 `\x1b[()*+][0-9A-Za-z]` 之类的新规则。**Task 9 的语料对拍用例把这条固定成了"两边都不剥离"**，所以日志与输出区至少是一致的 | 下一次有任务要动 `ansi.dart` 时顺手补，并给这条对拍用例改期望 |
| `lib/connection/connection_manager.dart:187` | 重叠的 `connect()` 会漏拆会话（注释里已详述，含实测数字）。根治要给每次尝试配代际令牌 | **必须先落地再让界面从用户手势驱动 `connect()`**，即计划 5 的前置条件 |
| `lib/connection/connection_manager.dart:280` | `onError: (Object _) {}` 是静默吞掉的保险（注释已说明它永远不该触发） | 评审结论是"留着"；真触发时没有事件、没有日志，别指望它报信 |
