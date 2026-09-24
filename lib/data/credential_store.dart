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
