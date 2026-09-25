import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/credential_store.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_stores_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  group('AppPaths', () {
    test('四个文件与两个目录都在应用数据目录下', () {
      final paths = AppPaths(root);
      expect(paths.devicesFile.path, '${root.path}/devices.json');
      expect(paths.settingsFile.path, '${root.path}/settings.json');
      expect(paths.knownHostsFile.path, '${root.path}/known_hosts.json');
      expect(paths.draftsDir.path, '${root.path}/drafts');
      expect(paths.logsDir.path, '${root.path}/logs');
    });

    test('只拼路径，不碰文件系统（构造它不该建出任何目录）', () {
      final paths = AppPaths(Directory('${root.path}/不存在'));
      expect(paths.devicesFile, isNotNull);
      expect(Directory('${root.path}/不存在').existsSync(), isFalse);
    });
  });

  group('AppStores', () {
    test('同一个 store 每次拿到的是同一个实例', () {
      final stores = AppStores(paths: AppPaths(root));
      expect(identical(stores.devices, stores.devices), isTrue);
      expect(identical(stores.hostKeys, stores.hostKeys), isTrue);
      expect(identical(stores.drafts, stores.drafts), isTrue);
      expect(identical(stores.settings, stores.settings), isTrue);
    });

    test('四个 store 指的是四个不同的文件/目录', () {
      final stores = AppStores(paths: AppPaths(root));
      expect(stores.devices.file.path, isNot(stores.settings.file.path));
      expect(stores.devices.file.path, isNot(stores.hostKeys.file.path));
      expect(stores.drafts.dir.path, isNot(stores.settings.file.path));
    });

    test('默认用明文凭据实现（NFR-S-01 的接缝，V1 已接受）', () async {
      final stores = AppStores(paths: AppPaths(root));
      await stores.devices.save([
        const DeviceProfile(
          id: 'd1',
          name: '核心交换机',
          protocol: DeviceProtocol.ssh,
          host: '10.0.0.1',
          port: 22,
          username: 'admin',
          password: 'hunter2',
        ),
      ]);
      final raw = await stores.devices.file.readAsString();
      expect(raw, contains('hunter2'));
    });

    test('可以换成别的凭据实现（那正是这个接口存在的理由）', () async {
      final stores = AppStores(paths: AppPaths(root), credentials: _Vault());
      await stores.devices.save([
        const DeviceProfile(
          id: 'd1',
          name: '核心交换机',
          protocol: DeviceProtocol.ssh,
          host: '10.0.0.1',
          port: 22,
          username: 'admin',
          password: 'hunter2',
        ),
      ]);
      final raw = await stores.devices.file.readAsString();
      expect(raw, isNot(contains('hunter2')));
    });
  });
}

class _Vault implements CredentialStore {
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
