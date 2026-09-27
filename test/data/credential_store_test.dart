import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/credential_store.dart';

void main() {
  group('PlaintextCredentialStore', () {
    const store = PlaintextCredentialStore();

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
      vault.write(record, const DeviceSecrets(password: 'secret'));
      expect(
        record.containsKey('password'),
        isFalse,
        reason: '密钥库实现把密码放在记录之外 —— 这正是接口存在的意义',
      );
      expect(vault.secretFor('d1'), const DeviceSecrets(password: 'secret'));
      expect(vault.read(record).password, 'secret');
    });
  });

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
}

/// 模拟"凭据不落在记录里"的实现，用来钉住接口形状是**够用**的。
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
