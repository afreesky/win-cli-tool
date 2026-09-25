import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// **是 `device_store.dart` 而不是 `load_issue.dart`。** 本文件既要 `LoadIssue` /
// `LoadIssueKind`，又要 `DuplicateDeviceNameError`（它只定义在 device_store.dart
// 里），而 device_store.dart **re-export 了** load_issue.dart（它自己 `:10` 那句
// `export 'load_issue.dart';`）。所以这一条 import 同时给出三样东西；再单独写一行
// `load_issue.dart` 会被分析器判为 `unnecessary_import` —— 而完成标准 1 要求
// `dart analyze lib/ test/` 输出 `No issues found!`。
import 'package:win_cli_tool/data/device_store.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/models/device_profile.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/providers.dart';

import '../fixtures/fake_session.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_providers_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 造一个"启动完成"的容器：与 `main()` 做的事一样（读盘 → 覆盖进去）。
  Future<ProviderContainer> boot({
    AppSettings settings = const AppSettings(),
    List<DeviceProfile> devices = const [],
    List<LoadIssue> deviceIssues = const [],
    FakeSessionFactory? factory,
  }) async {
    final stores = AppStores(paths: AppPaths(root));
    final container = ProviderContainer.test(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        startupProvider.overrideWithValue(
          AppStartup(
            settings: settings,
            devices: devices,
            deviceIssues: deviceIssues,
          ),
        ),
        sessionFactoryProvider.overrideWithValue(factory ?? FakeSessionFactory()),
        // **这一条不能省。** `logsDirPath` 是"必须由 main() 覆盖"的 provider
        // （没有默认值可给：应用数据目录只有 main() 知道），读它会抛
        // `StateError('logsDirPath 必须由 main() 覆盖')`。而
        // `SessionNotifier.build()` 造 controller 时就要用它 ——
        // `Directory(settings.logDir ?? ref.read(logsDirPath))`，而
        // `AppSettings.logDir` 默认是 **null**。不覆盖的话，凡是碰
        // `sessionProvider` 的用例都会在建 controller 时抛 StateError
        // （`_controller` 是 `late final`，抛了之后连 `LateInitializationError`
        // 都只是第二现场）。
        //
        // `main()` 正是这么做的（见 lib/main.dart 的 overrides），这里与它一致。
        logsDirPath.overrideWithValue('${root.path}/logs'),
      ],
    );
    return container;
  }

  test('设备列表来自启动时读到的那一份', () async {
    final container = await boot(devices: [fakeProfile(id: 'd1', name: 'A')]);
    expect(container.read(devicesProvider).single.name, 'A');
  });

  test('加设备：写盘 + 内存都更新，id 由本层生成且是小写十六进制', () async {
    final container = await boot();
    final notifier = container.read(devicesProvider.notifier);

    await notifier.add(
      const DeviceProfile(
        id: '',
        name: '新设备',
        protocol: DeviceProtocol.ssh,
        host: '10.0.0.9',
        port: 22,
        username: 'admin',
      ),
    );

    final added = container.read(devicesProvider).single;
    expect(added.id, isNotEmpty);
    expect(added.id, added.id.toLowerCase(), reason: '必须小写（见 newDeviceId 的文档）');
    expect(
      await container.read(appStoresProvider).devices.file.exists(),
      isTrue,
      reason: '加设备必须落盘',
    );
  });

  test('重名时抛 DuplicateDeviceNameError，内存状态不变（FR-D-04）', () async {
    final container = await boot(devices: [fakeProfile(id: 'd1', name: '同名')]);
    final notifier = container.read(devicesProvider.notifier);

    await expectLater(
      notifier.add(
        const DeviceProfile(
          id: '',
          name: '同名',
          protocol: DeviceProtocol.ssh,
          host: '10.0.0.9',
          port: 22,
          username: 'admin',
        ),
      ),
      throwsA(isA<DuplicateDeviceNameError>()),
    );
    expect(container.read(devicesProvider), hasLength(1));
  });

  test('改设备按 id 替换，不改变顺序', () async {
    final container = await boot(devices: [
      fakeProfile(id: 'a', name: 'A'),
      fakeProfile(id: 'b', name: 'B'),
    ]);
    await container
        .read(devicesProvider.notifier)
        .update(fakeProfile(id: 'a', name: 'A2'));

    expect(
      container.read(devicesProvider).map((d) => d.name),
      ['A2', 'B'],
      reason: '数组顺序就是显示顺序（§13.2）',
    );
  });

  test('拖拽排序靠重写整个数组（FR-D-07）', () async {
    final container = await boot(devices: [
      fakeProfile(id: 'a', name: 'A'),
      fakeProfile(id: 'b', name: 'B'),
      fakeProfile(id: 'c', name: 'C'),
    ]);
    await container
        .read(devicesProvider.notifier)
        .reorder(['c', 'a', 'b']);

    expect(container.read(devicesProvider).map((d) => d.id), ['c', 'a', 'b']);

    // 而且真的落盘了（重新读一遍文件）。
    final reloaded =
        await container.read(appStoresProvider).devices.load();
    expect(reloaded.devices.map((d) => d.id), ['c', 'a', 'b']);
  });

  test('删设备：一并删掉草稿，日志不动（FR-D-06）', () async {
    final container = await boot(devices: [fakeProfile(id: 'd1')]);
    final stores = container.read(appStoresProvider);
    await stores.drafts.write('d1', '写了一半的配置');
    expect(await stores.drafts.read('d1'), '写了一半的配置');

    await container.read(devicesProvider.notifier).remove('d1');

    expect(container.read(devicesProvider), isEmpty);
    expect(await stores.drafts.read('d1'), isEmpty, reason: 'FR-D-06：草稿一并删除');
  });

  test('设置改完存盘，重开容器读得回来（FR-G-02）', () async {
    final container = await boot();
    await container
        .read(settingsProvider.notifier)
        .update(const AppSettings(logEnabled: false, outputBufferLines: 123));

    final reloaded = await container.read(appStoresProvider).settings.load();
    expect(reloaded.settings.logEnabled, isFalse);
    expect(reloaded.settings.outputBufferLines, 123);
  });

  test('启动时发现的问题会被攒起来（LoadIssue 的文档：必须上报）', () async {
    final container = await boot(
      deviceIssues: const [
        LoadIssue(LoadIssueKind.jumpHostIgnored, '设备「A」配置了跳板机，将直接连接。'),
      ],
    );
    expect(container.read(issuesProvider).single.message, contains('跳板机'));
  });

  test('草稿：读得到、写得进，且真的落盘了', () async {
    final container = await boot();
    final notifier = container.read(draftProvider('d1').notifier);
    // **`build()` 是异步的，断言之前必须先等它落定。** `DraftStore.read` 返回
    // Future，而异步 build 在 future 完成之前状态是 `AsyncLoading`；
    // `AsyncValue.value` 此时是 **null**（`_value` 只在 data/error 落定时才填，
    // 见 riverpod 的 async_value.dart）——不等就是 `expect(null, '')`，必红。
    //
    // 等 `.future` 而不是 `Future.delayed(Duration.zero)`：前者拿到的就是
    // **这一次 build 的那个 future**，确定性；后者赌"一轮事件循环够不够"，
    // 而这里面是真文件 IO（`exists()` → `readAsBytes()`）。
    await container.read(draftProvider('d1').future);
    expect(container.read(draftProvider('d1')).value, '', reason: '没写过就是空串');

    await notifier.save('show version\n');

    expect(container.read(draftProvider('d1')).value, 'show version\n');
    expect(
      await container.read(appStoresProvider).drafts.read('d1'),
      'show version\n',
      reason: '草稿必须落盘（FR-E-04：切走再切回来要还在）',
    );
  });

  test('会话：每台设备一个 controller，连上之后输出进各自的缓冲（FR-O-09）', () async {
    final factory = FakeSessionFactory();
    final container = await boot(
      devices: [
        fakeProfile(id: 'a', name: 'A'),
        fakeProfile(id: 'b', name: 'B'),
      ],
      factory: factory,
    );

    final a = container.read(sessionProvider('a').notifier);
    final b = container.read(sessionProvider('b').notifier);
    expect(identical(a, b), isFalse, reason: '每台设备各自一个会话');

    await a.connect();
    await b.connect();
    expect(factory.sessions, hasLength(2));

    factory.sessions[0].emit('来自 A');
    await Future<void>.delayed(Duration.zero);

    final bufferA = container.read(outputBufferProvider('a'));
    final bufferB = container.read(outputBufferProvider('b'));
    expect(bufferA.lines.first.single.text, '来自 A');
    // **判据必须是内容，不能是行数。** `OutputBuffer._lines` 初始就带着一条空的
    // "进行中"行（`final List<List<AnsiSpan>> _lines = [<AnsiSpan>[]];`），所以 B
    // 从没收到东西时 `lines` 也已经有 1 条 —— 而 A 的输出真串进 B 时 B **同样**
    // 只有 1 条（那一条里装着 A 的文本）。`hasLength(1)` 在两种情况下都绿，
    // 恰好对这条用例要抓的那种错误视而不见。
    expect(
      bufferB.lines.single,
      isEmpty,
      reason: 'A 的输出不得串到 B 的缓冲里',
    );
  });

  test('改设置不会把正在用的输出缓冲换成另一个（FR-O-09）', () async {
    // 本用例钉的是 `outputBufferProvider` **不 watch 设置**。
    //
    // 若它 watch（原来的写法），`settingsProvider` 一变它就被重建，而
    // `SessionNotifier.build()` 早把旧缓冲抓成了 `SessionController` 的 `final`
    // 字段 —— 于是读到的缓冲和会话在写的缓冲成了两个实例：输出区当场变空，
    // 之后设备吐的每一个字都进那个没人看的旧缓冲。
    //
    // **判据必须是"是不是同一个实例"**：只看内容的话，改设置后旧缓冲里的东西
    // 还在（新缓冲是空的，可下面那条 `contains` 读的是新缓冲 —— 会红），但要
    // 精确地钉住"分家"这件事，`identical` 才是直说的那个。
    final factory = FakeSessionFactory();
    final container = await boot(
      devices: [fakeProfile(id: 'd1')],
      factory: factory,
    );

    await container.read(sessionProvider('d1').notifier).connect();
    factory.sessions.single.emit('改设置之前\n');
    await Future<void>.delayed(Duration.zero);

    final before = container.read(outputBufferProvider('d1'));
    expect(before.lines.first.single.text, '改设置之前');

    await container
        .read(settingsProvider.notifier)
        .update(const AppSettings(theme: AppTheme.dark));
    await Future<void>.delayed(Duration.zero);

    expect(
      identical(container.read(outputBufferProvider('d1')), before),
      isTrue,
      reason: '改设置不得换掉正在用的缓冲 —— 换了就是一个空缓冲，输出区当场清空，'
          '而且会话再也不会往界面看的那个缓冲里写',
    );

    // 光"还是同一个实例"不够：会话得**确实还写着它**。
    factory.sessions.single.emit('改设置之后\n');
    await Future<void>.delayed(Duration.zero);
    expect(
      container
          .read(outputBufferProvider('d1'))
          .lines
          .map((line) => line.map((s) => s.text).join())
          .join('\n'),
      contains('改设置之后'),
      reason: '会话没有被"离婚"到一个没人看的缓冲上',
    );
  });

  test('删掉设备时它的会话被拆掉', () async {
    final factory = FakeSessionFactory();
    final container = await boot(
      devices: [fakeProfile(id: 'd1')],
      factory: factory,
    );
    await container.read(sessionProvider('d1').notifier).connect();
    final session = factory.sessions.single;

    await container.read(devicesProvider.notifier).remove('d1');
    await Future<void>.delayed(Duration.zero);

    expect(session.closed, isTrue, reason: '设备都没了，会话不该还插在设备上');
  });
}
