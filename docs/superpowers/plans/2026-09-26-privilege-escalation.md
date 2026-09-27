# 提权（登录后 `en` 进入特权模式）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让设备在登录后自动执行提权命令（如 `en`）、必要时提交提权口令，进入特权模式（`Ruijie#`）后才算连接成功。

**Architecture:** 在 `ConnectionManager` 里、`SessionReady` 发出**之前**插入一个纯逻辑状态机 `EnableSequence`：它复用已有的 `PromptDetector`，直接通过 `Session.write` 与设备交互，成功后才让会话进入 `connected`；失败则走 FR-C-06 的可读原因 + 重连排程，且**不下发** `postLoginCommands`。提权口令与登录口令一样是凭据，因此把 `CredentialStore` 从 `String?` 扩成携带两个秘密的 `DeviceSecrets` 值对象（NFR-S-01 要求凭据读写收在一个接口后面）。

**Tech Stack:** Flutter 3.44.4 / Dart 3.12.2，`flutter_riverpod`，`dartssh2` 4.1.0。测试用 `flutter test`（**绝不用 `dart test`**）、`package:fake_async`。

---

## 背景：为什么必须插在 `SessionReady` 之前

真机实测（2026-09-26，锐捷 S6990-128QC2XS-E，10.166.96.41）：

```
[ 325ms] "Ruijie>"                      ← 登录提示符，会话就绪
--- 发送 "en" ---
[3004ms] "en\r\r\n"
[3032ms] "\r\r\nPassword:"
--- 发送口令 ---
[6009ms] "\r\r\n"
[6012ms] "Ruijie#"
```

这期间设备停在 `Password:` 上，而它**不是**命令行提示符。此时若让 `CommandDispatcher` 开始发用户命令（FR-C-08 的 `postLoginCommands` 或用户手输的命令），那些命令会被设备当成口令吃掉 —— 轻则提权失败，重则反复输错口令把账号锁掉。

已实测过的**错误做法**（不要走这条路）：把 `postLoginCommands` 配成 `['en', '〈提权口令〉']`。它确实能进特权模式，但是靠 `commandTimeout`（10s）强制放行下一条 —— 每次连接都白等 ~11s，每次都发一条假的「第 1/2 条命令执行超时」告警；而且一旦用户把口令那一行漏掉，下一条命令就会被当口令喂进去。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `lib/models/device_profile.dart` | 加 `enableCommand` / `enablePassword` 两个字段（模型保持"纯数据 + 往返"） | 改 |
| `lib/data/credential_store.dart` | 凭据接口从 `String?` 扩成 `DeviceSecrets`（NFR-S-01 的落脚点） | 改 |
| `lib/data/device_store.dart` | 两处调用点跟着改（读盘 / 存盘） | 改 |
| `lib/connection/enable_sequence.dart` | **新**：提权状态机，纯 Dart，零 flutter import | 建 |
| `lib/connection/connection_manager.dart` | 在 `SessionReady` 之前跑提权，失败则走 FR-C-06 + 不进已连接 | 改 |
| `lib/ui/dialogs/device_edit_dialog.dart` | 两个输入框 + 明文告警 | 改 |
| `lib/state/providers.dart` | `DevicesNotifier.add` 逐字段重建时补两个字段 | 改 |

**不改的地方（有意为之）：**

- `_displayOnlyFields = {'name', 'autoConnect', 'snippets'}`（`device_edit_dialog.dart:13`）**一个字都不动**。它是"显示字段"白名单，其余一律算连接参数；新字段自动落进"连接参数"，于是改了提权设置就断线重连 —— 这正是想要的（提权参数变了必须重连才生效）。
- `kDevicesSchemaVersion` **不升**。新字段缺失时 `as String?` 读出 null，v1/v2 文件都能读，无需迁移。
- `ConnectionFailureKind` **不加新枚举值**。口令被拒 → `authFailed`；设备没反应 → `timeout`。两者文案都是提权专属的，用户看不出复用了枚举。

---

## Task 1: `DeviceProfile` 增加两个提权字段

**Files:**
- Modify: `lib/models/device_profile.dart`
- Test: `test/models/device_profile_test.dart`

- [ ] **Step 1: 写失败的测试**

追加到 `test/models/device_profile_test.dart` 的 `main()` 里：

```dart
  test('提权字段：往返保留，缺省为 null', () {
    const full = DeviceProfile(
      id: 'd1',
      name: '汇聚交换机',
      protocol: DeviceProtocol.ssh,
      host: '10.0.0.1',
      port: 22,
      username: 'admin',
      enableCommand: 'en',
      enablePassword: 'enable-secret',
    );
    final back = DeviceProfile.fromJson(full.toJson());
    expect(back.enableCommand, 'en');
    expect(back.enablePassword, 'enable-secret');

    // 老文件里没有这两个键 —— 必须读成 null（"不提权"），不是空串。
    final legacy = DeviceProfile.fromJson(
      Map<String, Object?>.of(full.toJson())
        ..remove('enableCommand')
        ..remove('enablePassword'),
    );
    expect(legacy.enableCommand, isNull);
    expect(legacy.enablePassword, isNull);
  });

  test('提权字段的 null 有语义，copyWith 不能被 `??` 吞掉', () {
    const profile = DeviceProfile(
      id: 'd1',
      name: 'x',
      protocol: DeviceProtocol.ssh,
      host: 'h',
      port: 22,
      username: 'u',
      enableCommand: 'en',
      enablePassword: 'pw',
    );
    // 必须传 Object? 哨兵才能清空 —— 传 null 表示"我就是要清空"。
    final cleared = profile.copyWith(
      enableCommand: null,
      enablePassword: null,
    );
    expect(cleared.enableCommand, isNull, reason: '清空提权命令不能被 ?? 吃掉');
    expect(cleared.enablePassword, isNull, reason: '清空提权口令不能被 ?? 吃掉');

    // 不传则保持原值。
    expect(profile.copyWith(name: 'y').enableCommand, 'en');
  });
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/models/device_profile_test.dart`
Expected: 编译失败 —— `The named parameter 'enableCommand' isn't defined`。

- [ ] **Step 3: 加字段**

在 `lib/models/device_profile.dart` 的构造函数里，`this.privateKeyPath,` 之后插入：

```dart
    this.enableCommand,
    this.enablePassword,
```

字段声明（放在 `final String? privateKeyPath;` 之后）：

```dart
  /// 登录后自动执行的**提权命令**（如 `en`）。null 表示这台设备不提权。
  ///
  /// **null 与空串不同**：空串会真的往设备发一个空行。与 [password] 同理，
  /// 它的 null 是有语义的，所以 [copyWith] 用哨兵而不是 `?? this.x`。
  final String? enableCommand;

  /// 提权口令。null 表示设备不问口令（Cisco 形态的 `en` 直达 `#`）。
  ///
  /// **它是凭据，不是普通字段**：存盘时由 `CredentialStore` 负责从记录里
  /// 剥掉（NFR-S-01），读取时再由它填回来 —— 与 [password] 走同一条路。
  final String? enablePassword;
```

`copyWith` 的形参加在 `Object? privateKeyPath = _unset,` 之后：

```dart
    Object? enableCommand = _unset,
    Object? enablePassword = _unset,
```

`copyWith` 的构造函数调用里加（同样在 `privateKeyPath` 那一段之后）：

```dart
        enableCommand: identical(enableCommand, _unset)
            ? this.enableCommand
            : enableCommand as String?,
        enablePassword: identical(enablePassword, _unset)
            ? this.enablePassword
            : enablePassword as String?,
```

`fromJson` 里加（`privateKeyPath` 之后）：

```dart
        enableCommand: json['enableCommand'] as String?,
        enablePassword: json['enablePassword'] as String?,
```

`toJson` 里加（`'privateKeyPath': privateKeyPath,` 之后）：

```dart
        'enableCommand': enableCommand,
        'enablePassword': enablePassword,
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/models/device_profile_test.dart`
Expected: PASS（含原有的往返用例）。

- [ ] **Step 5: 提交**

```bash
git add lib/models/device_profile.dart test/models/device_profile_test.dart
git commit -m "feat(model): 设备增加提权命令与提权口令两个字段"
```

---

## Task 2: `CredentialStore` 携带两个秘密（`DeviceSecrets`）

**为什么现在改：** NFR-S-01 要求凭据读写收在一个接口后面，将来换成系统密钥库时只换实现。提权口令是第二个秘密 —— 如果给它单独加一对 `readEnablePassword`/`writeEnablePassword` 方法，接口形状就会牵着密钥库实现的条目形状走（一个秘密一个条目 vs 一台设备一个条目），而那是实现细节。一次改成值对象，接口就稳定了。

**Files:**
- Modify: `lib/data/credential_store.dart`
- Modify: `lib/data/device_store.dart:158-163`（读盘）、`lib/data/device_store.dart:228-229`（存盘）
- Test: `test/data/credential_store_test.dart`、`test/data/device_store_load_test.dart`、`test/data/device_store_save_test.dart`、`test/state/app_stores_test.dart`

- [ ] **Step 1: 写失败的测试**

在 `test/data/credential_store_test.dart` 的 `main()` 里追加：

```dart
  test('两个秘密一起进出，strip 把两个都剥掉', () {
    const store = PlaintextCredentialStore();
    final record = <String, Object?>{
      'id': 'd1',
      'password': 'login',
      'enablePassword': 'enable',
    };

    final secrets = store.read(record);
    expect(secrets.password, 'login');
    expect(secrets.enablePassword, 'enable');

    final stripped = store.strip(record);
    expect(stripped.containsKey('password'), isFalse);
    expect(
      stripped.containsKey('enablePassword'),
      isFalse,
      reason: 'NFR-S-01：提权口令也是凭据，绝不能留在 devices.json 里',
    );
    // strip 无副作用（原记录不能被改）。
    expect(record['enablePassword'], 'enable');

    // 写回：两个都落在记录自己的字段上。
    final target = <String, Object?>{'id': 'd2'};
    store.write(
      target,
      const DeviceSecrets(password: 'p', enablePassword: 'e'),
    );
    expect(target['password'], 'p');
    expect(target['enablePassword'], 'e');

    // null = 删键，而不是写 null（与密钥库实现的文件形状保持一致）。
    store.write(target, const DeviceSecrets(password: 'p'));
    expect(target['password'], 'p');
    expect(target.containsKey('enablePassword'), isFalse);
  });
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/data/credential_store_test.dart`
Expected: 编译失败 —— `The named parameter 'enablePassword' isn't defined` / `DeviceSecrets` 未定义。

- [ ] **Step 3: 改接口与明文实现**

把 `lib/data/credential_store.dart` 整个文件替换为：

```dart
/// 一台设备的全部凭据。
///
/// **它们必须一起进出接口**，而不是各自加一对方法 —— 每多一个秘密就多一对
/// `readXxx`/`writeXxx` 的话，将来换成系统密钥库时，接口的形状会牵着密钥库
/// 里条目的形状走（一个秘密一个条目 vs 一台设备一个条目），而那是实现细节。
class DeviceSecrets {
  const DeviceSecrets({this.password, this.enablePassword});

  /// 登录口令。null 表示不用密码认证（走密钥）。
  final String? password;

  /// 提权（`en`）口令。null 表示设备不问口令。
  final String? enablePassword;

  /// 值相等（与 `Snippet` 同一个理由：spec §13.7）。
  ///
  /// 存在的直接理由：接口契约用例要拿一个"什么都没取到"的结果去比
  /// （`expect(vault.secretFor('d1'), const DeviceSecrets())`），没有 `==`
  /// 那就是身份比较，永远红。
  ///
  /// **刻意不覆写 `toString()`。** `expect` 失败时会把实际值打出来，
  /// 而这个类的字段就是口令。默认的 `Instance of 'DeviceSecrets'` 什么都不泄露；
  /// 好心加一个"方便调试"的 `toString()` 会把口令写进测试日志与 CI 输出。
  @override
  bool operator ==(Object other) =>
      other is DeviceSecrets &&
      other.password == password &&
      other.enablePassword == enablePassword;

  @override
  int get hashCode => Object.hash(password, enablePassword);
}

/// 凭据存储。**NFR-S-01 的落脚点**：V1 明文存盘是被接受的决策，但"明文"
/// 必须是**一个实现类**里的细节，而不是散在 store 与模型里的字段访问。
///
/// 入参是**一条设备记录的 JSON map**，不是 `DeviceProfile` —— 模型保持冻结
/// （spec §13.1）。换成系统密钥库时，只需要换掉本接口的实现，
/// `DeviceStore` 与 `DeviceProfile` 一行都不用改。
abstract class CredentialStore {
  /// 取出这条记录的凭据。没有的字段是 null。
  DeviceSecrets read(Map<String, Object?> record);

  /// 把凭据写进这条记录并**负责决定它落在哪里**。
  ///
  /// [DeviceSecrets] 里为 null 的字段表示"这台设备没有该项凭据"。
  void write(Map<String, Object?> record, DeviceSecrets secrets);

  /// 返回一条**不含凭据**的记录副本，可以安全地交给模型或写进文件。
  ///
  /// **必须无副作用，且必须与 [write] 分开。** 读盘路径上如果图省事写成
  /// `write(record, const DeviceSecrets())`，那么在一个把凭据存进系统密钥库的
  /// 实现下，这就变成了"删掉用户密钥库里的条目"—— 读一次盘毁一次凭据，
  /// 而且用户只会看到"密码莫名其妙没了"。
  ///
  /// **[DeviceSecrets] 里每一个非 null 字段都必须被剥掉。** 漏掉一个，
  /// 在密钥库实现下那个秘密就**照旧落进 devices.json** —— 而那正是
  /// NFR-S-01 要防的泄露。
  Map<String, Object?> strip(Map<String, Object?> record);
}

/// V1 实现：明文，就写在记录自己的字段上（spec §8.6 / NFR-S-01）。
///
/// **字段名 `password` / `enablePassword` 不是本类的私事，而是与模型共享的
/// 契约**：`DeviceProfile` 的 `toJson` 写出这两个键、`fromJson` 也从它们读
/// 回来。所以 [strip] 必须删掉的正是**模型写出的那两个键** —— 别把它们改成
/// "不那么显眼"的名字。在明文实现下改它只是让往返测试变红；在密钥库实现下，
/// [strip] 就删不掉模型的 `password`，明文**照旧落进 devices.json**，
/// 而那正是 NFR-S-01 要防的泄露。
///
/// 本类唯一决定的是**凭据落在哪里**（就地写进 record）。别的代码要拿密码，
/// 走 [read]；要写密码，走 [write]。
class PlaintextCredentialStore implements CredentialStore {
  const PlaintextCredentialStore();

  /// 与模型共享的键名。**加字段时这里是第二个必须改的地方**
  /// （第一个是 `DeviceProfile.toJson`）—— 漏了它，[strip] 就漏剥一个秘密。
  static const List<String> keys = ['password', 'enablePassword'];

  @override
  DeviceSecrets read(Map<String, Object?> record) => DeviceSecrets(
        password: record['password'] as String?,
        enablePassword: record['enablePassword'] as String?,
      );

  @override
  void write(Map<String, Object?> record, DeviceSecrets secrets) {
    _put(record, 'password', secrets.password);
    _put(record, 'enablePassword', secrets.enablePassword);
  }

  @override
  Map<String, Object?> strip(Map<String, Object?> record) {
    final copy = Map<String, Object?>.of(record);
    for (final key in keys) {
      copy.remove(key);
    }
    return copy;
  }

  /// 删键而不是写 null：`"password": null` 与"没有这个键"在读取时等价，
  /// 但只有删键这个形状与密钥库实现（记录里根本没有这个键）一致 ——
  /// 两个实现对"没有凭据"给出同一种文件形状，往返测试才写得干净。
  static void _put(Map<String, Object?> record, String key, String? value) {
    if (value == null) {
      record.remove(key);
    } else {
      record[key] = value;
    }
  }
}
```

- [ ] **Step 4: 改 `device_store.dart` 的两处调用点**

读盘（`lib/data/device_store.dart:158-163`），把：

```dart
        final password = credentials.read(record);
        final profile =
            DeviceProfile.fromJson(credentials.strip(record)).copyWith(
          password: password,
        );
```

换成：

```dart
        final secrets = credentials.read(record);
        final profile =
            DeviceProfile.fromJson(credentials.strip(record)).copyWith(
          password: secrets.password,
          // 提权口令同样是凭据，走同一条路（NFR-S-01）。
          enablePassword: secrets.enablePassword,
        );
```

存盘（`lib/data/device_store.dart:228-229`），把：

```dart
      final record = credentials.strip(device.toJson());
      credentials.write(record, device.password);
```

换成：

```dart
      final record = credentials.strip(device.toJson());
      credentials.write(
        record,
        DeviceSecrets(
          password: device.password,
          enablePassword: device.enablePassword,
        ),
      );
```

- [ ] **Step 5: 改 `credential_store_test.dart` 里**原有**的 8 条用例**

**这一步是写计划时漏掉的，别跳过。** `read` 的返回类型从 `String?` 变成了
`DeviceSecrets`，所以该文件里原有的这几条会编译不过或断言失败。**逐条按下面的
新形状改，一条都不许删、不许弱化** —— 它们各自钉着一个边界：

```dart
    test('read 取出 password 字段', () {
      expect(
        store.read({'id': 'd1', 'password': 'hunter2'}).password,
        'hunter2',
      );
    });

    test('read 在没有该字段时返回 password 为 null 的结果', () {
      // **不再是 `isNull`。** 现在返回的是一个值对象，"没取到"表现为它
      // 两个字段都是 null，而不是结果本身为 null —— 这样调用方不必对
      // 返回值做空判断（NFR-S-01：换成密钥库实现时，多一个秘密不该多一层解包）。
      expect(store.read({'id': 'd1'}).password, isNull);
      expect(store.read({'id': 'd1'}).enablePassword, isNull);
    });

    test('read 在字段显式为 null 时返回 password 为 null 的结果', () {
      expect(store.read({'id': 'd1', 'password': null}).password, isNull);
    });

    test('write 一个非 null 值会写进字段', () {
      final record = <String, Object?>{'id': 'd1'};
      store.write(record, const DeviceSecrets(password: 'secret'));
      expect(record['password'], 'secret');
    });

    test('write null 是**删掉字段**，不是写一个 null 进去', () {
      final record = <String, Object?>{'id': 'd1', 'password': 'old'};
      store.write(record, const DeviceSecrets());
      expect(
        record.containsKey('password'),
        isFalse,
        reason: '留一个 "password": null 会让换密钥库后的文件看起来"还是有密码"',
      );
    });
```

`strip` 那三条（去掉凭据且不改原记录 / 返回副本 / 对没有凭据的记录安全）**断言
一个字都不用动** —— `strip` 的签名没变。只要把 `credential_store_test.dart:5`
那段 group 里其余用例按上面的形状改完即可。

契约 group 里那条"一个不写文件的实现可以让存盘结果里根本没有 password 键"
按下面改：

```dart
    test('一个不写文件的实现可以让存盘结果里根本没有 password 键', () {
      final vault = _FakeVault();
      final record = <String, Object?>{'id': 'd1', 'port': 22};
      vault.write(record, const DeviceSecrets(password: 'secret'));
      expect(
        record.containsKey('password'),
        isFalse,
        reason: '密钥库实现把密码放在记录之外 —— 这正是接口存在的意义',
      );
      expect(vault.secretFor('d1'), const DeviceSecrets(password: 'secret'));
      expect(vault.read(record).password, 'secret');
    });
```

- [ ] **Step 6: 改四个测试假实现**

这四个类 `implements CredentialStore`，接口一变就必须跟着改。逐个替换成下面的形状（各自保留原有的记录/返回值逻辑，只换签名）：

`test/data/credential_store_test.dart` 的 `_FakeVault`：

```dart
class _FakeVault implements CredentialStore {
  final _byId = <String, DeviceSecrets>{};

  DeviceSecrets? secretFor(String id) => _byId[id];

  @override
  DeviceSecrets read(Map<String, Object?> record) =>
      _byId[record['id'] as String?] ?? const DeviceSecrets();

  @override
  void write(Map<String, Object?> record, DeviceSecrets secrets) {
    final id = record['id'] as String?;
    if (id == null) return;
    _byId[id] = secrets;
  }

  @override
  Map<String, Object?> strip(Map<String, Object?> record) {
    final copy = Map<String, Object?>.of(record);
    for (final key in PlaintextCredentialStore.keys) {
      copy.remove(key);
    }
    return copy;
  }
}
```

`test/data/device_store_load_test.dart` 的 `_Vault`（保留 `readIds` 记录）：

```dart
class _Vault implements CredentialStore {
  final readIds = <String>[];

  @override
  DeviceSecrets read(Map<String, Object?> record) {
    readIds.add(record['id']! as String);
    return const DeviceSecrets(password: '来自密钥库', enablePassword: '密钥库提权口令');
  }

  @override
  void write(Map<String, Object?> record, DeviceSecrets secrets) {}

  @override
  Map<String, Object?> strip(Map<String, Object?> record) {
    final copy = Map<String, Object?>.of(record);
    for (final key in PlaintextCredentialStore.keys) {
      copy.remove(key);
    }
    return copy;
  }
}
```

同文件的 `_EmptyVault`：`read` 返回 `const DeviceSecrets()`，`write` 空实现，`strip` 同上。

`test/data/device_store_save_test.dart` 的 `_Vault` 与 `test/state/app_stores_test.dart` 的 `_Vault`：`read` 返回 `const DeviceSecrets()`，`write` 空实现，`strip` 同上。（`device_store_save_test.dart` 那个原来 `read` 返回 `'来自密钥库'`；它只被存盘路径用到，存盘路径不读，改成 `const DeviceSecrets()` 不影响任何断言。）

- [ ] **Step 7: 跑测试确认通过**

Run: `flutter test test/data/ test/state/app_stores_test.dart`
Expected: PASS。**`device_store_load_test.dart` 与 `device_store_save_test.dart` 里原有的"凭据不进文件"用例必须全绿** —— 它们正是 NFR-S-01 的守卫，接口改动若让其中一个变红，是改动错了，不是用例错了。

- [ ] **Step 8: 提交**

```bash
git add lib/data/credential_store.dart lib/data/device_store.dart test/data/credential_store_test.dart test/data/device_store_load_test.dart test/data/device_store_save_test.dart test/state/app_stores_test.dart
git commit -m "refactor(data): 凭据接口携带登录+提权两个秘密（NFR-S-01）"
```

- [ ] **Step 9: 补一条端到端守卫（**写计划时漏了，必须补**）**

上面只钉住了"`strip` 会剥掉 `enablePassword`"这一个**单元**行为。真正要保证的是
**端到端**：提权口令能存能读，且在任何实现下都不落进 `devices.json`。
两者之间隔着 `DeviceStore.save` / `load` 的调用点 —— 那里少传一个字段，
`strip` 再正确也没用，而**没有任何用例会发现**。

`test/data/device_store_save_test.dart` 里已有两条守卫
（「明文实现：密码出现在文件里」「密钥库实现：文件里根本没有 password 键」），
新的一条与它们并列。先给该文件的 `profile` 辅助加一个可选参数（默认 null，
现有用例行为不变）：

```dart
  DeviceProfile profile(
    String id, {
    String? name,
    String? password,
    String? enablePassword,
    List<String> hops = const [],
    List<Snippet> snippets = const [],
  }) =>
      DeviceProfile(
        // …原有字段不动…
        password: password,
        enablePassword: enablePassword,
        // …
      );
```

然后追加用例：

```dart
  test('提权口令与登录口令一起往返，且密钥库实现下都不落文件（NFR-S-01）', () async {
    // ① 明文实现：两个秘密都要能存能读。提权口令走的是与登录口令同一条
    //    剥/写路径（`credentials.strip` → `credentials.write`），
    //    任何一头漏了都会在这里断。
    final plain = profile(
      'd1',
      password: 'login-secret',
      enablePassword: 'enable-secret',
    );
    await store().save([plain]);

    final back = (await store().load()).devices.single;
    expect(back.password, 'login-secret');
    expect(
      back.enablePassword,
      'enable-secret',
      reason: '存盘→读盘往返不能丢提权口令（save/load 的调用点少传了字段）',
    );

    final raw = await file.readAsString();
    expect(raw, contains('login-secret'));
    expect(
      raw,
      contains('enable-secret'),
      reason: '明文实现下两个都落在文件里 —— 这是 V1 已接受的决策',
    );

    // ② 密钥库实现：两个都**不许**出现在文件里。这条才是 NFR-S-01 的守卫。
    final vaultFile = File('${root.path}/vault.json');
    await DeviceStore(file: vaultFile, credentials: _Vault()).save([plain]);
    final vaultRaw = await vaultFile.readAsString();
    expect(vaultRaw, isNot(contains('login-secret')));
    expect(
      vaultRaw,
      isNot(contains('enable-secret')),
      reason: 'strip 漏剥 enablePassword ⇒ 提权口令明文落进 devices.json',
    );
  });
```

Run: `flutter test test/data/device_store_save_test.dart`
Expected: PASS。

```bash
git add test/data/device_store_save_test.dart
git commit -m "test(data): 提权口令的存读往返与不落盘守卫（NFR-S-01）"
```

---

## Task 3: `EnableSequence` 提权状态机

**Files:**
- Create: `lib/connection/enable_sequence.dart`
- Test: `test/connection/enable_sequence_test.dart`

**设计要点（读代码前先读这段）：**

1. **回显闸门。** 建连横幅（`Ruijie>`）与我们发 `en` 之后设备回的提示符，在缓冲区里长得一样。为不让横幅被误判成"提权成功"，成功判据是：**缓冲区里出现过换行**，且**换行之后**的那一段以提示符结尾（回显必然在第一行，所以第一行不看）。设备不回显时缓冲区始终没有换行 —— 那条路由 `echoGrace` 兜底。
2. **口令提示先判。** 默认提示符正则 `[>#\]]\s*$` 匹配不上 `Password:`，但用户可以在设备上自定义 `promptRegex`，那个正则**可能**匹配它。所以每个状态下都先判口令提示、再判提示符。
3. **每次发送前清空缓冲。** 不清的话，建连横幅与上一条口令提示符会留在里面，被下一次判定当成"设备已经给了提示符/又在要口令"。

- [ ] **Step 1: 写失败的测试**

新建 `test/connection/enable_sequence_test.dart`：

```dart
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';
import 'package:win_cli_tool/connection/connection_failure.dart';
import 'package:win_cli_tool/connection/enable_sequence.dart';

/// 真机实录（2026-09-26，锐捷 S6990，10.166.96.41）的时序与字节。
/// 分块投喂，是为了让"同一 chunk 里同时有回显与口令提示"这条路径也被走到。
const _echoEn = 'en\r\r\n';
const _passwordPrompt = '\r\r\nPassword:';
const _privileged = 'Ruijie#';

void main() {
  test('有口令：发 en → 等口令提示 → 发口令 → 等特权提示符', () {
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: 'enable-secret',
      );

      ConnectionFailure? result;
      var completed = false;
      seq.start().then((f) {
        result = f;
        completed = true;
      });

      // 建连横幅先到（此时还没发 en）—— 它绝不能被当成提权成功。
      seq.onOutput('Ruijie>');
      async.elapse(const Duration(milliseconds: 100));
      expect(completed, isFalse, reason: '建连横幅不是提权成功');

      // settleDelay 到点 → 发 en。
      async.elapse(const Duration(milliseconds: 300));
      expect(written, ['en\n']);

      seq.onOutput(_echoEn);
      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();
      expect(written, ['en\n', 'enable-secret\n'], reason: '看到口令提示就该发口令');

      seq.onOutput('\r\r\n');
      seq.onOutput(_privileged);
      async.flushMicrotasks();
      expect(completed, isTrue);
      expect(result, isNull, reason: 'null = 提权成功');
      // 定时器都清干净了，不然 fakeAsync 会报 "pending timers"。
      async.elapse(const Duration(minutes: 1));
    });
  });

  test('无口令（Cisco 形态 en 直达 #）：不发第二笔', () {
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: null,
      );

      ConnectionFailure? result;
      var completed = false;
      seq.start().then((f) {
        result = f;
        completed = true;
      });
      async.elapse(const Duration(milliseconds: 300));

      seq.onOutput('en\r\r\n');
      seq.onOutput('Ruijie#');
      async.flushMicrotasks();

      expect(completed, isTrue);
      expect(result, isNull);
      expect(written, ['en\n'], reason: '设备不问口令就不该有第二笔写入');
      async.elapse(const Duration(minutes: 1));
    });
  });

  test('设备要口令但没配：立刻报错，不把命令当口令喂进去', () {
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: null,
      );

      ConnectionFailure? result;
      seq.start().then((f) => result = f);
      async.elapse(const Duration(milliseconds: 300));

      seq.onOutput('en\r\r\n');
      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();

      expect(result, isNotNull);
      expect(result!.kind, ConnectionFailureKind.authFailed);
      expect(result!.message, contains('提权口令'));
      expect(written, ['en\n'], reason: '没有口令可发，绝不能把别的东西写下去');
      async.elapse(const Duration(minutes: 1));
    });
  });

  test('口令被拒：重来一遍；两次都被拒就报认证失败', () {
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: '错的',
      );

      ConnectionFailure? result;
      seq.start().then((f) => result = f);
      async.elapse(const Duration(milliseconds: 300));
      expect(written, ['en\n']);

      // 第一次：要口令 → 发 → 又被要（口令错）。
      seq.onOutput('en\r\r\n$_passwordPrompt');
      async.flushMicrotasks();
      expect(written, ['en\n', '错的\n']);

      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();
      expect(written, ['en\n', '错的\n', 'en\n'], reason: '口令被拒要重来一遍');

      // 第二次又被拒 → 两次用完，报错。
      seq.onOutput('en\r\r\n$_passwordPrompt');
      async.flushMicrotasks();
      expect(written, ['en\n', '错的\n', 'en\n', '错的\n']);

      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();

      expect(result, isNotNull);
      expect(result!.kind, ConnectionFailureKind.authFailed);
      expect(result!.message, contains('提权口令被拒'));
      async.elapse(const Duration(minutes: 1));
    });
  });

  test('设备没反应：重发一次，再没反应就报超时', () {
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: 'pw',
        attemptTimeout: const Duration(seconds: 6),
      );

      ConnectionFailure? result;
      seq.start().then((f) => result = f);

      async.elapse(const Duration(milliseconds: 300));
      expect(written, ['en\n']);

      // 第一次尝试超时 → 重发。
      async.elapse(const Duration(seconds: 6));
      expect(written, ['en\n', 'en\n']);

      // 第二次也超时 → 报错。
      async.elapse(const Duration(seconds: 6));
      expect(result, isNotNull);
      expect(result!.kind, ConnectionFailureKind.timeout);
      expect(result!.message, contains('提权超时'));
    });
  });

  test('口令以 # 结尾也不会被回显骗成成功', () {
    // 部分设备会回显口令，而口令本身可能以 `#` 或 `>` 结尾 ——
    // 直接拿最后一行去匹配，`abc#` 那行就变成了"特权提示符"。
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: 'abc#',
      );

      ConnectionFailure? result;
      var completed = false;
      seq.start().then((f) {
        result = f;
        completed = true;
      });
      async.elapse(const Duration(milliseconds: 300));

      seq.onOutput('en\r\r\n$_passwordPrompt');
      async.flushMicrotasks();
      seq.onOutput('abc#\r\r\n'); // 回显，末尾就是 '#'
      async.flushMicrotasks();
      expect(completed, isFalse, reason: '口令回显不是特权提示符');

      seq.onOutput('Ruijie#');
      async.flushMicrotasks();
      expect(completed, isTrue);
      expect(result, isNull);
      async.elapse(const Duration(minutes: 1));
    });
  });
}
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/connection/enable_sequence_test.dart`
Expected: 编译失败 —— `enable_sequence.dart` 不存在。

- [ ] **Step 3: 实现**

新建 `lib/connection/enable_sequence.dart`：

```dart
import 'dart:async';

import '../command/prompt_detector.dart';
import 'connection_failure.dart';

/// 提权序列进行到哪一步。
enum _Phase {
  /// 还没开始，或已经结束。
  idle,

  /// 已发出提权命令，等设备的反应（口令提示 / 提权后的提示符）。
  awaitingEnable,

  /// 已发出口令，等提权后的提示符。
  awaitingPassword,
}

/// 登录之后的提权序列：发 `en` → 若设备要口令则提交 → 等特权提示符。
///
/// **它必须在 `SessionReady` 之前跑完。** 这段交互里设备停在口令提示符
/// （`Password:`）而不是命令行提示符上；此时若把用户命令交给
/// `CommandDispatcher`，命令会被当成口令喂进去 —— 轻则提权失败，重则反复
/// 输错口令把账号锁掉。
///
/// **纯逻辑，零 IO**：只经 [write] 往设备写字，输出由调用方经 [onOutput] 喂
/// 进来。所以它可以脱离 socket 单测（`test/connection/enable_sequence_test.dart`）。
///
/// ## 回显闸门
///
/// 建连横幅（`Ruijie>`）与我们发 `en` 之后设备回的提示符，在缓冲区里长得
/// 一样 —— 直接拿"最后一行是不是提示符"当判据，横幅一到就会宣布提权成功，
/// 而那时口令一个字都还没发。所以成功判据是：**缓冲区里出现过换行，且换行
/// **之后**的那一段以提示符结尾**。理由是设备的回显必然在第一行：我们写下
/// `en`，设备先回 `en\r\r\n`，之后才是 `Password:` 或 `Ruijie#`。
///
/// 代价是**不回显的设备走不通这条路**（缓冲区永远没有换行）。它由 [echoGrace]
/// 兜底：到那一刻仍没见过换行，就退回看整个缓冲区。这个口子开得有限 ——
/// 横幅若被延迟投递，紧接着设备的回应就到了，最后一行会被它顶掉。
class EnableSequence {
  EnableSequence({
    required void Function(String) write,
    required PromptDetector promptDetector,
    required this.command,
    this.password,
    this.lineEnding = '\n',
    this.maxAttempts = 2,
    this.attemptTimeout = const Duration(seconds: 6),
    this.settleDelay = const Duration(milliseconds: 300),
    this.echoGrace = const Duration(seconds: 1),
  })  : _write = write,
        _promptDetector = promptDetector;

  final void Function(String) _write;

  /// 提权命令，如 `en`。
  final String command;

  /// 提权口令。null 表示设备不问口令（Cisco 形态的 `en` 直达 `#`）。
  final String? password;

  final String lineEnding;

  /// 提权命令最多发几次。"设备没反应"时重发，口令被拒时从头发一遍。
  final int maxAttempts;

  /// **单次**尝试的上限。
  ///
  /// 真机实测（2026-09-26，锐捷 S6990）：`en` 的回显 ~28ms、口令到 `#` ~3s。
  /// 6s 是后者的两倍余量；两次尝试合计 12s ≈ FR-C-13 的默认连接超时 15s ——
  /// 提权不该比建连本身还慢。
  final Duration attemptTimeout;

  /// 建连之后先等这么久再发提权命令。
  ///
  /// 存在的理由是**建连横幅可能被延迟投递**：横幅在设备时间上先于我们写的
  /// `en`，但它在缓冲区里的落点可能晚于 `en` 的回显。等一小会让横幅先落下来，
  /// 紧接着 [_writeAndWait] 会清空缓冲区把它丢掉，后面就再也干扰不到判定了。
  final Duration settleDelay;

  /// 到这一刻仍没见过换行 ⇒ 认为设备不回显，退回看整个缓冲区。
  /// 见类文档的"回显闸门"。
  final Duration echoGrace;

  final PromptDetector _promptDetector;

  /// 设备的口令提示。**实测原文是 `Password:`**（锐捷），以冒号结尾。
  ///
  /// 默认提示符正则 `[>#\]]\s*$` 匹配不上它，但用户可以在设备上自定义
  /// `promptRegex` —— 那个正则**可能**匹配。所以每个状态下都**先判它**。
  static final RegExp passwordPromptPattern =
      RegExp(r'(?i)password\s*[:：]?\s*$');

  _Phase _phase = _Phase.idle;
  String _buffer = '';
  int _attemptsLeft = 0;
  bool _graceElapsed = false;
  Timer? _attemptTimer;
  Timer? _settleTimer;
  Timer? _graceTimer;
  Completer<ConnectionFailure?>? _done;

  bool get _finished => _done?.isCompleted ?? false;

  /// 开始提权。
  ///
  /// 返回 **null 表示已进入特权模式**；否则是可直接展示给用户的失败
  /// （`ConnectionFailure.message`，FR-C-06）。
  ///
  /// **一个实例只能跑一次**（重复调用抛 `StateError`）—— 调用方每次连接新建
  /// 一个，这样"试到第几次了"这类状态不会跨会话串味。
  Future<ConnectionFailure?> start() {
    if (_done != null) {
      throw StateError('EnableSequence 只能跑一次：每次连接新建一个');
    }
    final completer = _done = Completer<ConnectionFailure?>();
    _attemptsLeft = maxAttempts;
    _settleTimer = Timer(
      settleDelay,
      () => _writeAndWait(command, _Phase.awaitingEnable),
    );
    return completer.future;
  }

  /// 会话输出，由 `ConnectionManager` 在它的 output 订阅里喂进来。
  ///
  /// 在 [start] 之前喂进来的输出**只是攒着**（建连横幅就是这种），
  /// 第一次 [_writeAndWait] 会把它清掉。
  void onOutput(String chunk) {
    if (_done == null || _finished) return;
    _buffer += chunk;
    _check();
  }

  /// 放弃这次提权（会话正在被拆掉时调用）。
  ///
  /// **以 null 完成 future**，看着像"成功"—— 调用方必须靠**身份**判断这次
  /// 提权还算不算数（`identical(_enable, sequence)`），而不是靠这个返回值。
  /// `ConnectionManager` 正是这么写的。
  void dispose() {
    _cancelTimers();
    _phase = _Phase.idle;
    if (!_finished) _done?.complete(null);
  }

  void _writeAndWait(String text, _Phase phase) {
    if (_finished) return;
    // **每次发送前清空缓冲。** 不清的话，建连横幅与上一条口令提示符会留在
    // 里面，被下一次 [_check] 当成"设备已经给了提示符 / 又在要口令"。
    _buffer = '';
    _graceElapsed = false;
    _phase = phase;
    _write('$text$lineEnding');
    _graceTimer?.cancel();
    _graceTimer = Timer(echoGrace, () {
      _graceElapsed = true;
      _check();
    });
    _attemptTimer?.cancel();
    _attemptTimer = Timer(attemptTimeout, _onAttemptTimeout);
  }

  void _check() {
    switch (_phase) {
      case _Phase.idle:
        return;
      case _Phase.awaitingEnable:
        if (_passwordPromptSeen()) {
          final pw = password;
          if (pw == null) {
            _fail(_missingPasswordFailure());
            return;
          }
          _writeAndWait(pw, _Phase.awaitingPassword);
          return;
        }
        if (_promptSeen()) _succeed();
      case _Phase.awaitingPassword:
        if (_passwordPromptSeen()) {
          // 又被要了一次口令 ⇒ 刚才那条不对。
          if (_attemptsLeft > 1) {
            _attemptsLeft--;
            _writeAndWait(command, _Phase.awaitingEnable);
          } else {
            _fail(_rejectedPasswordFailure());
          }
          return;
        }
        if (_promptSeen()) _succeed();
    }
  }

  /// 缓冲区末尾（回显之后的那一段）是否为设备提示符。
  ///
  /// 见类文档的"回显闸门"。
  bool _promptSeen() {
    final at = _buffer.indexOf('\n');
    if (at >= 0) {
      final after = _buffer.substring(at + 1);
      return after.isNotEmpty && _promptDetector.matches(after);
    }
    // 到这一刻还没见过换行 ⇒ 设备不回显。只在 echoGrace 过了之后才认，
    // 以免把被延迟投递的建连横幅当成提权结果。
    return _graceElapsed && _promptDetector.matches(_buffer);
  }

  bool _passwordPromptSeen() {
    final line = PromptDetector.lastNonEmptyLine(_buffer);
    return line != null && passwordPromptPattern.hasMatch(line);
  }

  void _onAttemptTimeout() {
    if (_finished) return;
    if (_attemptsLeft > 1) {
      _attemptsLeft--;
      _writeAndWait(command, _Phase.awaitingEnable);
      return;
    }
    _fail(_timeoutFailure());
  }

  void _succeed() {
    _cancelTimers();
    _phase = _Phase.idle;
    if (!_finished) _done!.complete(null);
  }

  void _fail(ConnectionFailure failure) {
    _cancelTimers();
    _phase = _Phase.idle;
    if (!_finished) _done!.complete(failure);
  }

  void _cancelTimers() {
    _attemptTimer?.cancel();
    _settleTimer?.cancel();
    _graceTimer?.cancel();
  }

  static ConnectionFailure _missingPasswordFailure() => const ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '提权口令缺失：设备要求输入提权口令，但该设备没有配置。'
        '请在设备编辑对话框里填写「提权口令」。',
      );

  static ConnectionFailure _rejectedPasswordFailure() => const ConnectionFailure(
        ConnectionFailureKind.authFailed,
        '提权口令被拒：设备连续两次要求重新输入口令。'
        '请检查设备编辑对话框里的「提权口令」。',
      );

  static ConnectionFailure _timeoutFailure() => const ConnectionFailure(
        ConnectionFailureKind.timeout,
        '提权超时：设备没有在超时时间内进入特权模式。'
        '请检查「提权命令」是否是该设备的正确写法。',
      );
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/connection/enable_sequence_test.dart`
Expected: PASS（6 条）。

> **若"设备没反应"那条红了**：检查 `start()` 里 `_settleTimer` 用的是不是 `() => _writeAndWait(...)`。写成 `_writeAndWait(command, _Phase.awaitingEnable)` 直接当回调传会**立即执行**，于是 `en` 在 `start()` 的同一个 tick 就被发出去，`written` 的断言全错位。

- [ ] **Step 5: 提交**

```bash
git add lib/connection/enable_sequence.dart test/connection/enable_sequence_test.dart
git commit -m "feat(conn): 提权序列状态机（en → 口令 → 特权提示符）"
```

---

## Task 4: 接进 `ConnectionManager`（`SessionReady` 之前）

**Files:**
- Modify: `lib/connection/connection_manager.dart`（`_attemptConnect` 内，约 299-341 行；`_teardownSession` 内，约 449-453 行）
- Test: `test/connection/connection_manager_test.dart`、`test/state/session_controller_test.dart`

- [ ] **Step 1: 写失败的测试**

追加到 `test/connection/connection_manager_test.dart`。

先在 `_profile`（该文件 154 行）**之后**加一个**新**夹具 —— 不动 `_profile` 本身，它的 `postLogin: ['enable']` 被 26 条现有用例依赖着，改它风险不必要：

```dart
/// 一台**要提权**的设备。
///
/// 与 [_profile] 分开写而不是给它加参数：`_profile` 的
/// `postLogin: ['enable']` 被 20 多条现有用例依赖，默认值一个字都不能动。
///
/// `postLogin` 用 `['show version']` 而不是 `['enable']`：`enable` 这个词
/// 同时出现在提权命令与登录后命令上，断言 `written` 时分不清哪一笔是谁发的。
DeviceProfile _enableProfile({
  List<String> postLogin = const ['show version'],
  String? enablePassword = 'pw',
}) => DeviceProfile(
  id: 'd1',
  name: '核心交换机',
  protocol: DeviceProtocol.ssh,
  host: '10.0.0.1',
  port: 22,
  username: 'admin',
  enableCommand: 'en',
  enablePassword: enablePassword,
  postLoginCommands: postLogin,
);
```

然后在 `main()` 里追加（收尾一律 `mgr.dispose(); async.flushMicrotasks();`，与本文件其余 `fakeAsync` 用例一致）：

```dart
  test('提权成功之前不发 SessionReady，也不下发登录后命令', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _enableProfile(),
        factory: _FakeFactory(sessions),
      );
      final events = <ConnectionEvent>[];
      mgr.events.listen(events.add);

      mgr.connect();
      async.flushMicrotasks();
      final session = sessions.single;

      // 建连横幅先到 —— 它也以 `>` 结尾，绝不能被当成提权成功。
      session.emit('Ruijie>');
      async.elapse(const Duration(milliseconds: 400));
      expect(
        events.whereType<SessionReady>(),
        isEmpty,
        reason: '设备还停在登录提示符上，会话不该就绪',
      );
      expect(session.written, ['en\n'], reason: 'settleDelay 到点后才发提权命令');

      session.emit('en\r\r\n');
      session.emit('\r\r\nPassword:');
      async.flushMicrotasks();
      expect(session.written, ['en\n', 'pw\n']);

      // 真机实录里这两段是分开到达的（`\r\r\n` 然后 `Ruijie#`）。
      session.emit('\r\r\n');
      session.emit('Ruijie#');
      async.flushMicrotasks();
      expect(events.whereType<SessionReady>(), hasLength(1));
      expect(mgr.state, DeviceConnectionState.connected);

      // FR-C-08：登录后命令在 `SessionReady` **之后**才入队。
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(session.written, ['en\n', 'pw\n', 'show version\n']);

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('提权失败：报 ConnectionFailed、不进已连接、不下发登录后命令', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _enableProfile(),
        factory: _FakeFactory(sessions),
      );
      final events = <ConnectionEvent>[];
      mgr.events.listen(events.add);

      mgr.connect();
      async.flushMicrotasks();
      final session = sessions.single;
      async.elapse(const Duration(milliseconds: 400));
      expect(session.written, ['en\n']);

      // 口令被拒两轮：每轮"设备要口令 → 我们发 → 又被要"。
      // **每次喂"要口令"，状态机就同步发出下一笔**（发口令或重发 `en`），
      // 所以这里只喂"要口令"，不必再喂 `en` 的回显。
      session.emit('\r\r\nPassword:'); // 第 1 轮：发口令
      async.flushMicrotasks();
      session.emit('\r\r\nPassword:'); // 又被要 → 重发 en
      async.flushMicrotasks();
      session.emit('\r\r\nPassword:'); // 第 2 轮：发口令
      async.flushMicrotasks();
      session.emit('\r\r\nPassword:'); // 又被要 → 两次用完，报错
      async.flushMicrotasks();

      expect(session.written, ['en\n', 'pw\n', 'en\n', 'pw\n']);

      final failures = events.whereType<ConnectionFailed>().toList();
      expect(failures, hasLength(1));
      expect(
        failures.single.failure.kind,
        ConnectionFailureKind.authFailed,
        reason: '口令错 → authFailed（不新增枚举值）',
      );
      expect(events.whereType<SessionReady>(), isEmpty);
      expect(
        session.written,
        isNot(contains('show version\n')),
        reason: '没进特权模式就下发命令，命令会被设备当口令吃掉',
      );
      expect(mgr.state, DeviceConnectionState.failed);

      mgr.dispose();
      async.flushMicrotasks();
    });
  });

  test('提权口令被拒时不再自动重连（每次重连都会再喂一遍错口令）', () {
    fakeAsync((async) {
      final sessions = <_FakeSession>[];
      final mgr = ConnectionManager(
        profile: _enableProfile(),
        factory: _FakeFactory(sessions),
      );

      mgr.connect();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 400));

      // 一路喂到两轮用完（4 次"要口令"）。第二轮里重发 `en` 是**同步**发生的
      // （`_check` 在 `_passwordPromptSeen` 那一支里直接 `_writeAndWait`），
      // 所以这里只需要喂"要口令"，不用再喂 `en` 的回显。
      for (var i = 0; i < 4; i++) {
        sessions.single.emit('\r\r\nPassword:');
        async.flushMicrotasks();
      }

      // FR-C-07 的退避是 1s 起。等够 5s，确认**没有**再建会话。
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(
        sessions,
        hasLength(1),
        reason: '口令被拒是确定性失败，重连只会把账号锁掉',
      );
      expect(mgr.state, DeviceConnectionState.failed);

      mgr.dispose();
      async.flushMicrotasks();
    });
  });
```

> **`written` 那条断言只取最终值，不依赖中间时序** —— 所以它对着的是"发了两轮
> `en` + 两轮口令"这件事本身。真跑红了就是实现少发或多发了，**去改实现，
> 别去改这条断言**。

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/connection/connection_manager_test.dart`
Expected: 编译失败 —— `enableCommand` 无此参数（若 Task 1 未做）或断言失败（`SessionReady` 在提权前就发了）。

- [ ] **Step 3: 加字段**

在 `ConnectionManager` 的字段区（`StreamSubscription<String>? _outputSub;` 附近，`lib/connection/connection_manager.dart:156`）加：

```dart
  /// 本次连接正在跑的提权序列。null 表示这台设备不提权，或提权已经结束。
  ///
  /// 生命周期与 `_session` / `_outputSub` / `_dispatcher` **同进同退** ——
  /// 拆除时一并置空（见 [_teardownSession]），否则下一次连接会把输出喂给一个
  /// 属于上一条会话的状态机。
  EnableSequence? _enable;
```

文件顶部 import 加 `import 'enable_sequence.dart';`。

- [ ] **Step 4: 建序列并喂输出**

把 `lib/connection/connection_manager.dart:303-313` 那一段（`_outputSub = ...` 到 `CommandDispatcher(...)` 结束）整体替换为：

```dart
    // 提权与命令派发**共用同一个提示符检测器**：两者的判据必须是同一套
    // （用户可能给这台设备自定义过 `promptRegex`），各建一个实例迟早会漂移。
    final detector = promptDetector ?? PromptDetector();
    final enableCommand = profile.enableCommand;
    final enable = enableCommand == null
        ? null
        : EnableSequence(
            write: session.write,
            promptDetector: detector,
            command: enableCommand,
            password: profile.enablePassword,
            lineEnding: profile.lineEnding,
          );
    // **先建好再订阅。** 反过来的话，订阅建立到赋值之间到达的输出会被丢掉
    // （`session.output` 是广播流，没有订阅者就扔）—— 而那段正是 `en` 的回显。
    _enable = enable;

    // `onError` 是保险，不是通道：两个真实实现都把 output 上的错误转成了 `done`
    // 的**完成**（`_onError` → `_onDisconnected`），output 本身不会以错误结束。
    // 真要有错误漏到这里，它是**静默**吞掉的 —— 没有事件、没有日志、没有状态
    // 变化，所以别指望它能报信。
    _outputSub = session.output.listen((chunk) {
      if (!_output.isClosed) _output.add(chunk);
      _dispatcher?.onOutput(chunk);
      _enable?.onOutput(chunk);
    }, onError: (Object _) {});

    _dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: detector,
      morePager: morePager ?? MorePager(),
      lineEnding: profile.lineEnding,
    );
```

- [ ] **Step 5: 在 `SessionReady` 之前跑提权**

在 `session.done.then((_) => _onSessionDone(gen, session.lastError));`（原 320 行）**之后**、`final wasReconnect = _attempt > 0;`（原 322 行）**之前**插入：

```dart
    // FR-C-08 的前置一步：提权必须在 `SessionReady` **之前**跑完。
    // 见 `EnableSequence` 的类文档：这期间设备停在口令提示符上，
    // dispatcher 一旦开始发用户命令，命令就会被当成口令喂进去。
    if (enable != null) {
      final failure = await enable.start();
      // **靠身份判断这次提权还算不算数。** 这期间用户可能断开了、退出了、
      // 又连了一次，`_teardownSession` 会把 `_enable` 置空（并 dispose 掉这个
      // 序列，它以 null 完成 future —— 那个 null 不是"成功"）。
      if (!identical(_enable, enable)) return;
      _enable = null;

      if (failure != null) {
        if (_disposed || _userClosed || gen != _generation) return;
        unawaited(_teardownSession());
        if (!_events.isClosed) _events.add(ConnectionFailed(failure));
        // **口令被拒是确定性失败，不排程重连。** FR-C-07 会一直重试下去
        // （退避到 30s 封顶后无限期），而每次重连都会把同一条错误口令再喂给
        // 设备一遍 —— 很多设备会因此锁定账号。提权超时不在此列：那多半是
        // 设备慢或命令写法不对，重试是合理的。
        if (failure.kind == ConnectionFailureKind.authFailed) {
          _setState(DeviceConnectionState.failed);
        } else {
          _scheduleRetry(gen);
        }
        return;
      }
    }
```

- [ ] **Step 6: 拆除时一并清掉**

在 `_teardownSession` 里（`_outputSub = null;` / `_dispatcher = null;` 那两行，原 452-453 行）改成：

```dart
    _outputSub = null;
    _dispatcher = null;
    // 提权序列与它们同进同退：留着的话，下一次连接的输出会被喂给一个属于
    // 上一条会话的状态机。dispose 会以 null 完成它的 future —— 调用方靠
    // `identical(_enable, enable)` 认出"这次提权已经作废"，不看那个返回值。
    _enable?.dispose();
    _enable = null;
```

- [ ] **Step 7: 跑测试确认通过**

Run: `flutter test test/connection/connection_manager_test.dart test/state/session_controller_test.dart`
Expected: PASS。原有用例必须全绿 —— 提权是**追加**的一条路径，`enableCommand == null` 的设备行为逐字不变。

- [ ] **Step 8: 提交**

```bash
git add lib/connection/connection_manager.dart test/connection/connection_manager_test.dart
git commit -m "feat(conn): 登录后先提权，成功才进已连接并发登录后命令"
```

---

## Task 5: 设备编辑对话框两个输入框

**Files:**
- Modify: `lib/ui/dialogs/device_edit_dialog.dart`
- Test: `test/ui/device_edit_dialog_test.dart`、`test/ui/device_params_change_test.dart`

- [ ] **Step 1: 写失败的测试**

追加到 `test/ui/device_edit_dialog_test.dart`：

```dart
  testWidgets('提权命令与提权口令能存进设备（FR-D-01）', (tester) async {
    await pumpDialog(tester); // 用本文件现成的打开对话框的辅助
    await tester.enterText(find.byKey(const ValueKey('device-name')), '汇聚');
    await tester.enterText(find.byKey(const ValueKey('device-host')), '10.0.0.1');
    await tester.enterText(
      find.byKey(const ValueKey('device-username')),
      'admin',
    );
    await tester.enterText(
      find.byKey(const ValueKey('device-enable-command')),
      'en',
    );
    await tester.enterText(
      find.byKey(const ValueKey('device-enable-password')),
      'enable-secret',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = container.read(devicesProvider).single;
    expect(saved.enableCommand, 'en');
    expect(saved.enablePassword, 'enable-secret');
  });

  testWidgets('提权命令留空 → null（表示不提权，而不是空串）', (tester) async {
    await pumpDialog(tester);
    await tester.enterText(find.byKey(const ValueKey('device-name')), '接入');
    await tester.enterText(find.byKey(const ValueKey('device-host')), '10.0.0.2');
    await tester.enterText(
      find.byKey(const ValueKey('device-username')),
      'admin',
    );
    await tester.enterText(
      find.byKey(const ValueKey('device-enable-command')),
      '   ',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      container.read(devicesProvider).single.enableCommand,
      isNull,
      reason: '空串会真的往设备发一个空行；null 才是"不提权"',
    );
  });
```

追加到 `test/ui/device_params_change_test.dart`（该文件测的是"改连接参数就断线"）：

```dart
  testWidgets('改提权设置算连接参数变更 → 断开（决策①）', (tester) async {
    // 提权参数不在 `_displayOnlyFields` 里，所以它自动算连接参数。
    // 这条用例把这个"自动"钉住：哪天有人往白名单里加了 enableCommand，
    // 改提权设置就会静默地不断线，而界面上设备行看起来已经改好了。
    await pumpExistingDevice(tester); // 用本文件现成的辅助
    await tester.enterText(
      find.byKey(const ValueKey('device-enable-command')),
      'en',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('连接参数已改变，已断开该设备，请重新连接'), findsOneWidget);
  });
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/ui/device_edit_dialog_test.dart test/ui/device_params_change_test.dart`
Expected: FAIL —— `find.byKey(const ValueKey('device-enable-command'))` 找不到。

- [ ] **Step 3: 加控制器**

`_DeviceEditDialogState` 里，`late final TextEditingController _postLogin;` 之后加：

```dart
  late final TextEditingController _enableCommand;
  late final TextEditingController _enablePassword;
```

`initState` 里，`_postLogin = TextEditingController(...)` 那一段之后加：

```dart
    _enableCommand = TextEditingController(
      text: existing?.enableCommand ?? '',
    );
    _enablePassword = TextEditingController(
      text: existing?.enablePassword ?? '',
    );
```

`dispose` 的循环列表里，`_postLogin,` 之后加：

```dart
      _enableCommand,
      _enablePassword,
```

- [ ] **Step 4: 加两个输入框**

在 `build` 里，`device-key-path` 那个 `TextField` 之后（`device-line-ending` 下拉之前）插入：

```dart
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-enable-command'),
                controller: _enableCommand,
                decoration: const InputDecoration(
                  labelText: '提权命令（可选，如 en；留空表示不提权）',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-enable-password'),
                controller: _enablePassword,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '提权口令（明文保存，设备不问口令就留空）',
                ),
              ),
```

- [ ] **Step 5: 存进 draft**

`_submit()` 里，`DeviceProfile(...)` 的 `privateKeyPath:` 那两行之后加：

```dart
      // 同样是**空串要变成 null**：null 是"不提权"或"设备不问口令"，
      // 而空串会真的往设备发一个空行。见 `_emptyToNull` 与 `_unset`。
      enableCommand: _emptyToNull(_enableCommand.text),
      enablePassword: _emptyToNull(_enablePassword.text),
```

- [ ] **Step 6: 跑测试确认通过**

Run: `flutter test test/ui/device_edit_dialog_test.dart test/ui/device_params_change_test.dart`
Expected: PASS。

- [ ] **Step 7: 提交**

```bash
git add lib/ui/dialogs/device_edit_dialog.dart test/ui/device_edit_dialog_test.dart test/ui/device_params_change_test.dart
git commit -m "feat(ui): 设备编辑对话框增加提权命令与提权口令"
```

---

## Task 6: `DevicesNotifier.add` 补字段

**为什么会有这一条：** `add` 是**逐字段重建** `DeviceProfile`（它刻意不用 `copyWith`，因为 `copyWith` 不接受 `id`）。漏一个字段的后果是**新增的设备静默丢掉那个设置**，而后面每条路径都看起来是对的 —— 用户填了提权口令，保存后设备连不上，回来看对话框里那栏是空的。

**Files:**
- Modify: `lib/state/providers.dart:132-151`
- Test: `test/state/providers_test.dart`

- [ ] **Step 1: 写失败的测试**

追加到 `test/state/providers_test.dart`：

```dart
  test('新增设备时提权字段不能丢（add 是逐字段重建的）', () async {
    final container = await makeContainer(); // 用本文件现成的装配辅助
    final draft = DeviceProfile(
      id: 'draft-id',
      name: '汇聚',
      protocol: DeviceProtocol.ssh,
      host: '10.0.0.1',
      port: 22,
      username: 'admin',
      enableCommand: 'en',
      enablePassword: 'enable-secret',
    );

    final created = await container.read(devicesProvider.notifier).add(draft);

    expect(created.id, isNot('draft-id'), reason: 'id 由本层生成');
    expect(created.enableCommand, 'en');
    expect(created.enablePassword, 'enable-secret');
  });
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/state/providers_test.dart`
Expected: FAIL —— `created.enableCommand` 是 null。

- [ ] **Step 3: 补上两个字段**

`lib/state/providers.dart` 的 `add` 里，`privateKeyPath: draft.privateKeyPath,` 之后加：

```dart
      enableCommand: draft.enableCommand,
      enablePassword: draft.enablePassword,
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/state/providers_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/state/providers.dart test/state/providers_test.dart
git commit -m "fix(state): 新增设备时补上提权字段（add 逐字段重建）"
```

---

## Task 7: 全量回归 + 真机验收

**Files:** 无代码改动。这一条是验收，不是实现。

- [ ] **Step 1: 全量测试**

Run: `flutter test`
Expected: `All tests passed!`（跳过 3 条 golden）。

> **这套全量跑有已知的偶发红**（20 跑 15 红，总是 `test/ui/` 下的
> `device_list_panel_test.dart` 拖拽删除/排序与 `main_window_test.dart` 切设备草稿，
> 成因是 `test/ui/ui_harness.dart` 的 `settleDisk` 写死 60ms 真实等待）。
> 红了先**单跑那个文件**：绿 ⇒ 偶发，重跑全量即可；红了 ⇒ 真问题，去查。

- [ ] **Step 2: 静态检查**

Run: `dart analyze lib/ test/`
Expected: `No issues found!`（`info` 级也不许有）。

- [ ] **Step 3: 真机验收（锐捷 S6990-128QC2XS-E，10.166.96.41）**

在应用里编辑那台设备，填：

| 字段 | 值 |
|---|---|
| 协议 | ssh |
| 主机地址 | 10.166.96.41 |
| 端口 | 22 |
| 用户名 | admin |
| 密码 | 〈该设备的登录口令，不写进本文件〉 |
| 提权命令 | `en` |
| 提权口令 | 〈该设备的提权口令，不写进本文件〉 |

> **口令不进仓库。** 这台设备的口令在 2026-09-26 的排查里由用户口头提供，
> 只存在于那次会话里；本文件与任何提交都**不得**带上它。验收时人工填。

然后连接，逐条确认：

1. 首次连接弹出主机密钥确认，指纹是
   `SHA256:f/p+2TgLwGF72TRyfoH9DEtJ8fB0Lo9eSbavnFNJHfk`（FR-C-11）；
2. 设备按钮变绿；
3. 输出区**没有**「执行超时」告警 —— 这一条正是与"把口令塞进
   `postLoginCommands`"那个错误做法的分水岭；
4. 发一条 `show clock`，**不再**回
   `% User doesn't have sufficient privilege`（提权前实测就是这句）；
5. 命令回显里能看到 `Ruijie#`。

- [ ] **Step 4: 真机验收 · 反例**

把提权口令**改成错的**（如 `wrong`），重连，确认：

1. 输出区出现一行黄色「连接失败：提权口令被拒：设备连续两次要求重新输入口令。…」
   （FR-C-06 的可读原因）；
2. 设备按钮是**红色**，而且**不再无限重试**（口令被拒是确定性失败）；
3. 设备上的账号**没有**被反复喂错口令 —— 这正是 Task 4 那条"口令被拒不排程
   重连"要防的事。

验收完把口令改回正确的那个。

- [ ] **Step 5: 记录验收结果**

把上面两次真机验收的实况（时序、看到的原文）写进
`docs/superpowers/plans/2026-09-26-privilege-escalation.md` 末尾的
「验收记录」一节，并提交：

```bash
git add docs/superpowers/plans/2026-09-26-privilege-escalation.md
git commit -m "docs(plans): 提权功能真机验收记录"
```

---

## 验收记录

（Task 7 执行后在此填写。）

---

## 附：本计划有意不做的

- **通用「提示符 → 应答」表格。** 用户已在 2026-09-26 明确选了"设备级提权设置"，
  不是通用应答表。多厂商的其它登录后交互（如强制改密）不在本期。
- **提权口令与登录口令的联动**（"与登录口令相同"勾选框）。用户明确选了"单独字段"。
- **`requirements.md` 的同步修订。** §10.1 的「旧 SSH 算法的兼容开关」与 §13 风险表
  那两处仍写着"V1 明确不做兼容开关"，已被提交 `f283de0`（算法集末尾补回 `ssh-rsa`）
  推翻。**这不在本计划的授权范围内**，单独提请用户决定。
- **`ReconnectScheduled` 的文案。** 首次连接从未成功时它也说「连接**断开**，N 秒后重连」，
  "断开"在那种场合是错的。已知，未授权修改。
