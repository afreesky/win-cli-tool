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
