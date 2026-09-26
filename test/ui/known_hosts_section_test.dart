import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/ui/dialogs/known_hosts_section.dart';

import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_khs_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 预置盘上的 `known_hosts.json`。
  ///
  /// **用另一个 `AppStores` 实例是安全的**，因为 `FileHostKeyStore` **不持
  /// 实例缓存**（见它 `_readFromDisk` 的文档）。这一点正是那段文档要保的东西。
  ///
  /// **必须包在 `tester.runAsync` 里，否则用例必挂。** 写盘是真 I/O，而
  /// `testWidgets` 的用例体跑在 `FakeAsync` 里（`flutter_test` 的
  /// `binding.dart`，`AutomatedTestWidgetsFlutterBinding` 用 `FakeAsync.run`
  /// 包住整个用例体）：真 I/O 的完成回调落进**假**的微任务队列，而那个队列
  /// 只有 `pump` / `runAsync` 才会推。用例体自己 `await` 它是推不动的 ——
  /// 体挂在那里等，框架在等体，谁都不动，直到 `testWidgets` 自带的
  /// **10 分钟**超时。`dart analyze` 看不出这件事，它只在运行时发作。
  ///
  /// 实测（Task 10 执行期）：不包 `runAsync` 时，第一条调用它的用例就把整个
  /// 文件挂住（180s 被杀，`EXIT=124`）；包上之后同七条用例 4 秒跑完。
  /// 这与 `sync_dialog_test.dart` 的 `seedDraft`、`settleDisk` /
  /// `pumpUntilTrue` 里那些 `tester.runAsync` 是**同一条规矩**。
  Future<void> seed(WidgetTester tester, List<KnownHost> hosts) async {
    await tester.runAsync(() async {
      final store = AppStores(paths: AppPaths(root)).hostKeys;
      for (final h in hosts) {
        await store.save(h);
      }
    });
  }

  KnownHost host(String ip, {String type = 'ssh-ed25519', String fp = 'SHA256:aaa'}) =>
      KnownHost(host: ip, port: 22, keyType: type, fingerprint: fp);

  Future<void> pumpSection(WidgetTester tester) async {
    await pumpUi(
      tester,
      root: root,
      child: const SizedBox(height: 400, child: KnownHostsSection()),
    );
    // 这一段 `initState` 就 `await all()` 读盘（真 I/O），`settleDisk` 的
    // 12×5ms 是碰运气。等它离开"读取中…"——**空、有记录、读失败**三种收尾
    // 都不再是它，所以这一句对七条用例都成立。
    await pumpUntilTrue(tester, () => find.text('读取中…').evaluate().isEmpty);
  }

  testWidgets('空的时候说清楚，不是一片空白', (tester) async {
    await pumpSection(tester);

    expect(find.textContaining('还没有任何已知主机密钥'), findsOneWidget);
  });

  testWidgets('列出一条记录的主机与算法（FR-G-01 的"查看"）', (tester) async {
    await seed(tester, [
      host('10.0.0.1', type: 'ssh-ed25519', fp: 'SHA256:abc123'),
    ]);

    await pumpSection(tester);

    expect(find.textContaining('10.0.0.1:22'), findsOneWidget);
    expect(find.textContaining('ssh-ed25519'), findsOneWidget);
    expect(find.textContaining('SHA256:abc123'), findsOneWidget);
  });

  testWidgets('同一主机的两种算法是两条（spec §13.5）', (tester) async {
    await seed(tester, [
      host('10.0.0.1', type: 'ssh-ed25519', fp: 'SHA256:ed'),
      host('10.0.0.1', type: 'rsa-sha2-256', fp: 'SHA256:rsa'),
    ]);

    await pumpSection(tester);

    expect(find.textContaining('SHA256:ed'), findsOneWidget);
    expect(find.textContaining('SHA256:rsa'), findsOneWidget);
    expect(find.textContaining('10.0.0.1:22'), findsNWidgets(2));
  });

  testWidgets('逐条清除：确认之后盘上那条没了（FR-G-01 的"逐条清除"）', (tester) async {
    await seed(tester, [
      host('10.0.0.1', fp: 'SHA256:ed'),
      host('10.0.0.2', type: 'rsa-sha2-256', fp: 'SHA256:rsa'),
    ]);
    await pumpSection(tester);

    // 第一条记录的清除按钮。
    await tester.tap(find.byKey(const ValueKey('known-host-remove-0')));
    await tester.pumpAndSettle();
    expect(find.text('清除这条已知主机密钥？'), findsOneWidget);

    await tester.tap(find.text('确认清除'));
    // **不能只 `settleDisk`。** `_remove` 是 `await remove()` → `await _reload()`，
    // 两次真 I/O（`remove` 走 `_readFromDisk` + `writeJsonObject`，两个 chmod
    // 真进程）。而且这里**盯"确认框关了"没用** —— 那个框在**写之前**就 pop 了。
    // 能当信号的是"列表自己刷新掉了那一行"：它只在 `remove()` 返回之后才可能
    // 发生。等到之后再断言，两条断言（盘上、界面上）都不会红在"还没轮到"上。
    await pumpUntilTrue(
      tester,
      () => find.textContaining('SHA256:ed').evaluate().isEmpty,
    );

    final left = (await tester.runAsync(
      () => AppStores(paths: AppPaths(root)).hostKeys.all(),
    ))!;
    expect(left, hasLength(1));
    expect(left.single.host, '10.0.0.2');
    expect(find.textContaining('SHA256:ed'), findsNothing, reason: '列表要跟着刷新');
  });

  testWidgets('清除时点取消：盘上一条都不少', (tester) async {
    await seed(tester, [host('10.0.0.1')]);
    await pumpSection(tester);

    await tester.tap(find.byKey(const ValueKey('known-host-remove-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await settleDisk(tester);

    expect(
      await tester.runAsync(
        () => AppStores(paths: AppPaths(root)).hostKeys.all(),
      ),
      hasLength(1),
    );
    expect(find.textContaining('SHA256:aaa'), findsOneWidget);
  });

  testWidgets('全部清除也要确认，且一次清光', (tester) async {
    await seed(tester, [host('10.0.0.1'), host('10.0.0.2')]);
    await pumpSection(tester);

    await tester.tap(find.byKey(const ValueKey('known-hosts-clear-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认清除'));
    // 同「逐条清除」：等界面自己刷成空态，而不是赌那 60ms 真实时间。
    // 两条 `remove` 是**串行 await** 的，所以刷成空态就意味着两条都写完了。
    await pumpUntilTrue(
      tester,
      () => find.textContaining('还没有任何已知主机密钥').evaluate().isNotEmpty,
    );

    expect(
      await tester.runAsync(
        () => AppStores(paths: AppPaths(root)).hostKeys.all(),
      ),
      isEmpty,
    );
    expect(find.textContaining('还没有任何已知主机密钥'), findsOneWidget);
  });

  testWidgets('文件坏了：说出来，不把设置对话框炸掉', (tester) async {
    // **必须 `await`。** 少这个 await，`writeAsString` 就与下面的
    // `pumpSection` 赛跑：`_readFromDisk` 先看到"文件不存在"就返回空 map，
    // 界面显示的是空态而不是"无法读取"，用例红在一个看起来像实现错的地方。
    await tester.runAsync(
      () => File('${root.path}/known_hosts.json').writeAsString('{ not json'),
    );

    await pumpSection(tester);

    expect(find.textContaining('无法读取'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
