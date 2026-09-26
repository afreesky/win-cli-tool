import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/host_key_prompt.dart';
import 'package:win_cli_tool/state/providers.dart';
import 'package:win_cli_tool/ui/widgets/host_key_prompt_host.dart';

import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_hkprompt_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  KnownHost candidate(String ip, {String fp = 'SHA256:abc'}) => KnownHost(
    host: ip,
    port: 22,
    keyType: 'ssh-ed25519',
    fingerprint: fp,
  );

  ProviderContainer makeContainer({
    AppSettings settings = const AppSettings(),
  }) {
    final container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores(paths: AppPaths(root))),
        startupProvider.overrideWithValue(
          AppStartup(settings: settings, devices: const []),
        ),
        logsDirPath.overrideWithValue('${root.path}/logs'),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('HostKeyPromptNotifier', () {
    test('接受时 ask 的 Future 兑现 true（FR-C-11）', () async {
      final container = makeContainer();
      final notifier = container.read(hostKeyPromptProvider.notifier);

      final answer = notifier.ask(candidate('10.0.0.1'));
      final prompt = container.read(hostKeyPromptProvider);
      expect(prompt, isNotNull);
      expect(prompt!.host.fingerprint, 'SHA256:abc');

      notifier.reply(prompt, true);

      expect(await answer, isTrue);
      expect(
        container.read(hostKeyPromptProvider),
        isNull,
        reason: '回答完就该收起来',
      );
    });

    test('拒绝时兑现 false', () async {
      final container = makeContainer();
      final notifier = container.read(hostKeyPromptProvider.notifier);

      final answer = notifier.ask(candidate('10.0.0.1'));
      notifier.reply(container.read(hostKeyPromptProvider)!, false);

      expect(await answer, isFalse);
    });

    test('过期的回答不生效，也不会串到新的询问上（设计点 2）', () async {
      final container = makeContainer();
      final notifier = container.read(hostKeyPromptProvider.notifier);

      final first = notifier.ask(candidate('10.0.0.1', fp: 'SHA256:first'));
      final stale = container.read(hostKeyPromptProvider)!;

      // 第一个还没答，第二个就来了（FR-C-14 会并发连多台）。
      final second = notifier.ask(candidate('10.0.0.2', fp: 'SHA256:second'));

      notifier.reply(stale, true);
      expect(await first, isTrue, reason: '它答的是第一个');
      expect(
        container.read(hostKeyPromptProvider)!.host.fingerprint,
        'SHA256:second',
        reason: '答完第一个，第二个应当接上',
      );

      // **同一个过期对象再答一次**：它已经不是当前那个了。
      notifier.reply(stale, true);

      final current = container.read(hostKeyPromptProvider)!;
      expect(current.host.fingerprint, 'SHA256:second', reason: '不该被顶掉');
      notifier.reply(current, false);
      expect(await second, isFalse);
    });

    test('容器销毁时挂着的询问一律判拒绝（设计点 3）', () async {
      final container = makeContainer();
      final notifier = container.read(hostKeyPromptProvider.notifier);

      final answer = notifier.ask(candidate('10.0.0.1'));
      container.dispose();

      expect(
        await answer,
        isFalse,
        reason: '默认必须是拒绝 —— 没人回答时绝不能放行',
      );
    });
  });

  group('sessionFactoryProvider 的接线（NFR-S-03 的要害）', () {
    test('onUnknownHostKey 不是 null，且能把用户的选择带回去（FR-C-11）', () async {
      final container = makeContainer();
      final factory = container.read(sessionFactoryProvider);

      expect(
        factory.onUnknownHostKey,
        isNotNull,
        reason: '为 null 时 SshSession 一律拒绝 —— 任何新设备都连不上，'
            '而"确认后保存"这条 FR-C-11 从来没有发生过',
      );

      final pending = factory.onUnknownHostKey!(candidate('10.0.0.1'));
      final prompt = container.read(hostKeyPromptProvider)!;
      container.read(hostKeyPromptProvider.notifier).reply(prompt, true);

      expect(await pending, isTrue);
    });

    test('设置里关掉校验时，factory 的 verifyHostKey 跟着是 false（FR-C-11）', () {
      final container = makeContainer(
        settings: const AppSettings(verifySshHostKey: false),
      );

      expect(container.read(sessionFactoryProvider).verifyHostKey, isFalse);
    });

    test('设置里超时改了，factory 的 connectTimeout 跟着改（FR-C-13）', () {
      final container = makeContainer(
        settings: const AppSettings(connectTimeoutMs: 3000),
      );

      expect(
        container.read(sessionFactoryProvider).connectTimeout,
        const Duration(milliseconds: 3000),
      );
    });
  });

  group('HostKeyPromptHost', () {
    Future<void> pumpHost(
      WidgetTester tester, {
      AppSettings settings = const AppSettings(),
    }) => pumpUi(
      tester,
      root: root,
      settings: settings,
      child: const HostKeyPromptHost(child: SizedBox()),
    );

    testWidgets('询问时弹出对话框，指纹一字不差地摆出来（FR-C-11）', (tester) async {
      await pumpHost(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HostKeyPromptHost)),
      );

      final answer = container
          .read(hostKeyPromptProvider.notifier)
          .ask(candidate('10.0.0.1', fp: 'SHA256:Zx9/abc='));
      await tester.pumpAndSettle();

      expect(find.textContaining('10.0.0.1'), findsWidgets);
      expect(find.textContaining('ssh-ed25519'), findsOneWidget);
      expect(find.text('SHA256:Zx9/abc='), findsOneWidget);

      await tester.tap(find.text('接受并保存'));
      await tester.pumpAndSettle();

      expect(await answer, isTrue);
      expect(find.text('接受并保存'), findsNothing, reason: '答完要收起来');
    });

    testWidgets('点「拒绝」把 false 带回去', (tester) async {
      await pumpHost(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HostKeyPromptHost)),
      );

      final answer = container
          .read(hostKeyPromptProvider.notifier)
          .ask(candidate('10.0.0.1'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();

      expect(await answer, isFalse);
    });

    testWidgets('两个询问排队出现，不是只弹一个（设计点 1）', (tester) async {
      await pumpHost(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HostKeyPromptHost)),
      );
      final notifier = container.read(hostKeyPromptProvider.notifier);

      final first = notifier.ask(candidate('10.0.0.1', fp: 'SHA256:first'));
      final second = notifier.ask(candidate('10.0.0.2', fp: 'SHA256:second'));
      await tester.pumpAndSettle();

      expect(find.text('SHA256:first'), findsOneWidget);

      await tester.tap(find.text('接受并保存'));
      await tester.pumpAndSettle();

      expect(await first, isTrue);
      expect(find.text('SHA256:second'), findsOneWidget, reason: '第二个要接上');

      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(await second, isFalse);
    });
  });
}
