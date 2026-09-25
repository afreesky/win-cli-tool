import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/providers.dart';

import '../fixtures/fake_session.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_assembly_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 与 `main()` 同一条路：真 store、真读盘、真覆盖，只有会话层是夹具。
  Future<(ProviderContainer, FakeSessionFactory)> boot() async {
    final paths = AppPaths(root);
    final stores = AppStores(paths: paths);
    final deviceResult = await stores.devices.load();
    final settingsResult = await stores.settings.load();
    final factory = FakeSessionFactory();

    final container = ProviderContainer.test(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        logsDirPath.overrideWithValue(paths.logsDir.path),
        startupProvider.overrideWithValue(
          AppStartup(
            settings: settingsResult.settings,
            devices: deviceResult.devices,
            settingsIssues: settingsResult.issues,
            deviceIssues: deviceResult.issues,
          ),
        ),
        sessionFactoryProvider.overrideWithValue(factory),
      ],
    );
    return (container, factory);
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  String textOf(ProviderContainer c, String id) => c
      .read(outputBufferProvider(id))
      .lines
      .map((line) => line.map((s) => s.text).join())
      .join('\n');

  test('从空目录启动到两台设备各自跑起来', () async {
    final (container, factory) = await boot();
    addTearDown(container.dispose);

    // 1. 空目录启动：没有设备，也没有问题要报。
    expect(container.read(devicesProvider), isEmpty);
    expect(container.read(issuesProvider), isEmpty);

    // 2. 加两台设备（id 由状态层生成）。
    final devices = container.read(devicesProvider.notifier);
    final a = await devices.add(fakeProfile(id: '', name: 'A'));
    final b = await devices.add(fakeProfile(id: '', name: 'B'));
    expect(a.id, isNot(b.id));

    // 3. 落盘了：重新读一遍文件。
    final reloaded = await container.read(appStoresProvider).devices.load();
    expect(reloaded.devices.map((d) => d.name), ['A', 'B']);

    // 4. 两台各自连接。
    await container.read(sessionProvider(a.id).notifier).connect();
    await container.read(sessionProvider(b.id).notifier).connect();
    expect(factory.sessions, hasLength(2));

    // 5. 各吐各的输出。
    factory.sessions[0].emit('A 的输出\n');
    factory.sessions[1].emit('B 的输出\n');
    await settle();

    expect(textOf(container, a.id), contains('A 的输出'));
    expect(textOf(container, a.id), isNot(contains('B 的输出')));
    expect(textOf(container, b.id), contains('B 的输出'));
    expect(textOf(container, b.id), isNot(contains('A 的输出')));

    // 6. 输出也进了日志，而且是剥干净的。
    //
    // **读盘之前必须先逼一次落盘，否则这一条是空转。** `LogWriter` 攒够
    // `flushEveryLines`（32）行才写，而这上面每台只吐了一行；一行永远等不到
    // 阈值，日期目录那时也还不存在（它是在第一次真正写盘时才建的），于是
    // `_readAllLogs` 读回的是空串 —— 两条 `contains` 在"日志里什么都没有"时
    // 照样绿。`end()` 是**唯一**的强制落盘点，而 `disconnect()` 会 `await`
    // 到它；`dispose()` 不行，它的 `_endLogSync()` 是 `unawaited(log.end())`。
    await container.read(sessionProvider(a.id).notifier).disconnect();
    await container.read(sessionProvider(b.id).notifier).disconnect();

    final logs = await _readAllLogs(Directory(container.read(logsDirPath)));
    expect(logs, contains('A 的输出'));
    expect(logs, contains('B 的输出'));
  });

  test('A 断线重连期间切到 B：A 的队列与输出都不受影响（FR-O-09 / §5.5）', () async {
    final (container, factory) = await boot();
    addTearDown(container.dispose);

    final devices = container.read(devicesProvider.notifier);
    final a = await devices.add(fakeProfile(id: '', name: 'A'));
    final b = await devices.add(fakeProfile(id: '', name: 'B'));

    await container.read(sessionProvider(a.id).notifier).connect();
    await container.read(sessionProvider(b.id).notifier).connect();

    // A 上排一条命令，然后断线 —— 未发出的全部丢弃（FR-C-10）。
    // `sessionProvider(id)` 读出来的**就是** `SessionStatus`（那是它的 `state`
    // 类型），所以丢弃数直接读它，不要写成 `.notifier.status`（`SessionNotifier`
    // 上没有 `status` 这个成员）。
    container.read(sessionProvider(a.id).notifier).enqueue(['show version']);
    await settle();
    factory.sessions[0].drop();
    await settle();

    // 界面此刻切到 B（读 B 的 provider 就是"切过去"）。
    expect(container.read(sessionProvider(b.id)).state.name, 'connected');

    // A 的丢弃告警落在 A 自己的缓冲里，B 的一点没沾。
    expect(textOf(container, a.id), contains('丢弃'));
    expect(textOf(container, b.id), isNot(contains('丢弃')));
    expect(container.read(sessionProvider(a.id)).droppedCommands,
        greaterThan(0));

    // A 退避 1s 后自己连回来，全程不需要界面参与。
    await Future<void>.delayed(const Duration(seconds: 2));
    await settle();
    expect(factory.sessions, hasLength(3), reason: 'A 应当已经重连');
    expect(
      textOf(container, a.id),
      contains('重连成功'),
      reason: '重连的横幅写在 A 的缓冲里',
    );
  });

  test('启动时的加载问题会出现在 issuesProvider 里（NFR-R-03）', () async {
    // 手写一个 devices.json：文件坏了。
    await File('${root.path}/devices.json').writeAsString('{oops');

    final (container, _) = await boot();
    addTearDown(container.dispose);

    expect(container.read(devicesProvider), isEmpty, reason: '坏文件按空配置启动');
    expect(
      container.read(issuesProvider).map((i) => i.message).join(),
      contains('留档'),
      reason: 'NFR-R-03：损坏的配置文件要留档并**向用户提示**',
    );
  });

  test('退出（dispose 容器）时所有会话都被关掉，且没向设备发过任何命令（FR-C-12）', () async {
    final (container, factory) = await boot();

    final devices = container.read(devicesProvider.notifier);
    final a = await devices.add(fakeProfile(id: '', name: 'A'));
    await container.read(sessionProvider(a.id).notifier).connect();

    final session = factory.sessions.single;
    session.written.clear();

    // **dispose 之前必须先让 `SessionReady` 投递完，否则这一条是红的。**
    // `_manager.events` 是异步广播流：`connect()` 返回时 `SessionReady` 与
    // `ConnectionStateChanged(connected)` 还排在投递队列里（实测：这里不 settle
    // 的话，下一行读到的是 `connecting`，而不是 `connected`）。
    // `SessionController.dispose()` 的第一句是 `await _dispatchSub?.cancel()` ——
    // 即使 `_dispatchSub` 是 null，那个 `await` 也让出一轮微任务，于是**在途的
    // 那个事件赶在 `_eventsSub.cancel()` 之前**投递到 `onStatus` → `state = status`，
    // 而此刻 notifier 已经被 dispose，抛出 "Cannot use the Ref ... after it has
    // been disposed"。**在 `dispose()` 之后补 await 挡不住它**（实测：补
    // `Duration.zero` 仍然红）—— 事件已经排在那里，补的 await 只是给它让路。
    await settle();

    container.dispose();
    await settle();

    expect(session.closed, isTrue);
    expect(
      session.written,
      isEmpty,
      reason: 'FR-C-12：退出时不向设备发任何命令 —— 包括不清除分页、不发登出序列',
    );
  });
}

Future<String> _readAllLogs(Directory root) async {
  if (!root.existsSync()) return '';
  final parts = <String>[];
  await for (final entity in root.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.log')) {
      parts.add(await entity.readAsString());
    }
  }
  return parts.join('\n');
}
