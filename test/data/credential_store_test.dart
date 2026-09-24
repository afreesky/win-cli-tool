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
