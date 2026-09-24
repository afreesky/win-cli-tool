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
      );

      final restored = JumpHost.fromJson(j.toJson());

      expect(restored.id, 'j1');
      expect(restored.name, '堡垒机-A');
      expect(restored.host, '10.0.0.254');
      expect(restored.port, 22);
      expect(restored.username, 'ops');
      expect(restored.password, 'pw');
      expect(restored.privateKeyPath, isNull);
    });
  });
}
