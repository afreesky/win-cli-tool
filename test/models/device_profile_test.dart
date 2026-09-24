import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/models/device_profile.dart';

void main() {
  group('DeviceProtocol', () {
    test('默认端口：ssh 为 22，telnet 为 23', () {
      expect(DeviceProtocol.ssh.defaultPort, 22);
      expect(DeviceProtocol.telnet.defaultPort, 23);
    });

    test('未知协议名抛出 FormatException', () {
      expect(() => DeviceProtocol.fromName('ftp'), throwsFormatException);
    });
  });

  group('DeviceProfile', () {
    test('未指定的字段使用规范默认值', () {
      const p = DeviceProfile(
        id: 'd1',
        name: '核心交换机',
        protocol: DeviceProtocol.telnet,
        host: '10.0.0.1',
        port: 23,
        username: 'admin',
      );

      expect(p.lineEnding, '\n');
      expect(p.promptRegex, isNull);
      expect(p.jumpHostIds, isEmpty);
      expect(p.postLoginCommands, isEmpty);
      expect(p.autoConnect, isFalse);
      expect(p.snippets, isEmpty);
      expect(p.password, isNull);
      expect(p.privateKeyPath, isNull);
    });

    test('JSON 往返后所有字段保持一致', () {
      const original = DeviceProfile(
        id: 'd1',
        name: '核心交换机',
        protocol: DeviceProtocol.ssh,
        host: '10.1.1.1',
        port: 22,
        username: 'admin',
        password: 'secret',
        privateKeyPath: '/home/u/.ssh/id_rsa',
        jumpHostIds: ['j1', 'j2'],
        lineEnding: '\r\n',
        promptRegex: r'[>#]\s*$',
        postLoginCommands: ['enable', 'terminal length 0'],
        autoConnect: true,
        snippets: [
          Snippet(id: 's1', name: '保存配置', content: 'save\nY'),
        ],
      );

      final restored = DeviceProfile.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.protocol, DeviceProtocol.ssh);
      expect(restored.host, original.host);
      expect(restored.port, original.port);
      expect(restored.username, original.username);
      expect(restored.password, original.password);
      expect(restored.privateKeyPath, original.privateKeyPath);
      expect(restored.jumpHostIds, ['j1', 'j2']);
      expect(restored.lineEnding, '\r\n');
      expect(restored.promptRegex, r'[>#]\s*$');
      expect(restored.postLoginCommands, ['enable', 'terminal length 0']);
      expect(restored.autoConnect, isTrue);
      expect(restored.snippets, hasLength(1));
      expect(restored.snippets.first.name, '保存配置');
      expect(restored.snippets.first.content, 'save\nY');
    });

    test('copyWith 只改指定字段', () {
      const p = DeviceProfile(
        id: 'd1',
        name: 'A',
        protocol: DeviceProtocol.telnet,
        host: '10.0.0.1',
        port: 23,
        username: 'admin',
      );

      final q = p.copyWith(name: 'B', port: 2323);

      expect(q.name, 'B');
      expect(q.port, 2323);
      expect(q.host, '10.0.0.1');
      expect(q.id, 'd1');
    });

    test('copyWith 不传参时保留原值（原值为 null 也保留）', () {
      const p = DeviceProfile(
        id: 'd1',
        name: 'A',
        protocol: DeviceProtocol.ssh,
        host: '10.0.0.1',
        port: 22,
        username: 'admin',
        password: 'pw',
        promptRegex: r'[>#]\s*$',
      );

      final q = p.copyWith(name: 'B');

      expect(q.password, 'pw');
      expect(q.promptRegex, r'[>#]\s*$');
    });

    test('copyWith 能把可空字段显式清回 null', () {
      const p = DeviceProfile(
        id: 'd1',
        name: 'A',
        protocol: DeviceProtocol.ssh,
        host: '10.0.0.1',
        port: 22,
        username: 'admin',
        password: 'pw',
        privateKeyPath: '/home/u/.ssh/id_rsa',
        promptRegex: r'[>#]\s*$',
      );

      final q = p.copyWith(
        password: null,
        privateKeyPath: null,
        promptRegex: null,
      );

      expect(q.password, isNull);
      expect(q.privateKeyPath, isNull);
      expect(q.promptRegex, isNull);
      // 未指定的字段不受影响
      expect(q.name, 'A');
      expect(q.host, '10.0.0.1');
      expect(q.port, 22);
      expect(q.id, 'd1');
    });

    test('copyWith 能把可空字段从 null 设为新值', () {
      // 哨兵机制有三个分支：保留、清空、设新值。前两个由上面两个用例覆盖，
      // 这个覆盖第三个 —— 若只在保留/清空上正确而设新值有 bug，用户改的密码
      // 会被静默丢弃，且因为每次保存都丢掉，用户再编辑也救不回来。
      const p = DeviceProfile(
        id: 'd1',
        name: 'A',
        protocol: DeviceProtocol.ssh,
        host: '10.0.0.1',
        port: 22,
        username: 'admin',
      );

      final q = p.copyWith(password: 'new-pw', promptRegex: r'>>>\s*$');

      expect(q.password, 'new-pw');
      expect(q.promptRegex, r'>>>\s*$');
    });

    test('JSON 只有必填字段时，可选项回落到默认值（v1 配置迁移形状）', () {
      final restored = DeviceProfile.fromJson(const <String, Object?>{
        'id': 'd1',
        'name': '核心交换机',
        'protocol': 'telnet',
        'host': '10.0.0.1',
        'port': 23,
        'username': 'admin',
      });

      expect(restored.password, isNull);
      expect(restored.privateKeyPath, isNull);
      expect(restored.jumpHostIds, isEmpty);
      expect(restored.lineEnding, '\n');
      expect(restored.promptRegex, isNull);
      expect(restored.postLoginCommands, isEmpty);
      expect(restored.autoConnect, isFalse);
      expect(restored.snippets, isEmpty);
    });
  });

  group('JumpHost', () {
    test('JSON 往返', () {
      const j = JumpHost(
        id: 'j1',
        name: '堡垒机-A',
        host: '10.0.0.254',
        port: 22,
        username: 'ops',
        password: 'pw',
        privateKeyPath: '/home/ops/.ssh/id_ed25519',
      );

      final restored = JumpHost.fromJson(j.toJson());

      expect(restored.id, 'j1');
      expect(restored.name, '堡垒机-A');
      expect(restored.host, '10.0.0.254');
      expect(restored.port, 22);
      expect(restored.username, 'ops');
      expect(restored.password, 'pw');
      expect(restored.privateKeyPath, '/home/ops/.ssh/id_ed25519');
    });

    test('copyWith 保留与清空可空字段', () {
      const j = JumpHost(
        id: 'j1',
        name: '堡垒机-A',
        host: '10.0.0.254',
        port: 22,
        username: 'ops',
        password: 'pw',
        privateKeyPath: '/home/ops/.ssh/id_ed25519',
      );

      // 不传 → 保留
      final kept = j.copyWith(username: 'ops2');
      expect(kept.password, 'pw');
      expect(kept.privateKeyPath, '/home/ops/.ssh/id_ed25519');
      expect(kept.username, 'ops2');

      // 显式传 null → 清空
      final cleared = j.copyWith(password: null, privateKeyPath: null);
      expect(cleared.password, isNull);
      expect(cleared.privateKeyPath, isNull);
      expect(cleared.username, 'ops');

      // 设新值
      final updated = j.copyWith(password: 'new-pw');
      expect(updated.password, 'new-pw');
      expect(updated.privateKeyPath, '/home/ops/.ssh/id_ed25519');
    });
  });

  group('Snippet', () {
    test('JSON 往返后所有字段保持一致（含 id）', () {
      const s = Snippet(id: 's1', name: '保存配置', content: 'save\nY');

      final restored = Snippet.fromJson(s.toJson());

      expect(restored.id, 's1');
      expect(restored.name, '保存配置');
      expect(restored.content, 'save\nY');
    });
  });
}
