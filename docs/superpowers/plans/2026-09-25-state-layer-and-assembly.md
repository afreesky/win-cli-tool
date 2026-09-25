# 状态层与装配（计划 5a）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把已经写完但**一个生产调用方都没有**的四个层（`data/` `connection/` `command/` `render/`）真正装起来：一组唯一的持久化实例、一台设备一个会话编排器、以及一个输出缓冲 —— 并在此之前修掉三处会**静默丢用户数据**的既有缺陷。

**Architecture:** 装配根在 `lib/state/`。`main()` 在 `runApp` 之前把设备与设置**一次性读出来**（异步只有这一处），此后所有 provider 都是同步的；`ProviderScope(overrides:)` 把这个结果与唯一的 store 集合注入进去。每台设备的会话由一个 `SessionController` 编排：**它订阅 `ConnectionManager.output`**（不是 `Session.output`），在构造时就订阅，早于第一次连接；同一份文本喂给输出缓冲，日志从**同一个缓冲**取 —— §5.6 的「日志与输出区所见一致」因此是构造上的事实，不是两处各自遵守的约定。

**Tech Stack:** Flutter 3.44.4 / Dart 3.12.2、`flutter_riverpod` 3.4.3、`path_provider` 2.1.6、`clock` 1.1.1（已在用）。

---

## 0. 给实现者的硬约束（逐条照做，不要"改进"）

1. **不要运行 `dart format`。** 本仓库的格式是逐行审过的，格式化会重排整个文件。
2. **测试一律用 `flutter test`**，**不是** `dart test`。
3. **一次只跑本任务的那一个测试文件**；整仓跑只在任务收尾时做一次。
4. **绝不并发跑两个 `flutter test`** —— spec §13.23 的构建锁竞争会把两边都拖死（实测一次卡了 13 分钟）。某行超过约 2 分钟没返回，先 `pgrep -af flutter` 看孤儿进程，**先杀孤儿再重跑**。
5. **判红只看点名用例的 `[E]`**。输出里出现的是**文件路径**的那是假红，不算证据。
6. **不要读 `/tmp/wct-plan2-check`**（参考实现）、**不要读 `/tmp/wct-plan4-findings.md`**。
7. **不要改 `git config user.email`**（它现在是占位符，这是已知的、有意留着的）；**不要 push**；**不要配置远程**；**不要改写历史**（不许 rebase / amend / reset）。
8. **不要编辑本计划文件** —— 它是被评审过的产物，改由控制者来合。
9. 暂存只按显式路径 `git add <path>`，不要 `git add -A`。
10. 每条提交的信息以 `Co-Authored-By: Claude Code <noreply@anthropic.com>` 结尾。
11. 断言类型**一律**用 `expect(v, isA<T>())`，**永不**用 `expect(v.runtimeType, T)`（后者失败信息是 `Expected: Uint8List, Actual: Uint8List`，误导）。
12. 涉及**拆除**（`cancel` / `close` / `dispose`）的断言一律用**真实 `async`** 测；`fakeAsync` 只留给需要控制时间的用例（退避序列、超时、断线时长）。原因：`fake_async` 推不动 `await` 串起来的拆除链（spec §13.15）。

## 1. 本计划的边界

**做（属于计划 5a）：**

- 三处既有缺陷的修复（Task 1–3）—— 它们是"装配起来就会踩中"的前置条件。
- `render/ansi_parser.dart` 的流式接续（Task 4）—— 输出缓冲正确性所必需。
- `lib/state/`：输出缓冲、路径、唯一的 store 集合、会话编排、Riverpod providers（Task 5–8）。
- `lib/app.dart` + `lib/main.dart`：真正的装配与生命周期（Task 9）。
- 无头端到端装配验证（Task 10）。

**不做（属于计划 5b「界面」）：**

- `lib/ui/` 下的**任何** widget：主窗口、四个面板、三个对话框、通用组件。本计划**一个 widget 都不建**（除了 Task 9 里那个最小的 `MaterialApp` 外壳）。
- §9.2 的六条界面行为测试（发送范围、设备切换、后台队列、按钮状态、自动滚动、清屏的**交互**验证）。清屏的**数据**语义（FR-O-05：只清显示、不动日志）在 Task 5 用单元测试钉住；它的按钮在 5b。
- 输出渲染的**节流**（NFR-F-02 的 60ms 批量刷新）—— 那是重绘策略，没有重绘就没有可测的东西。
- 设备编辑对话框里的**明文凭据提示**（NFR-S-02）—— 对话框在 5b。
- 跳板机相关的**任何**界面（spec §10.2：整体放弃）。`JumpHost` 模型与 `DeviceProfile.jumpHostIds` **原样保留不动**（手写的 v2 文件在往返中不能丢数据）。

## 2. 文件结构

**新建：**

| 文件 | 职责 |
|---|---|
| `lib/state/app_paths.dart` | 应用数据目录下的路径拼接。**不碰文件系统**。 |
| `lib/state/app_stores.dart` | 四个 store 的**唯一**实例（`late final`，构造上一个文件一个）。 |
| `lib/state/output_buffer.dart` | 一台设备的输出缓冲：流式块 → 按行分组的样式片段；**同时是日志取文本的唯一来源**。 |
| `lib/state/session_controller.dart` | 一台设备的会话编排：`ConnectionManager` 事件 → 界面可用状态 + 日志生命周期 + dispatcher 重订阅。 |
| `lib/state/providers.dart` | spec §8.4 点名的文件：全部 Riverpod providers 与装配根。 |
| `lib/app.dart` | 根 widget：主题、`MaterialApp`、启动后的一次性副作用（FR-C-14 自动连接）。 |
| `test/fixtures/fake_session.dart` | 会话层测试夹具（供 `test/state/` 复用）。 |
| `test/render/ansi_stream_test.dart` | Task 4 的用例。 |
| `test/state/output_buffer_test.dart` | Task 5 的用例。 |
| `test/state/app_stores_test.dart` | Task 6 的用例。 |
| `test/state/session_controller_test.dart` | Task 7 的用例。 |
| `test/state/providers_test.dart` | Task 8 的用例。 |
| `test/ui/app_test.dart` | Task 9 的外壳冒烟测试。 |
| `test/state/assembly_e2e_test.dart` | Task 10 的端到端装配验证。 |

**修改：**

| 文件 | 改什么 |
|---|---|
| `lib/data/device_store.dart` | 删掉 `_rawJumpHosts` 实例状态，`save()` 自己读盘（Task 1）。 |
| `lib/data/host_key_store.dart` | 删掉实例缓存；补 `schemaVersion` 校验（Task 2）。 |
| `lib/connection/connection_manager.dart` | `connect()` 的代际令牌（Task 3）。 |
| `lib/render/ansi_parser.dart` | 加 `parseAnsiChunk` / `ansiHoldBackLength`，`parseAnsi` 变成它的一层壳（Task 4）。 |
| `test/data/device_store_save_test.dart` | 两条用例的期望与注释（Task 1）。 |
| `test/data/host_key_store_test.dart` | 补 4 条用例、改 2 处注释（Task 2）。 |
| `test/connection/connection_manager_test.dart` | 补重叠 `connect()` 的用例（Task 3）。 |
| `lib/main.dart` | 换成真正的 `main()`（Task 9）。 |
| `pubspec.yaml` | 加 `flutter_riverpod` / `path_provider`（Task 6）。 |

**为什么 `lib/state/` 下不是一个 `providers.dart`：** spec §8.4 只列了 `providers.dart`，那是"Riverpod providers 放哪"的答案，不是"状态层只能有一个文件"。装配根（`app_stores`）、缓冲（`output_buffer`）、编排（`session_controller`）各自是独立可测的单元，塞进一个文件会让那个文件同时承担三种生命周期。`providers.dart` 保持薄：它只做接线。

**为什么复用 `test/fixtures/` 而不是把 `connection_manager_test.dart` 里的私有夹具提出来：** 那个文件里的 `_FakeSession` 带着一段**承重**的注释（它**刻意不关** `_output`，为的是让"manager 有没有取消订阅"真的可观测）—— 那段说明属于那个文件，搬走会让它失去上下文。新的 `test/fixtures/fake_session.dart` 是给状态层用的另一副夹具，目的不同（验证接线，不验证连接语义）。这是知情的取舍，不是漏了 DRY。

---

## Task 1: `DeviceStore.save` 不再依赖实例状态

**为什么：** `_rawJumpHosts` 是**每个 `DeviceStore` 各自**的状态，只有 `load()` 会填它，而 `save()` 写回的是"本实例 load 过的那一份"。没在本实例上 `load()` 过就直接 `save()`，文件里手写的 `jumpHosts` 会被**静默抹成空数组** —— 用户手写的堡垒机配置没了，屏幕上一句提示都没有。跳板机虽已放弃，但"别丢用户数据"这条没有放弃。

**Files:**
- Modify: `lib/data/device_store.dart`
- Test: `test/data/device_store_save_test.dart`

- [ ] **Step 1: 写失败的用例**

在 `test/data/device_store_save_test.dart` 的 `void main()` 内、`test('没读过盘就存盘：...')` **之前**插入：

```dart
  test('另一个实例从没读过盘，存盘也不会抹掉用户手写的 jumpHosts', () async {
    await file.writeAsString(jsonEncode({
      'schemaVersion': 2,
      'jumpHosts': [
        {'id': 'j1', 'name': '堡垒机', 'host': 'h', 'port': 22, 'username': 'u'},
      ],
      'devices': <Object?>[],
    }));
    // 写的是一个**全新的**实例（`store()` 每次调用都新建），它这辈子没 load() 过。
    // 修复前这里写回空数组：用户手写的堡垒机配置被静默抹掉，没有任何提示。
    // 修复后存盘结果与"用哪个实例写"无关 —— `save` 自己读盘。
    await store().save([profile('d1')]);

    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(
      raw['jumpHosts'],
      hasLength(1),
      reason: '存盘结果不能取决于写它的那个实例读没读过盘',
    );
  });
```

并把 `test('没读过盘就存盘：jumpHosts 写成空数组，不是 null')` 这条**改名并改写**为：

```dart
  test('盘上没有文件时，jumpHosts 写成空数组而不是 null', () async {
    await store().save([profile('d1')]);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['jumpHosts'], isEmpty);
  });
```

（行为不变，但原来的名字描述的是一个**已经不存在**的危险路径。）

- [ ] **Step 2: 跑用例，确认它红**

Run: `flutter test test/data/device_store_save_test.dart`
Expected: 新增那条 `[E]`，失败信息是 `Expected: an object with length of <1>` / `Actual: []` —— **点名用例名**，不是文件路径。

- [ ] **Step 3: 改实现**

在 `lib/data/device_store.dart` 里，**删掉** `_rawJumpHosts` 字段及其文档（当前 `:58-67`）：

```dart
  /// 上一次读到的 `jumpHosts` 原文，存盘时**原样写回**。
  ///
  /// 跳板机已放弃（spec §10.2），V1 既不解释也不修改这个字段；留着的唯一目的是
  /// **不丢用户数据** —— 手写的 `jumpHosts` 不该被本程序的一次保存抹掉。
  ///
  /// **但"原样写回"是有前提的，别读成无条件的**：写回的是**本实例 `load()` 记下的
  /// 那一份**。没在本实例上 `load()` 过就直接 `save()`，这里还是初始的 `const []`，
  /// 于是文件里手写的 `jumpHosts` **会被抹成空数组**（实测过，有测试钉着这个行为）。
  /// 所以：**同一个文件不要建两个 store，一个读一个写** —— 计划 5 尤其注意。
  List<Object?> _rawJumpHosts = const [];
```

替换为：

```dart
  /// 读出盘上**当前**的 `jumpHosts` 原文，供存盘时原样写回。
  ///
  /// 跳板机已放弃（spec §10.2），V1 既不解释也不修改这个字段；留着的唯一目的是
  /// **不丢用户数据** —— 手写的 `jumpHosts` 不该被本程序的一次保存抹掉。
  ///
  /// **为什么每次都读盘，而不是拿"本实例读到的那一份"：** 后者是个静默丢数据的
  /// 陷阱。`load()` 与 `save()` 一旦落在**不同实例**上（装配层读、界面另建一个写、
  /// 或将来某个后台任务自己 new 一个），写回的是初始值 `const []`，文件里手写的
  /// 堡垒机配置**被抹成空数组**，而这条路径上没有任何东西会报错 —— 用户要等到
  /// 哪天去查跳板机配置才发现。读盘是唯一让"存盘结果与本实例无关"的做法。
  ///
  /// 代价是每次存盘多读一次文件。存盘是用户动作（加/改/删设备），不是热路径。
  Future<List<Object?>> _rawJumpHostsFromDisk() async {
    // **读不回来时退回空数组，不抛。** 这里是**存盘**路径：用户此刻正在改配置，
    // 多半就是想修好一个坏文件，为此抛出去等于把人锁在门外。真正的损坏上报在
    // `load()` 那边（`LoadIssueKind.corruptFile`），不在这里重复。
    try {
      final raw = await readJsonObject(file);
      final jumpHosts = raw?['jumpHosts'];
      // 与 `load()` 里同一条判法：**先查形状，不硬转**。`as List<Object?>?` 是
      // 一次没有 try 兜着的强转，手改坏的 `"jumpHosts": "x"` 会让存盘直接抛。
      return jumpHosts is List<Object?> ? jumpHosts : const [];
    } catch (_) {
      return const [];
    }
  }
```

在 `load()` 里**删掉**这一行（当前 `:123-124`）：

```dart
    final rawJumpHosts = raw['jumpHosts'];
    _rawJumpHosts = rawJumpHosts is List<Object?> ? rawJumpHosts : const [];
```

（`load()` 此后不再需要认识 `jumpHosts` —— 它只负责读设备。原地上方那段解释"形状不对时退回空数组"的注释随之删掉，因为那段判断搬进了 `_rawJumpHostsFromDisk`。）

在 `save()` 里，把：

```dart
      // 原样搬运，不解释也不修改 —— 跳板机已放弃（spec §10.2），
      // 这里唯一的目的就是别把用户手写的数据抹掉。
      'jumpHosts': _rawJumpHosts,
```

改成：

```dart
      // 原样搬运，不解释也不修改 —— 跳板机已放弃（spec §10.2），
      // 这里唯一的目的就是别把用户手写的数据抹掉。
      'jumpHosts': await _rawJumpHostsFromDisk(),
```

并把 `save()` 文档末尾那行（当前 `:205`）：

```dart
  /// 另见 [_rawJumpHosts]：`jumpHosts` 只对**在本实例上 load() 过**的文件才是原样写回。
```

改成：

```dart
  /// 另见 [_rawJumpHostsFromDisk]：`jumpHosts` **每次存盘都从盘上现读**，
  /// 所以存盘结果与本实例读没读过盘无关。
```

- [ ] **Step 4: 跑用例，确认全绿**

Run: `flutter test test/data/device_store_save_test.dart`
Expected: 全部通过（原有的 12 条 + 本任务新增 1 条 = 13 条）。

- [ ] **Step 5: 提交**

```bash
git add lib/data/device_store.dart test/data/device_store_save_test.dart
git commit -m "$(cat <<'EOF'
fix(data): DeviceStore.save 每次从盘上现读 jumpHosts，不再依赖实例状态

_rawJumpHosts 只有 load() 会填，save() 写回的是"本实例 load 过的那一份"。
一旦 load 与 save 落在不同实例上（装配层读、界面另建一个写），写回的是初始
值 const []，文件里手写的 jumpHosts 被静默抹成空数组 —— 没有任何提示。
读盘是唯一让"存盘结果与本实例无关"的做法。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `FileHostKeyStore` 去掉实例缓存 + 校验 schemaVersion

**为什么两件事一起做：** 它们都是"写了却没人读/一份状态被两个实例各持一次"的同一种病。缓存让**两个实例互相盖掉对方的已知主机记录**（丢一条 = 那台主机退回"首次连接"，用户会在**没被告知记录丢过**的情况下重新确认指纹 —— 而那正是最不该被训练成习惯的动作），`all()` 还是永不刷新的快照。`schemaVersion` 则是**写进去了、从来没人读** —— 一个来自更新版本的文件会被按当前语义静默读进来。

**Files:**
- Modify: `lib/data/host_key_store.dart`（改动是贯穿的，整文件替换）
- Test: `test/data/host_key_store_test.dart`

- [ ] **Step 1: 写失败的用例**

在 `test/data/host_key_store_test.dart` 的 `void main()` 内、末尾的 `}` 之前插入：

```dart
  test('两个实例并存时，后来的 save 不会盖掉先前的记录', () async {
    // 修复前：`save` 在**本实例的缓存**上做读-改-写，而缓存是各自 load 出来的
    // 快照 —— a 与 b 各持一份，a 存 ed25519、b 存 rsa，b 落盘的结果里只有
    // rsa，a 那条**静默消失**。
    //
    // **那两句 `all()` 是承重的，不是热身装饰。** 旧实现的 `_cache` 是**懒填**的
    // （构造时不读、第一次用到才读），所以不预热的话 `b.save()` 那一刻 `b` 的缓存
    // 还是 null，它会**真的去读盘**、读到 a 刚写进去的记录，于是两边都写、什么
    // 都不丢 —— 这条用例在修复前也是绿的，钉不住它要钉的东西（实测过：不预热时
    // 修复前 `+19`，即它没红）。预热之后两个实例才各持一份**自己的空快照**，
    // 而这正是装配层的真实场景：启动时读一遍（预热），之后另一个实例再写。
    final a = store();
    final b = store();
    await a.all();
    await b.all();
    await a.save(host(type: 'ssh-ed25519'));
    await b.save(host(type: 'rsa-sha2-256'));

    expect(
      await store().find('10.0.0.1', 22, 'ssh-ed25519'),
      isNotNull,
      reason: '丢一条已知主机密钥 = 那台主机退回"首次连接"，'
          '用户会在没被告知的情况下被重新问一次指纹',
    );
    expect(await store().find('10.0.0.1', 22, 'rsa-sha2-256'), isNotNull);
  });

  test('长命实例的 all() 读得到另一个实例写进去的记录（不是快照）', () async {
    final s = store();
    expect(await s.all(), isEmpty);
    await store().save(host()); // 另一个实例写盘
    expect(await s.all(), hasLength(1));
  });

  test('schemaVersion 比本程序新时抛 FormatException，不静默按当前语义读', () async {
    await file.writeAsString(
      jsonEncode({'schemaVersion': 2, 'hosts': <Object?>[]}),
    );
    expect(() => store().find('h', 22, 'k'), throwsFormatException);
  });

  test('schemaVersion 不是整数时也抛 FormatException', () async {
    await file.writeAsString(
      jsonEncode({'schemaVersion': '1', 'hosts': <Object?>[]}),
    );
    expect(() => store().find('h', 22, 'k'), throwsFormatException);
  });

  test('没有 schemaVersion 时抛 FormatException', () async {
    // 本文件只由本程序写出，写出时一定带版本号 —— 所以"没有版本号"意味着
    // 这是别处来的文件。本类的立场是**响亮地失败**（见 _readFromDisk）。
    await file.writeAsString(jsonEncode({'hosts': <Object?>[]}));
    expect(() => store().find('h', 22, 'k'), throwsFormatException);
  });
```

再把 `test('写盘失败时，本实例不留下"文件里没有"的记录（缓存不领先于文件）')` 的**名字与正文注释**改成不再提"缓存"：

```dart
  test('写盘失败时，本实例不留下"文件里没有"的记录', () async {
    // 父路径是一个**普通文件**，所以写盘必定失败，且与 uid 无关（chmod 挡不住
    // root，这个形状挡得住）。要钉的是：失败之后本实例**不能**声称这条记录存在
    // —— 设置界面（FR-G-01）把它列出来、`find` 把它当已知主机放行，而重启之后
    // 它就消失了。已知主机记录**悄悄消失**正是 [FileHostKeyStore._readFromDisk]
    // 那段注释最想避免的结局。（修复前这条靠"先写盘、成功了才换缓存"的写序成立；
    // 现在没有缓存了，它靠"每次都读盘"成立 —— 断言不变，理由变了。）
    final blocker = File('${root.path}/blocker')..writeAsStringSync('not a dir');
    final s = FileHostKeyStore(file: File('${blocker.path}/known_hosts.json'));

    await expectLater(s.save(host()), throwsA(isA<FileSystemException>()));

    expect(await s.find('10.0.0.1', 22, 'ssh-ed25519'), isNull,
        reason: '写盘失败后本实例不得声称这条记录存在 —— 否则重启后它就不见了');
  });
```

并把 `test('remove 不存在的记录不抛，且不改动文件内容')` 里那句注释：

```dart
    // 此时 `s` 的缓存里已经有记录，一旦它重写，写出来的是缓存（规范形态），
    // 绝不会是这段手写文本。
```

改成：

```dart
    // `s` 已经 load 过这个文件，而且它**每次操作都重读盘** —— 一旦它重写，
    // 写出来的一定是它解析后的规范形态，绝不会是这段手写文本。
```

- [ ] **Step 2: 跑用例，确认它红**

Run: `flutter test test/data/host_key_store_test.dart`
Expected: **5 条新用例全部点名变红** —— `+18 -5`。五条都在下面的 `Failing tests:`
清单里，逐条点名（有两条 `schemaVersion` 的失败信息长这样：

```
  Expected: throws <Instance of 'FormatException'>
    Actual: <Closure: () => Future<KnownHost?>>
     Which: returned a Future that emitted <null>
```

—— 因为 `expect(() => store().find(...), throwsFormatException)` 是**异步**抛出的，
失败时 matcher 描述的是那个闭包，这是正常的，不是"没抛"）。

- [ ] **Step 3: 换掉实现**

把 `lib/data/host_key_store.dart` **整个文件**替换为：

```dart
import 'dart:io';

import '../connection/known_host.dart';
import 'json_file.dart';

/// 当前 `known_hosts.json` 的格式版本。
///
/// 与 `devices.json`（`kDevicesSchemaVersion`）和 `settings.json`
/// （`kSettingsSchemaVersion`）一样要有常量：写入的地方和读取的地方**必须是同一个
/// 字面量**，否则"写了却从不读"会以另一种形状回来 —— 写的一方升到 2、读的一方
/// 还在认 1，而两边单独看都"对"。
const int kHostKeySchemaVersion = 1;

/// 已知主机密钥的落盘实现（FR-C-11「首次连接确认后保存」）。
///
/// 实现的是计划 2 冻结的 [HostKeyStore] 接口，条目形状也与计划 2 的测试
/// 一致 —— 见 spec §13.5。文件形状是本计划定的：
/// `{"schemaVersion": 1, "hosts": [ {host, port, keyType, fingerprint} ]}`。
class FileHostKeyStore implements HostKeyStore {
  FileHostKeyStore({required this.file});

  final File file;

  @override
  Future<KnownHost?> find(String host, int port, String keyType) async =>
      (await _readFromDisk())[(host, port, keyType)];

  @override
  Future<void> save(KnownHost host) async {
    final next = Map.of(await _readFromDisk())
      ..[(host.host, host.port, host.keyType)] = host;
    await _persist(next);
  }

  /// 删除这一条记录。
  ///
  /// 删除失败时会抛出去、且盘上什么都没变 —— 用户以为已经清掉了那把密钥、
  /// 文件里却还在，是最坏的结局："清掉一条已知主机密钥"正是用户遇到真的密钥
  /// 变更时唯一的出路（`known_host.dart` 里 [HostKeyStore.remove] 的文档）。
  @override
  Future<void> remove(String host, int port, String keyType) async {
    final map = await _readFromDisk();
    if (!map.containsKey((host, port, keyType))) return;
    final next = Map.of(map)..remove((host, port, keyType));
    await _persist(next);
  }

  /// 全部记录，供 FR-G-01 的「已知主机密钥记录的查看与逐条清除」使用。
  ///
  /// **刻意只加在这个具体类上，没有加到 [HostKeyStore] 接口里。**
  /// 加接口就要改计划 2 已冻结的 `known_host.dart` 与它的围栏，而
  /// "枚举"只有设置界面需要 —— 计划 5 的组合根本来就直接构造这个具体类型，
  /// 拿到的方法是具体类型上的，不涉及向下转型（spec §13.5 的要求是
  /// "别让设置界面去 downcast 具体类型"，从具体类型上直接调用不算）。
  Future<List<KnownHost>> all() async =>
      List.unmodifiable((await _readFromDisk()).values);

  /// 从盘上读。**每次调用都真读，没有实例缓存。**
  ///
  /// 原先这里有一个 `_cache`（键是 `(host, port, keyType)` 元组，不是拼接串 ——
  /// 元组仍然是对的，理由见下）。缓存带来三件事，全都要靠"每个文件只建一个
  /// 实例"这条**纪律**才不出事：
  ///
  /// 1. 两个实例各持一份快照 ⇒ 后写的那个把先写的记录**整个盖掉**（静默丢）；
  /// 2. 长命实例的 [all] 是永不刷新的快照（设置界面看不到别处写入的记录）；
  /// 3. 缓存与文件之间多出一段需要推理的窗口，以及一条"先写盘、成功了才换缓存"
  ///    的写序（见 save 的旧注释）。
  ///
  /// 而**这个类丢数据的后果恰好是最不该依赖纪律的一处**：丢一条已知主机密钥
  /// 等于让那台主机退回"首次连接"，用户会在**根本没被告知记录丢过**的情况下
  /// 重新确认一个指纹。所以缓存整个去掉。代价是每次操作多读一次文件 —— 与一次
  /// SSH 握手相比可以忽略。
  ///
  /// **键是元组，不是 `'$host:$port:$keyType'` 拼接串。** spec §13.5 给了两个
  /// 修法，这里选的是"结构上不可能碰撞"那一个：拼接串的不变式要靠**三处**
  /// 同时成立才守得住（构造函数拒绝含冒号的 keyType + find/remove 不校验 +
  /// identity 的拼法），而这三处已经出现过一处不设防的形状。元组把它变成
  /// 类型系统的事。
  Future<Map<(String, int, String), KnownHost>> _readFromDisk() async {
    final map = <(String, int, String), KnownHost>{};
    final raw = await readJsonObject(file);
    if (raw == null) return map;

    // **版本号是写过的，就必须读。** 原先 `_persist` 写 `schemaVersion` 而这里
    // 从不看它 —— 一个来自更新版本的文件会被按当前语义**静默**读进来。
    // `is! int` 那一半也是必须的（与另外两个 store 同款）：`"schemaVersion": "1"`
    // 这样手改出来的文件否则会**静默**通过。本类对"外面来的东西"的立场见下。
    final version = raw['schemaVersion'];
    if (version is! int || version > kHostKeySchemaVersion) {
      throw FormatException(
        '已知主机密钥文件的 schemaVersion 无法识别（$version）',
        file.path,
      );
    }

    final hosts = raw['hosts'];
    if (hosts is! List<Object?>) {
      throw FormatException('已知主机密钥文件里没有 hosts 数组', file.path);
    }
    for (var i = 0; i < hosts.length; i++) {
      final entry = hosts[i];
      if (entry is! Map) {
        throw FormatException('已知主机密钥第 $i 条不是 JSON 对象', file.path);
      }
      // **这里刻意不逐条隔离**（与 DeviceStore 的读路径相反）。
      // 丢一条已知主机密钥，等于让那台主机退回"首次连接"：用户会在
      // **根本没被告知记录丢过**的情况下重新确认一个指纹 —— 而那正是
      // 最不该被训练成习惯的动作（spec §13.5）。所以文件有问题就响亮地
      // 失败，由装配层留档并告诉用户。
      final host = KnownHost.fromJson(Map<String, Object?>.from(entry));
      map[(host.host, host.port, host.keyType)] = host;
    }
    return map;
  }

  Future<void> _persist(Map<(String, int, String), KnownHost> map) async {
    await writeJsonObject(file, {
      'schemaVersion': kHostKeySchemaVersion,
      'hosts': map.values.map((h) => h.toJson()).toList(growable: false),
    });
  }
}
```

- [ ] **Step 4: 跑用例，确认全绿**

Run: `flutter test test/data/host_key_store_test.dart`
Expected: 全部通过（原有的 18 条 + 本任务新增 5 条 = 23 条）。

- [ ] **Step 5: 提交**

```bash
git add lib/data/host_key_store.dart test/data/host_key_store_test.dart
git commit -m "$(cat <<'EOF'
fix(data): 已知主机密钥去掉实例缓存，并读回 schemaVersion

缓存让两个实例各持一份快照、后写的整个盖掉先写的（静默丢记录），all() 还是
永不刷新的快照。丢一条已知主机密钥 = 那台主机退回"首次连接"，用户会在没被告知
记录丢过的情况下重新确认指纹 —— 最不该依赖"记得只建一个实例"这条纪律的一处。
同时补上 schemaVersion 校验：原先只写不读，来自更新版本的文件会被静默读入。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `ConnectionManager` 的代际令牌（计划 5 的前置条件）

**为什么必须在**本**计划做：** FR-C-03 要求「点击设备按钮，若尚未连接则同时发起连接」—— 那就是把 `connect()` 接到用户手势上。今天这个类里**没有任何东西阻止重叠**，而重叠的后果实测过：连点两下 → `created=3`、`closed=[true,false,false]`（`sessions[1]` 成了**孤儿**，一个被占住的 vty）、`received=[out1,out2]`（两条会话同时往 `mgr.output` 里灌），外加一个**假告警**（`ConnectionFailed` + `ReconnectScheduled`）和一个**假** `Reconnected` 横幅 —— 用户其实从没掉线。

**机制（实测确认过，别按"两次拆除互相拆台"去推理，那是错的）：** 是**漏拆**。输掉的那次尝试走进 `catch` 时字段早已被对手清空，于是它那句 `unawaited(_teardownSession())` 是**空操作**；它接着发 `ConnectionFailed`、调 `_scheduleRetry()` —— 在前一条会话**还活着**的时候武装一个重连定时器，那个回调直接调 `_attemptConnect()`、**不经任何拆除**，把字段静默覆写。

**修法：** 给每次尝试配一个代号。每次 `connect()` / `disconnect()` / `dispose()` 让代际前进；任何越过 `await` 之后醒来的代码先核对代号，**过期就只关掉自己建的那条会话**，既不碰字段也不发事件。

**Files:**
- Modify: `lib/connection/connection_manager.dart`
- Test: `test/connection/connection_manager_test.dart`

- [ ] **Step 1: 写失败的用例**

在 `test/connection/connection_manager_test.dart` 的 `void main()` 内、末尾的 `}` 之前插入**两条**用例。

**先说清楚哪条会红、哪条不会**，否则 Step 2 的证据看起来会不对：

| 用例 | 修复前 | 为什么 |
|---|---|---|
| 连点两下 | **红** | 过期的那次尝试多发一个假告警，并 arm 一个重连定时器建出第三条会话，`sessions[1]` 成孤儿 |
| 连点两下（不 gate）输出隔离 | **绿**（是**钉子**，不是红用例） | 顺序的第二次 `connect()` 本来就会 `_teardownSession()` 把旧订阅取消掉。它守的是"**别把 `_teardownSession()` 从 `connect()` 里拿掉**"—— 只留令牌、不拆旧会话的写法会让它红 |

**不要**再写"建连途中用户主动断开"那一条：本文件在 `建连途中用户主动断开：不得报失败，也不得转红（FR-C-05 / §5.4）` 已经**原样覆盖**了，而且它在修复前也是绿的（`_userClosed` 那条路径本来就走得通）。重复一条只增加维护面。

第一条钉**孤儿**：

```dart
  test('连点两下 connect()：不留孤儿会话，也不发假告警', () async {
    // 真实 async（不是 fakeAsync）：这条要等第一次 connect() 被 close() 打回来。
    final sessions = <_FakeSession>[];
    final mgr = ConnectionManager(
      profile: _profile(),
      factory: _FakeFactory(sessions, failConnect: true, gate: true),
    );
    addTearDown(mgr.dispose);

    final failures = <ConnectionFailure>[];
    final reconnected = <Reconnected>[];
    mgr.events.listen((e) {
      if (e is ConnectionFailed) failures.add(e.failure);
      if (e is Reconnected) reconnected.add(e);
    });

    // 用户连点两下。第一次挂在握手中途；第二次的 connect() 会把第一条拆掉，
    // 于是第一条的 connect() 抛错 —— 而它**已经过期**，那条失败不是用户的线。
    final first = mgr.connect();
    await Future<void>.delayed(Duration.zero);
    final second = mgr.connect();
    unawaited(second); // 见下：这一条**故意不等**

    // 只有**第一次**能等到：它建的会话已经被第二次的 `_teardownSession()` 关掉，
    // 于是它的 connect() 抛错返回。
    await first;
    // 留一点时间给"万一存在的"重连定时器与在途拆除。
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // **不要 `await second`**：`gate: true` + `failConnect: true` 下，第二次建的
    // 那条会话挂在握手中途，而**没有任何东西会去关它**（它就是当下那条）。等它
    // 等于等一个永远不会到来的 gate —— 整个文件会挂到超时，而不是点名变红。
    // 夹具的 gate 只由 `close()` 打开，所以"它还开着"正是"它是当下的会话"。

    // 修复前实际是 3 条：过期那次失败还会 `_scheduleRetry()`，
    // 于是一个我们控制不了的定时器又建了第三条。
    expect(sessions, hasLength(2), reason: '两次点击只该建两条会话');

    // 断言写成"只有最后一条可以还开着"，不要写成 `closed` 全为 true —— 后者会被
    // 末尾那次 `mgr.dispose()` 的拆除变成**恒真**，看不出孤儿。
    final stillOpen = [
      for (var i = 0; i < sessions.length; i++)
        if (!sessions[i].closed) i,
    ];
    expect(
      stillOpen,
      [sessions.length - 1],
      reason: '只有当下那条可以还开着；其余都是占着设备侧一个 vty 的孤儿',
    );
    expect(failures, isEmpty, reason: '自己拆出来的失败不是用户的线，报了就是假告警');
    expect(reconnected, isEmpty, reason: '用户从没掉过线，不该有重连横幅');
  });
```

（`unawaited` 来自 `dart:async`，本文件已经 import 了。）

第二条是**钉子**：顺序的第二次 `connect()` 必须仍然把旧订阅摘掉。**它修复前后都绿**，守的是"只加令牌、把 `_teardownSession()` 从 `connect()` 里拿掉"那种改法。

```dart
  test('被取代的会话不得再往 mgr.output 里灌数据', () async {
    // 不 gate、不 fail：两条会话都真的连上，于是两条都注册过 output 订阅 ——
    // 这才是"旧订阅有没有被摘掉"唯一能被看见的形状。
    final sessions = <_FakeSession>[];
    final mgr = ConnectionManager(
      profile: _profile(),
      factory: _FakeFactory(sessions),
    );
    addTearDown(mgr.dispose);

    final received = <String>[];
    mgr.output.listen(received.add);

    await mgr.connect();
    await mgr.connect(); // 取代第一条
    await Future<void>.delayed(Duration.zero);
    expect(sessions, hasLength(2));

    // 每条会话各吐一次。夹具的 close() 刻意不关 _output，所以旧会话**还能** emit，
    // 到不到得了 mgr.output 完全取决于订阅有没有被取消。
    sessions[0].emit('out0');
    sessions[1].emit('out1');
    await Future<void>.delayed(Duration.zero);

    expect(received, ['out1'], reason: '旧会话的订阅必须已经被摘掉');
  });
```

- [ ] **Step 2: 跑用例，确认它红**

Run: `flutter test test/connection/connection_manager_test.dart`
Expected: **第一条**（`连点两下 connect()...`）点名变红，红的是**假告警**那条断言：

```
00:00 +26 -1: 连点两下 connect()：不留孤儿会话，也不发假告警 [E]
  Expected: empty
    Actual: [ConnectionFailure:ConnectionFailure(unknown): 连接失败：connect failed]
  自己拆出来的失败不是用户的线，报了就是假告警
```

**别预期 `sessions` 长度或 `stillOpen` 先红 —— 实测它们在这里是绿的。** 默认
`backoff` 首项是 **1s**，而用例只等 50ms：过期那次排的重连定时器**在这个窗口里
根本不会醒**，所以 `sessions` 就是 2 条、`stillOpen` 就是 `[1]`。上面引的
`created=3`、`closed=[true,false,false]` 来自一条**60ms 退避**的探针，形状不同，
别把两组数字当同一件事（我第一版就是这么记错的，它把这条用例的期望写成了长度断言）。

于是那两条长度断言在这里是**回归护栏**（将来谁把退避序列调短、或让过期尝试的
定时器真的跑起来，它们会接手变红）；当下钉住这个 bug 的是那条假告警断言。

**第二条（输出隔离那条）应当全绿** —— 它是钉子不是红用例（见上表）。它绿说明
`connect()` 里的 `_teardownSession()` 还在，这一步别把它当成"没红所以写错了"。

**如果整个文件挂到超时**：多半是某处 `await` 了那条**故意不等**的第二次
`connect()`（见用例里的说明）。

- [ ] **Step 3: 加字段**

在 `lib/connection/connection_manager.dart` 的私有字段区（`var _userClosed = false;` 之后）加上：

```dart
  /// **尝试代际。** 每次 [connect] / [disconnect] / [dispose] 让它前进，任何越过
  /// `await` 之后醒来的代码先核对它 —— 代号变了就说明自己**已经过期**。
  ///
  /// 存在的唯一理由是 [connect] 的重叠调用不安全（详见那里的说明）。过期的一方
  /// **只关掉自己建的那条会话**：它既不碰 `_session` / `_outputSub` / `_dispatcher`
  /// （那些现在很可能已经是后来者的），也不发事件、不排重连 —— 否则用户会看到一条
  /// 他从没掉过的线的告警。
  var _generation = 0;
```

- [ ] **Step 4: 换掉 `connect()`**

把 `connect()`（当前 `:184-235`，含它上面那一大段文档）**整段**替换为：

```dart
  /// 发起连接。用户点击设备按钮时调用（FR-C-03）。
  ///
  /// **本方法拥有它替换掉的那条会话。** 会话是在这里被换掉的，所以拆掉旧的
  /// 也是这里的责任：直接建新会话再覆写 `_session` / `_outputSub` / `_dispatcher`，
  /// 旧的既没人 `close()`、订阅也再没人取消 —— 泄漏的不是内存，而是**一条仍插在
  /// 设备上的 SSH 连接**（设备侧那个 vty 一直占着，直到它自己超时）。
  /// 重连那条路不需要这段：`_onSessionDone` 与失败分支都会在排程之前先把字段
  /// **同步**清空，定时器醒来时手里已经没有旧会话了。
  ///
  /// **重叠调用由代际令牌挡住**（`_generation`，见字段的文档）。曾经的形状是
  /// **漏拆**，别按"两次拆除互相拆台"去推理（那是我记错过的版本，实测**是错的**）：
  /// 输掉的那次尝试走进 `catch` 时字段早已被对手清空，于是它那句
  /// `unawaited(_teardownSession())` 是**空操作**；它接着发 `ConnectionFailed`、
  /// 调 `_scheduleRetry()` —— 在前一条会话**还活着**的时候武装一个重连定时器，
  /// 那个回调直接调 `_attemptConnect()`、**不经任何拆除**，把
  /// `_session` / `_outputSub` / `_dispatcher` 静默覆写，前一条会话从此没人关。
  ///
  /// 实测（真实 async，gate 型夹具，握手中途 `close()` ⇒ `connect()` 抛错，60ms 退避）：
  /// 修复前连点两下的探针给出 `created=3`、`closed=[true,false,false]` ——
  /// `sessions[2]` 是当下那条，`sessions[1]` 成了**孤儿**（一个被占住的 vty）；
  /// 再从每条会话各 emit 一次，`received=[out1,out2]`，也就是**两条**会话同时往
  /// `mgr.output` 里灌。同一次还多发了一个**假告警**（`ConnectionFailed` +
  /// `ReconnectScheduled`）和一个 `Reconnected` 横幅 —— 用户其实从没掉线。
  /// "重连尝试在途时手动 connect()"的探针给出 `created=4`、
  /// `closed=[true,true,false,false]`，同样一个孤儿。
  ///
  /// **修复前（`acdc10d`）的对照，每条探针各有自己的数字。** 原先这里写成
  /// "同两条探针"，是把**不带 gate 的 P** 与上面两条 gate 探针混为一谈，实测不符：
  /// 上面那条 gate 探针修复前是 `created=2`、`closed=[false,false]`、`received=[out1]`；
  /// B1 修复前是 `created=3`、`closed=[false,false,false]`；而**不带 gate 的连点两下**
  /// （P，也就是 I5a 那个形状）修复前才是 `created=2`、`closed=[false,false]`、
  /// `received=[out0,out1]`。所以 I5 的修复**不是**这次泄漏的来源（重叠一次就漏
  /// 一条，修之前也漏），也**没有**堵上这个洞；新出现的是那个假 `ConnectionFailed`
  /// 加 `Reconnected` 横幅。
  Future<void> connect() async {
    if (_disposed) return;
    _userClosed = false;
    // 动手之前先摘掉待命的重连定时器：手动连接一旦成功，`_attempt` 会归零，
    // 而那个定时器并不知道又有人连上了 —— 它到点照跑，会再造一条会话把刚连上
    // 的这条顶掉（`_session` 被覆写，这条就再也没人关了）。
    _retryTimer?.cancel();
    _retryTimer = null;
    // **作废所有在途的尝试。** 代际一旦前进，先前那些还挂在 await 上的
    // `_attemptConnect` 醒来时就会发现代号对不上，于是它们只关掉自己建的那条会话。
    final gen = ++_generation;
    // 已经连着时，先把旧会话拆干净再建新的，见上面的所有权说明。
    // 这个保证**只在前一次拆除没有在途时才成立**：`_teardownSession()` 在任何
    // await 之前就把字段取走并置空，所以第二次拆除对着已被清空的字段是**空操作**，
    // `connect()` 会径直往下建新会话。实测：让上一次 `close()` 悬在半路，`connect()`
    // 建出第 2 条会话时第 1 条的 `closed` 仍是 false（`created=2 closed=[false,false]`）。
    // 结局是良性的 —— 第 1 次拆除终究会关掉它自己那条会话，最终 `closed=[true,false]`，
    // 无孤儿 —— 但"已经连着（**或上一次拆除还没走完**）时都先拆干净"是**过度承诺**，
    // 别照着它推理。
    //
    // 这里 `await` 是安全的：按契约 `Session.close()` **不会**触发
    // `done`（session.dart），所以旧会话不会在拆除途中反过来走一趟 `_onSessionDone`。
    await _teardownSession();
    // 拆除期间又有人调了 connect()/disconnect()/dispose()：本次已经过期，
    // 交出去，别再往下建会话。
    if (gen != _generation) return;
    await _attemptConnect(gen);
  }
```

- [ ] **Step 5: 换掉 `_attemptConnect()`**

把 `_attemptConnect()`（当前 `:237-315`）**整段**替换为：

```dart
  Future<void> _attemptConnect(int gen) async {
    if (_disposed || _userClosed || gen != _generation) return;

    _setState(
      _attempt == 0
          ? DeviceConnectionState.connecting
          : DeviceConnectionState.reconnecting,
    );

    final session = factory.create(profile);
    _session = session;

    try {
      await session.connect();
    } catch (e) {
      if (_disposed) return;
      // **本次尝试已被后一次取代**（用户又点了一下，或重连定时器与手动连接撞上）。
      // 只关自己这一条：`_teardownSession()` 拆的是**字段里**的会话，而字段现在
      // 很可能已经是后来者的了 —— 那正是这条路径当初的洞（输掉的一方把赢的一方
      // 拆掉，或者谁都没拆而留下一条占着 vty 的孤儿）。
      if (gen != _generation) {
        unawaited(session.close());
        return;
      }
      // 不 await：拆除是清理，不能挡住重连排程。_teardownSession 会在任何
      // await 之前同步清空 _session/_outputSub 等状态，所以 fire-and-forget
      // 不会与随后的重连串到一起去。
      unawaited(_teardownSession());
      // 用户已断开或应用已退出：这次失败是我们自己关掉 socket 造成的。
      // 报给用户就是假告警，改状态则会让按钮从灰变红（§5.4 要求是灰的）。
      if (_userClosed) return;
      if (!_events.isClosed) {
        _events.add(ConnectionFailed(classifyConnectionFailure(e)));
      }
      _scheduleRetry(gen);
      return;
    }

    if (_disposed || _userClosed || gen != _generation) {
      // 建连期间用户断开/退出/又有人连了：关掉**自己这条**，不进入已连接状态。
      // 同样不能走 `_teardownSession()`（理由见上）。`identical` 那一句是必须的：
      // 字段可能已经被后来者填上了它自己的会话，那不是我们的。
      await session.close();
      if (identical(_session, session)) _session = null;
      return;
    }

    // `onError` 是保险，不是通道：两个真实实现都把 output 上的错误转成了 `done`
    // 的**完成**（`_onError` → `_onDisconnected`），output 本身不会以错误结束。
    // 真要有错误漏到这里，它是**静默**吞掉的 —— 没有事件、没有日志、没有状态
    // 变化，所以别指望它能报信。
    _outputSub = session.output.listen((chunk) {
      if (!_output.isClosed) _output.add(chunk);
      _dispatcher?.onOutput(chunk);
    }, onError: (Object _) {});

    _dispatcher = CommandDispatcher(
      write: session.write,
      promptDetector: promptDetector ?? PromptDetector(),
      morePager: morePager ?? MorePager(),
      lineEnding: profile.lineEnding,
    );
    // `done` **不会**以错误完成（两个实现都只 `complete()`，不带参数），所以这里
    // **不接** `onError:` —— 那条分支永远不会执行，而它读起来像"断开原因就是从
    // 这儿传下去的"，比没有更糟。原因走 [Session.lastError]：`done` 完成之后再读，
    // 此时它一定已经写好（两个实现的 `_onDisconnected` 都是先存再 `complete()`，
    // spec §13.12 / §13.20）。
    // 代号随会话一起捕获：这条会话的落幕只对它自己那一代有效。
    session.done.then((_) => _onSessionDone(gen, session.lastError));

    final wasReconnect = _attempt > 0;
    if (wasReconnect) {
      // 用 clock.now() 而不是 DateTime.now()：fake_async 推进的是 clock，
      // 用真实时间会让 FR-C-09 的断线时长在测试里恒为 0。
      final downtime = clock.now().difference(_disconnectedAt);
      if (!_events.isClosed) _events.add(Reconnected(downtime, _attempt));
    }
    if (!_events.isClosed) _events.add(SessionReady(_dispatcher!));

    // 退避计数在**连接成功**时归零：FR-C-07 的 1→2→4→… 描述的是
    // "一直连不上时等多久"，不是"这台设备历史上断过几次"。一台能连上、
    // 只是偶尔掉线的设备，每次都应该 1s 后就重连，而不是无限升级到 30s。
    _attempt = 0;
    _setState(DeviceConnectionState.connected);

    // FR-C-08：连接成功后自动下发登录后命令。追加到队列尾部，
    // 因此用户此时发出的命令会排在其后。
    if (profile.postLoginCommands.isNotEmpty) {
      _dispatcher!.enqueue(profile.postLoginCommands);
    }
  }
```

- [ ] **Step 6: 换掉 `_onSessionDone()` 与 `_scheduleRetry()`**

把 `_onSessionDone()`（当前 `:320-335`）整段替换为：

```dart
  /// [error] 只有一个来源：`session.done` 完成之后读到的 `session.lastError`。
  /// 形参**不再是可选的** —— 可选会让人以为还有别的调用点（原先那条 `onError:`
  /// 已经删掉，见上面注册处）。
  ///
  /// [gen] 是那条会话所属的代际。**代号对不上就直接返回**：这次落幕属于一条
  /// 已经被取代的会话（用户在它还活着的时候又连了一次），既不该拆字段里的会话，
  /// 也不该发 `SessionLost` —— 那会让用户看到一条他从没掉过的线。
  void _onSessionDone(int gen, Object? error) {
    if (_disposed || _userClosed || gen != _generation) return;
    _disconnectedAt = clock.now();

    // FR-C-10：未发出的命令一律丢弃，不自动重放。
    // onDisconnected 会把在途的那条也计入丢弃数 —— 它的输出永远收不到了。
    _dispatcher?.onDisconnected();
    _teardownSession();

    if (!_events.isClosed) {
      _events.add(
        SessionLost(error == null ? null : classifyConnectionFailure(error)),
      );
    }
    _scheduleRetry(gen);
  }
```

把 `_scheduleRetry()`（当前 `:337-363`）整段替换为：

```dart
  void _scheduleRetry(int gen) {
    // 用户主动断开或应用退出：状态已由 disconnect()/dispose() 定好，
    // 这里再改一次就会把按钮从灰刷成红（§5.4 要求灰色）。
    // 代号对不上同理：这次失败属于一条已被取代的尝试，它无权安排下一次。
    if (_disposed || _userClosed || gen != _generation) return;

    if (!autoReconnect) {
      _setState(DeviceConnectionState.failed);
      return;
    }

    _setState(DeviceConnectionState.reconnecting);
    _attempt++;

    // 超出序列时用最后一项（封顶，FR-C-07）。
    final delay =
        backoff[_attempt - 1 < backoff.length
            ? _attempt - 1
            : backoff.length - 1];

    if (!_events.isClosed) _events.add(ReconnectScheduled(_attempt, delay));

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      // 定时器醒来时代号仍要核对：`connect()` / `disconnect()` / `dispose()`
      // 都会取消它，但"取消"与"已经排在事件队列里"之间没有原子性 —— 多核这一
      // 行是廉价的。
      if (_disposed || _userClosed || gen != _generation) return;
      unawaited(_attemptConnect(gen));
    });
  }
```

- [ ] **Step 7: 在 `disconnect()` 与 `dispose()` 里推进代际**

把 `disconnect()`（当前 `:365-376`）里的开头几句改成：

```dart
  Future<void> disconnect() async {
    _userClosed = true;
    // **作废在途的尝试与已排程的重连。** 它们醒来时会发现代号对不上，于是只关掉
    // 自己建的那条会话 —— 不会再改状态、不会再发事件、也不会再建新会话。
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _attempt = 0;
    // 立即置为已断开：用户点了"断开"，按钮就该马上变灰，而不是等拆除
    // 流程走完（关闭 socket 可能要等对端响应）。state 是同步可读的，
    // 界面下一帧就会看到。
    _setState(DeviceConnectionState.disconnected);
    await _teardownSession();
  }
```

把 `dispose()`（当前 `:378-391`）里的开头几句改成：

```dart
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _userClosed = true;
    // `_disposed` 已经能挡住所有路径，这一行是纵深防御：将来若有谁把在途尝试的
    // 守卫写成只看 `_userClosed`，代际仍然兜得住。
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _teardownSession();
    await _events.close();
    await _output.close();
  }
```

- [ ] **Step 8: 跑用例，确认全绿**

Run: `flutter test test/connection/connection_manager_test.dart`
Expected: 全部通过（原有的 26 条 + 本任务新增 2 条 = 28 条）。

**如果退避那条用例（`连续建连失败按 1s -> 2s -> 4s 退避`）变红**，说明代际在重连路径上被误伤：`_scheduleRetry(gen)` 的 `gen` 与 `_attemptConnect(gen)` 的 `gen` **必须是同一个**（重连属于同一次尝试代际），别在某处写成了 `_generation`。

- [ ] **Step 9: 提交**

```bash
git add lib/connection/connection_manager.dart test/connection/connection_manager_test.dart
git commit -m "$(cat <<'EOF'
fix(connection): connect() 重叠调用加代际令牌，堵掉漏拆与孤儿会话

FR-C-03 要求点击设备按钮即发起连接，所以这把 connect() 接到了用户手势上；
而重叠调用原先不安全：输掉的那次走进 catch 时字段已被对手清空，它那句
unawaited(_teardownSession()) 成了空操作，接着又发假告警并 arm 一个重连定时器，
定时器回调不经任何拆除就覆写字段 —— 前一条会话从此没人关（实测 created=3、
closed=[true,false,false]，孤儿占着一个 vty）。

修法是给每次尝试配代号：任何越过 await 之后醒来的代码先核对，过期就只关掉
自己建的那条会话，既不碰字段也不发事件。connect/disconnect/dispose 都推进代际。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `ansi_parser` 的流式接续（`parseAnsiChunk` / `ansiHoldBackLength`）

**为什么：** `parseAnsi` / `stripToPlainText` **每次调用独立**，不保留跨调用状态。设备把一条控制序列分开发（`'\x1b['` + `'31mred'`）时，两边都会把前半个序列当字面文本留下 —— 输出区会显示 `[31m` 这种东西。Task 5 的输出缓冲要正确渲染就得**留住**那半条，而"留住"这件事只有解析器自己说得准。同时：样式必须**跨块延续**，否则 `'\x1b[32m'` 与紧随其后的文本分属两块时颜色会丢 —— 这需要一个能给出**块末样式**的入口（`spans.last.style` 不行：输入以 `'\x1b[32m'` 结尾时**一个片段都没有**，而样式已经是绿的）。

**Files:**
- Modify: `lib/render/ansi_parser.dart`
- Test: `test/render/ansi_stream_test.dart`（新建）

- [ ] **Step 1: 写失败的用例**

创建 `test/render/ansi_stream_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/render/ansi_parser.dart';

void main() {
  group('ansiHoldBackLength', () {
    test('不含 ESC 时不留尾巴', () {
      expect(ansiHoldBackLength('hello\nworld'), 0);
    });

    test('末尾是完整的 CSI 时不留尾巴', () {
      expect(ansiHoldBackLength('a\x1b[31mb'), 0);
    });

    test('末尾是半条 CSI 时留到那个 ESC', () {
      // 这条输入正是"设备把一条序列分开发"的前半截。
      expect(ansiHoldBackLength('a\x1b['), 2);
      expect(ansiHoldBackLength('a\x1b[3'), 3);
      expect(ansiHoldBackLength('a\x1b[38;5;'), 7);
    });

    test('末尾是裸露的 ESC 时留 1', () {
      expect(ansiHoldBackLength('abc\x1b'), 1);
    });

    test('末尾是半条 OSC 时留到那个 ESC', () {
      // OSC 的终止符是 BEL 或 ST（ESC \\）；没等到就是还没完。
      expect(ansiHoldBackLength('\x1b]0;标题'), 6);
      expect(ansiHoldBackLength('\x1b]0;标题\x07'), 0);
    });

    test('OSC 的 ST 终止符本身是一个完整的 ESC 序列', () {
      // 只看**最后一个** ESC 就够，靠的就是这条：序列之间不嵌套。
      expect(ansiHoldBackLength('\x1b]0;t\x1b\\'), 0);
    });

    test('ESC 后跟的不是 [ 或 ] 时，判定已经做出，不留尾巴', () {
      // `\x1b(B`（选择字符集）解析器刻意不剥离（既有用例钉着），但它也**不会**
      // 因为后续输入而改判 —— ESC 处的判定只取决于下一个字符。
      expect(ansiHoldBackLength('a\x1b(B'), 0);
      // 真正的两字节序列（ESC + `@`-`Z` / `\]^_`）同理：已经完整。
      expect(ansiHoldBackLength('a\x1bM'), 0);
    });

    test('半条序列比 kMaxAnsiHoldBack 还长时不再留（免得永久卡住）', () {
      // 一条永远等不到后半截的畸形序列不得把输出区卡死：
      // 超过上限就当作普通文本放行。
      final pathological = '\x1b[${'1' * (kMaxAnsiHoldBack + 10)}';
      expect(ansiHoldBackLength(pathological), 0);
      expect(ansiHoldBackLength(pathological).isNegative, isFalse);
    });

    test('留住的长度永不超过 kMaxAnsiHoldBack', () {
      final long = '\x1b[' + '1' * (kMaxAnsiHoldBack * 3);
      expect(ansiHoldBackLength(long), lessThanOrEqualTo(kMaxAnsiHoldBack));
    });
  });

  group('parseAnsiChunk', () {
    test('返回的 finalStyle 是输入走完时的样式', () {
      final r = parseAnsiChunk('\x1b[32m');
      expect(r.spans, isEmpty, reason: '只有样式、没有文本时不该产出片段');
      expect(r.finalStyle.foreground, const AnsiBasic(2));
    });

    test('finalStyle 与 spans.last.style 不是一回事', () {
      // 这正是要单开一个入口的理由：`spans.last.style` 会给出**上一段文本**的
      // 样式，而输入末尾那次换色就丢了。
      final r = parseAnsiChunk('\x1b[32mgreen\x1b[31m');
      expect(r.spans.single.text, 'green');
      expect(r.spans.single.style.foreground, const AnsiBasic(2));
      expect(r.finalStyle.foreground, const AnsiBasic(1));
    });

    test('分两块喂（样式接续）与一次喂得到同样的结果', () {
      const whole = 'a\x1b[32mgreen\x1b[0mb';
      final oneShot = parseAnsi(whole);

      final first = parseAnsiChunk('a\x1b[32mgre');
      final second = parseAnsiChunk('en\x1b[0mb', initial: first.finalStyle);
      final twoShot = [...first.spans, ...second.spans];

      expect(
        twoShot.map((s) => s.text).join(),
        oneShot.map((s) => s.text).join(),
      );
      // **按字符比样式，不按片段比。** 块边界落在同一段同样式文本中间时（这里
      // green 被切成 'gre' + 'en'），两次调用各自在块末 `flush()`，所以片段边界
      // 必然不同 —— `AnsiParseResult` 只带 spans + finalStyle，没有跨调用状态能把
      // 它们并回一段，这是设计如此（渲染上相邻同色片段本来就等价）。承重的不变量
      // 是"每个字符的样式一致"，不是"片段切法一致"。
      //
      // **原先这里比的是 `twoShot.map((s) => s.style).toList()`，那条断言无解**：
      // 实测一次性喂是 3 段 `[none, green, none]`，分两块喂是 4 段
      // `[none, green, green, none]` —— 长度都不等。Task 4 的实现者照做跑红之后
      // 停下来报告，没有把断言改软。
      List<AnsiStyle> perChar(Iterable<AnsiSpan> spans) =>
          [for (final s in spans) ...List.filled(s.text.length, s.style)];
      expect(perChar(twoShot), perChar(oneShot));
    });

    test('parseAnsi 就是 parseAnsiChunk 的片段那一半', () {
      const input = '\x1b[1;31mred\x1b[0m plain';
      expect(parseAnsi(input), parseAnsiChunk(input).spans);
    });
  });
}
```

- [ ] **Step 2: 跑用例，确认它红**

Run: `flutter test test/render/ansi_stream_test.dart`
Expected: 编译失败（`ansiHoldBackLength` / `parseAnsiChunk` / `kMaxAnsiHoldBack` / `AnsiParseResult` 未定义）—— 这是**编译错**，不是点名用例红。这一步的"红"就是编译不过，可以接受。

- [ ] **Step 3: 改实现**

在 `lib/render/ansi_parser.dart` 里，把 `parseAnsi` 的**签名与结尾**改掉，函数体**原样不动**。

当前签名（`:215`）：

```dart
List<AnsiSpan> parseAnsi(String input, {AnsiStyle initial = AnsiStyle.none}) {
```

改成：

```dart
AnsiParseResult parseAnsiChunk(String input, {AnsiStyle initial = AnsiStyle.none}) {
```

当前结尾（`:297-300`）：

```dart
  flush();
  emitRun();
  return spans;
}
```

改成：

```dart
  flush();
  emitRun();
  return AnsiParseResult(spans, style);
}

/// [parseAnsiChunk] 的结果，多带一个**块末样式**。
///
/// 流式调用方（输出缓冲）必须把 [finalStyle] 接给下一块，否则 `'\x1b[32m'`
/// 与紧随其后的文本分属两块时颜色会丢。
class AnsiParseResult {
  const AnsiParseResult(this.spans, this.finalStyle);

  final List<AnsiSpan> spans;

  /// 输入走完时的当前样式。
  ///
  /// **它与 `spans.last.style` 不是一回事**：输入以 `'\x1b[32m'` 结尾时
  /// `spans` 是空的，而样式已经是绿的。照 `spans.last` 取会丢掉末尾那次换色。
  final AnsiStyle finalStyle;
}

/// 剥离控制符之外什么都不做，返回样式片段。
///
/// 等同于 `parseAnsiChunk(input, initial: initial).spans` —— 保留这个名字是因为
/// 一次性调用的地方（日志、测试）读起来更直接，且它保证了 [stripToPlainText]
/// 与 `parseAnsi` 走的是同一条实现路径。
List<AnsiSpan> parseAnsi(String input, {AnsiStyle initial = AnsiStyle.none}) =>
    parseAnsiChunk(input, initial: initial).spans;

/// 一条不完整的控制序列最多可能有多长。
///
/// 超过它就不再往回找：一段永远等不到后半截的畸形字节不该把输出区**永久**卡住。
/// 64 远大于现实里任何一条序列（CSI 参数很少超过 20 字符）。
const int kMaxAnsiHoldBack = 64;

/// [input] 的末尾有多少个字符必须**留在缓冲里**等下一块 —— 因为从某个 `\x1b`
/// 开始的控制序列可能还没收完。
///
/// 存在的理由只有一个，见 [parseAnsiChunk] 上面那段前提：解析**每次调用独立**，
/// 把 `'\x1b['` 与 `'31mred'` 分两次喂，前半个序列会退化成字面文本。输出区要
/// 正确渲染就得留住它，而日志要与输出区一致就得从**同一处缓冲**取文本 —— 所以
/// 这个判断属于"两边共用的那处缓冲"，不属于渲染。
///
/// **只看最后一个 `\x1b`。** 控制序列之间不会嵌套（OSC 的 ST 终止符 `ESC \`
/// 自己就是一条完整的两字节序列），所以更早的 ESC 若已经收完，就不可能被末尾的
/// 半条影响。
///
/// **返回 0 是常态**：输入里没有控制序列，或末尾那条已经完整。
int ansiHoldBackLength(String input) {
  final lowerBound = input.length - kMaxAnsiHoldBack;
  for (var i = input.length - 1; i >= 0 && i >= lowerBound; i--) {
    if (input.codeUnitAt(i) != 0x1b) continue;
    return _isCompleteSequenceAt(input, i) ? 0 : input.length - i;
  }
  return 0;
}

/// 从 [i] 处的 `\x1b` 起，后续输入**还能不能**改变它的含义 —— 不能就是"已经完整"。
///
/// 判据直接照抄 `parseAnsiChunk` 的优先级顺序（`:265-294`）：ESC 处的判定**只**
/// 取决于下一个字符。所以三种情况：下一个字符是 `[` / `]` 时序列可能还没收完
/// （要 `_matchCsi` / `_matchOsc` 说有才算完）；其余情况**此刻已经定死**，
/// 后续输入改不了它 —— 包括"ESC 被当普通字符留下"这种结局。
bool _isCompleteSequenceAt(String input, int i) {
  final next = i + 1;
  if (next >= input.length) {
    // 末尾裸露的 ESC：解析器**确实**会把它当普通字符留下，但下一块一来它就可能
    // 变成序列的开头 —— 含义**还能**变，所以是"不完整"。留 1 个字符。
    return false;
  }
  if (input.codeUnitAt(next) == 0x5b /* [ */) {
    return _matchCsi(input, i) != null;
  }
  if (input.codeUnitAt(next) == 0x5d /* ] */) {
    return _matchOsc(input, i) != null;
  }
  // 走到这里说明下一个字符既不是 `[` 也不是 `]`。判定已经定死，于是"完整"。
  //
  // **这里原先写的是 `return _isTwoByteFinal(...)`，那是错的**（Task 4 的实现者
  // 先按原文照做、跑出 `'a\x1b(B'` 得 3 而不是 0，然后停下来报告，没有擅自改）：
  // `\x1b(` 后面跟普通字符时它判"不完整"，于是把**已经定死的字面文本**一直扣在
  // 缓冲里 —— 设备此后不再发数据的话，那段文本要等缓冲涨过 kMaxAnsiHoldBack 才
  // 放行，在此之前**不显示**。这不是期望写错，是实现写错。
  return true;
}
```

- [ ] **Step 4: 跑用例，确认全绿**

Run: `flutter test test/render/ansi_stream_test.dart`
Expected: 全部通过（13 条）。

- [ ] **Step 5: 跑一遍既有的解析器用例，确认没被碰坏**

Run: `flutter test test/render/ansi_parser_test.dart`
Expected: 全部通过。`parseAnsi` 的行为**一个字都没变**（只是多了一层壳），所以这里必须**一条都不红**；红了就说明函数体被改动了。

- [ ] **Step 6: 提交**

```bash
git add lib/render/ansi_parser.dart test/render/ansi_stream_test.dart
git commit -m "$(cat <<'EOF'
feat(render): 解析器支持流式接续（parseAnsiChunk / ansiHoldBackLength）

parseAnsi 每次调用独立，设备把一条控制序列分开发（'\x1b[' + '31mred'）时
前半个序列会退化成字面文本。输出区要正确渲染就得留住那半条，而日志要与输出区
一致就得从同一处缓冲取文本 —— 所以这两个判断属于共用的缓冲。

parseAnsiChunk 另外给出块末样式：spans.last.style 在"输入以换色结尾"时是错的
（那时一个片段都没有，而样式已经变了）。parseAnsi 变成它的一层壳，行为不变。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `OutputBuffer` —— 输出区与日志的唯一来源

**为什么：** §5.6 要求「日志与输出区所见一致」。计划 4 已经把两边收敛到同一套剥离规则，但留了一个**前提**：必须按**同样的边界**喂。两边各自攒各自的缓冲，就必然有一边踩上"半条控制序列"那个坑。这个类把"边界"这件事收到一处：**它持有唯一的缓冲**，日志从它拿到的文本与之逐字相同。

**Files:**
- Create: `lib/state/output_buffer.dart`
- Test: `test/state/output_buffer_test.dart`

- [ ] **Step 1: 写失败的用例**

创建 `test/state/output_buffer_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/render/ansi_parser.dart';
import 'package:win_cli_tool/state/output_buffer.dart';

void main() {
  late List<String> logged;
  late OutputBuffer buffer;

  OutputBuffer make({int maxLines = 5000}) {
    final b = OutputBuffer(maxLines: maxLines);
    b.onText = logged.add;
    return b;
  }

  setUp(() {
    logged = <String>[];
    buffer = make();
  });

  /// 把各行拼回一个字符串，供"文本内容"断言。
  String textOf(List<List<AnsiSpan>> lines) => lines
      .map((line) => line.map((s) => s.text).join())
      .join('\n');

  group('分块', () {
    test('没有换行的输入留在同一行里', () {
      buffer.add('abc');
      expect(buffer.lines, hasLength(1));
      expect(textOf(buffer.lines), 'abc');
    });

    test('换行把内容切开，并在末尾留下一个未完成的行', () {
      buffer.add('a\nb\n');
      expect(textOf(buffer.lines), 'a\nb\n');
      expect(buffer.lines, hasLength(3), reason: '末尾的空行是"下一行还没开始"');
    });

    test('跨块的一行会接起来', () {
      buffer.add('hel');
      buffer.add('lo\n');
      expect(textOf(buffer.lines), 'hello\n');
    });
  });

  group('日志与输出区同一边界', () {
    test('喂给 onText 的文本与喂给解析器的逐字相同', () {
      const chunk = 'a\x1b[31mred\x1b[0m\n';
      buffer.add(chunk);
      expect(logged, [chunk]);
      expect(textOf(buffer.lines), 'ared\n');
    });

    test('半条控制序列被留住，两边都不吃它', () {
      buffer.add('a\x1b[');
      // 喂给日志的是**本次完整的那一段**，边界正好落在半条序列之前 ——
      // 所以这里不是 `isEmpty`：`'a'` 是完整的、该进日志；`'\x1b['` 被留住。
      expect(logged, ['a']);
      expect(textOf(buffer.lines), 'a');

      buffer.add('31mred');
      expect(
        logged,
        ['a', '\x1b[31mred'],
        reason: '等到了后半截，于是这半条与它的前半截**一次完整地**喂下去',
      );
      expect(textOf(buffer.lines), 'ared', reason: '整条序列都被吃掉了');
      expect(
        // `lines.first` 此时有**两个**片段（无色 'a' + 红色 'red'），
        // 所以取 `.last` 而不是 `.single`。
        buffer.lines.first.last.style.foreground,
        const AnsiBasic(1),
        reason: '留在缓冲里是对的：接起来之后红色才认得出来',
      );
    });

    test('样式跨块延续（否则分块会丢颜色）', () {
      buffer.add('\x1b[32m');
      expect(logged, ['\x1b[32m']);
      buffer.add('green');
      expect(
        buffer.lines.first.single.style.foreground,
        const AnsiBasic(2),
        reason: '块末样式必须接给下一块 —— spans.last.style 在这里给不出来',
      );
    });
  });

  group('flush', () {
    test('放出残留的尾巴，并同样喂给日志', () {
      buffer.add('a\x1b[');
      expect(logged, ['a'], reason: '前半截进过一次');

      buffer.flush();

      // flush 把残留的 `'\x1b['` 也喂下去：它是一条永远等不到后半截的畸形序列，
      // 按字面文本处理 —— 与 `parseAnsi` 对它的处置一致。
      expect(logged, ['a', '\x1b[']);
      expect(textOf(buffer.lines), 'a\x1b[');
    });

    test('没有残留时什么都不做', () {
      buffer.add('done\n');
      logged.clear();
      buffer.flush();
      expect(logged, isEmpty);
    });
  });

  group('行数上限（FR-O-07）', () {
    test('超出上限时丢掉最旧的行', () {
      final b = make(maxLines: 3);
      b.onText = logged.add;
      b.add('1\n2\n3\n4\n5\n');
      expect(textOf(b.lines), '3\n4\n5\n');
    });

    test('上限为 0 或负数时至少留一行（否则 add 会抛）', () {
      final b = OutputBuffer(maxLines: 0);
      b.add('a\nb\n');
      expect(b.lines, isNotEmpty);
    });
  });

  group('clear（FR-O-05）', () {
    test('清掉显示内容，但日志一点都不受影响', () {
      buffer.add('before\n');
      logged.clear();
      buffer.clear();
      expect(textOf(buffer.lines), '');
      expect(logged, isEmpty, reason: '清屏只清显示内容，不动日志');
    });

    test('不清解析状态：清屏后的样式与半条序列仍然接得上', () {
      buffer.add('\x1b[32m');
      buffer.clear();
      buffer.add('after');
      expect(
        textOf(buffer.lines),
        'after',
        reason: '半条序列与样式是解析状态，不是"显示内容"',
      );
      expect(
        buffer.lines.first.single.style.foreground,
        const AnsiBasic(2),
      );
    });
  });

  group('addMarker', () {
    test('自占一行，且不进日志', () {
      buffer.add('cmd\n');
      logged.clear();
      buffer.addMarker('--- 连接断开 ---');
      // **这条断言必须在下面那句 `add` 之前。** 原文把它写在最后，而 `add` 会把
      // `'next\n'` 喂进日志（`onText` 一直是挂着的），于是 `expect(logged, isEmpty)`
      // **永远不可能成立** —— 它钉的不是"标记不进日志"，而是"这之后什么都不许进
      // 日志"，而后者本来就是假的。
      expect(logged, isEmpty, reason: '日志有它自己的一套标记（LogWriter 负责）');

      buffer.add('next\n');
      expect(textOf(buffer.lines), 'cmd\n--- 连接断开 ---\nnext\n');
      expect(logged, ['next\n'], reason: '标记之后的设备输出照常进日志');
    });

    test('带上样式', () {
      buffer.addMarker('warn', style: const AnsiStyle(foreground: AnsiBasic(3)));
      final marker = buffer.lines[buffer.lines.length - 2].single;
      expect(marker.text, 'warn');
      expect(marker.style.foreground, const AnsiBasic(3));
    });
  });
}
```

- [ ] **Step 2: 跑用例，确认它红**

Run: `flutter test test/state/output_buffer_test.dart`
Expected: 编译失败（`package:win_cli_tool/state/output_buffer.dart` 不存在）。这是预期的红。

- [ ] **Step 3: 写实现**

创建 `lib/state/output_buffer.dart`：

```dart
import 'dart:collection';

import '../render/ansi_parser.dart';

/// 一台设备的输出缓冲：把流式到达的块攒成**按行分组**的样式片段。
///
/// **它是这条流唯一的消费者。** 输出区要的样式片段与日志要的纯文本都从这里
/// 出来 —— 见 [parseAnsiChunk] 的前提：解析每次调用独立，一条控制序列被切开
/// 分两次喂就会退化成字面文本。两处各攒各的缓冲，就必然有一处（或两处）踩上；
/// 从同一处取则**构造上**不可能不一致，§5.6 因此不靠约定维持。
///
/// 生命周期：活得比一次会话长。FR-O-09 要求切换设备后切回来还能看到完整的输出，
/// 而 `ConnectionManager` 会在重连时换掉整个会话 —— 所以它由状态层持有，
/// 会话只往里灌数据。
class OutputBuffer {
  OutputBuffer({required this.maxLines});

  /// 保留的最大行数（FR-O-07，取 `AppSettings.outputBufferLines`，默认 5000）。
  final int maxLines;

  /// 已定型的行为单位。**最后一项是正在累积的那一行**（可能为空）。
  final List<List<AnsiSpan>> _lines = [<AnsiSpan>[]];

  /// 还没能定型的尾巴 —— 可能是一条半的控制序列。
  String _pending = '';

  /// 块末样式。必须跨块延续，否则 `'\x1b[32m'` 与紧随其后的文本分属两块时
  /// 颜色会丢（那时 `spans` 是空的，`spans.last.style` 给不出任何东西）。
  AnsiStyle _style = AnsiStyle.none;

  /// 每喂进一段**完整**文本时回调一次，参数与喂给 [parseAnsiChunk] 的**逐字
  /// 相同**。日志挂在这里，于是"日志与输出区所见一致"不是约定而是同一份入参。
  ///
  /// **每次会话开始时换上新的、结束时置空** —— 日志是"一次会话一个实例"
  /// （`LogWriter` 的文档），而本缓冲活得比一次会话长。置空期间攒下的输出
  /// 不会进日志，这是有意的：那段时间本来就没有会话在写日志。
  void Function(String text)? onText;

  /// 当前所有行（含未完成的那一行）。**是活视图**：不要改它，也不要长期持有。
  List<List<AnsiSpan>> get lines => UnmodifiableListView(_lines);

  /// 喂进一块。块边界**不必**与任何东西对齐 —— 半条控制序列会被留住。
  void add(String chunk) {
    if (chunk.isEmpty) return;
    final input = _pending + chunk;
    // 留住的尾巴**不喂给日志**，于是两边的边界逐字相同（见类的说明）。
    final hold = ansiHoldBackLength(input);
    final complete = input.substring(0, input.length - hold);
    _pending = input.substring(input.length - hold);
    if (complete.isEmpty) return;
    _consume(complete);
  }

  /// 放出残留的尾巴。会话结束/断开时调用。
  ///
  /// 残留多半是一条永远等不到后半截的畸形序列，按字面文本处理 —— 与
  /// [parseAnsi] 对它的处置一致。
  void flush() {
    final rest = _pending;
    if (rest.isEmpty) return;
    _pending = '';
    _consume(rest);
  }

  /// 往输出区插一段**不由会话产生**的文本（断开/重连标记、命令超时告警行）。
  ///
  /// **不回调 [onText]。** 那是有意的：日志有它自己的一组标记
  /// （`LogWriter.disconnected()` / `reconnected()`，§5.6 逐字规定），
  /// 两处的内容本就不同，让这些标记也进日志会把 §5.6 的格式弄脏。
  ///
  /// 标记自占一行：接在未完成的那一行后面会让人以为它是设备输出。
  void addMarker(String text, {AnsiStyle style = AnsiStyle.none}) {
    // 当前那一行**还是空的就写在它上面**：设备的输出常常以换行结束（此刻光标
    // 正停在一个空行的开头），无条件另起一行会在每次断开时都多插一个空行。
    // 反过来，半行输出后面直接接标记会让人以为标记也是设备输出 —— 所以非空时
    // 才另起一行。
    if (_lines.last.isNotEmpty) _lines.add(<AnsiSpan>[]);
    _lines.last.add(AnsiSpan(text, style));
    // 标记之后另起一行，后续输出不会接在它后面。
    _lines.add(<AnsiSpan>[]);
    _trim();
  }

  /// 清屏（FR-O-05）：**只清显示内容**。
  ///
  /// **不清 [_pending] 与 [_style]。** 清屏时流还在继续，丢掉半条序列会让紧随
  /// 其后的那半截变成字面文本，丢掉样式会让后续文本用错颜色 —— 这两样都是
  /// **解析状态**，不是"显示内容"。也不动日志（`onText` 根本不被调用）。
  void clear() {
    _lines
      ..clear()
      ..add(<AnsiSpan>[]);
  }

  void _consume(String complete) {
    final result = parseAnsiChunk(complete, initial: _style);
    _style = result.finalStyle;
    _append(result.spans);
    // 顺序是承重的：先让**这一次**的片段落进缓冲，再通知日志。反过来的话，
    // 日志里出现的一行在输出区还看不到，两者会出现一帧的错位。
    onText?.call(complete);
  }

  void _append(List<AnsiSpan> spans) {
    for (final span in spans) {
      final parts = span.text.split('\n');
      for (var i = 0; i < parts.length; i++) {
        // 第一个分段接在当前行后面，其后每段都意味着"上一条换行符到了"。
        if (i > 0) _lines.add(<AnsiSpan>[]);
        if (parts[i].isNotEmpty) {
          _lines.last.add(AnsiSpan(parts[i], span.style));
        }
      }
    }
    _trim();
  }

  void _trim() {
    // **`maxLines + 1` 里的那个 +1 是 [_lines] 的形状带来的，不是笔误。**
    // `_lines.last` 永远是"正在累积、可能还是空的那一行"，所以它**不算**一行输出。
    // 只留 `maxLines` 个元素的话，用户把上限设成 5000 实际只看到 4999 行完整输出
    // —— 差一行不致命，但它是那种"看着像对的"错。
    //
    // 下限兜到 2（=1 行输出 + 那一行在途）：`maxLines` 是设置里的值，用户把它
    // 写成 0 或负数不该让 `_lines` 空掉、下一次 `add` 直接抛。
    final keep = maxLines < 1 ? 2 : maxLines + 1;
    if (_lines.length > keep) {
      _lines.removeRange(0, _lines.length - keep);
    }
  }
}
```

- [ ] **Step 4: 跑用例，确认全绿**

Run: `flutter test test/state/output_buffer_test.dart`
Expected: 全部通过（14 条）。

- [ ] **Step 5: 提交**

```bash
git add lib/state/output_buffer.dart test/state/output_buffer_test.dart
git commit -m "$(cat <<'EOF'
feat(state): OutputBuffer —— 输出区与日志的唯一文本来源

§5.6 要求两边所见一致。计划 4 已把规则收敛到同一套，但留了"必须按同样的边界喂"
这个前提：各自攒缓冲就必然有人踩上半条控制序列那个坑。这里把边界收到一处 ——
半条序列留住不喂给日志，等齐了再一次喂下去，两边逐字相同。

另外带上 addMarker（断开/重连标记、告警行，不进日志，因为 LogWriter 有自己的一套）
与 clear（FR-O-05：只清显示，不动日志，也不清解析状态）。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 引入依赖 + 唯一的 store 集合

**为什么：** spec §8.5 点名 `flutter_riverpod` 3.4.3 与 `path_provider` 2.1.6；NFR-P-04 要求应用数据目录按平台惯例。而 `AppStores` 是把"每个文件只有一个 store 实例"从**纪律**变成**构造**的地方 —— Task 1/2 已经让两个 store 各自不再依赖实例状态，但装配层仍然只该建一份：少一份状态就少一类跨实例的推理。

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/state/app_paths.dart`、`lib/state/app_stores.dart`
- Test: `test/state/app_stores_test.dart`

- [ ] **Step 1: 加依赖**

Run: `flutter pub add --offline flutter_riverpod path_provider`

**`--offline` 不是可选项，是量出来的。** 不加它，pub 要向 pub.dev 取版本列表，
而这台机器的网络不可靠（仓库连 git remote 都没有配）。加了它 pub 只从本地缓存
解析，而这条命令**已经实测成功**：`flutter pub add --offline --dry-run
flutter_riverpod path_provider` 退出码 0，"Would change 29 dependencies"，
其中 `path_provider 2.1.6`、`path_provider_linux 2.2.2`、
`path_provider_windows 2.3.0`、`path_provider_platform_interface 2.1.3`、
`xdg_directories 1.1.0`、`plugin_platform_interface 2.1.8`、`riverpod 3.4.3`
都是缓存里现成的。

顺带它还**正合规格**：spec §8.5 点名 3.4.3 与 2.1.6，联网解析有可能拿到更新的
版本，反而偏离了规格（本计划里所有 riverpod 的 API 结论都是照着 3.4.3 核的）。

Expected: 解析出 `flutter_riverpod 3.4.3` 与 `path_provider 2.1.6`。`pubspec.yaml`
的 `dependencies:` 段落里会出现这两行；`pubspec.lock` 会一并变化 —— **它也要提交**
（Step 6 的 `git add` 里已经带了）。

然后**手工**给它们各配一行说明（本仓库的惯例：每个直接依赖都写清为什么）：

```yaml
  # 状态层（spec §8.5 点名 3.4.3）：按设备维度用 family provider 隔离会话、
  # 草稿、输出。
  flutter_riverpod: ^3.4.3
  # 应用数据目录（NFR-P-04）：Windows 在 %APPDATA% 下，Linux 在
  # $XDG_DATA_HOME（默认 ~/.local/share）下的应用子目录。
  path_provider: ^2.1.6
```

- [ ] **Step 2: 写失败的用例**

创建 `test/state/app_stores_test.dart`：

```dart
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
```

（`_Vault` 实现的是 `CredentialStore`，上面已经 import 了
`package:win_cli_tool/data/credential_store.dart`。**不要** import
`device_store.dart`：这个文件里没有一处直接提到 `DeviceStore`，多一个就是
`unused_import`，会让 `dart analyze` 不干净。）

- [ ] **Step 3: 跑用例，确认它红**

Run: `flutter test test/state/app_stores_test.dart`
Expected: 编译失败（两个新文件不存在）。

- [ ] **Step 4: 写实现**

创建 `lib/state/app_paths.dart`：

```dart
import 'dart:io';

/// 应用数据目录下的各处路径。
///
/// **只做路径拼接，不碰文件系统。** 目录存不存在由各个 store 自己负责
/// （`DraftStore` 第一次写会建目录，`writeJsonObject` 会 `create(recursive: true)`）
/// —— 在这里 `create()` 会让"构造一个路径对象"变成一次 IO，测试与将来的
/// 只读场景都不需要它。
class AppPaths {
  const AppPaths(this.root);

  /// 应用数据目录。`main()` 用 `path_provider` 的
  /// `getApplicationSupportDirectory()` 取（NFR-P-04：Windows 在 `%APPDATA%` 下，
  /// Linux 在 `$XDG_DATA_HOME`（默认 `~/.local/share`）下的应用子目录）；
  /// 测试里直接给一个临时目录。
  final Directory root;

  File get devicesFile => File('${root.path}/devices.json');
  File get settingsFile => File('${root.path}/settings.json');
  File get knownHostsFile => File('${root.path}/known_hosts.json');
  Directory get draftsDir => Directory('${root.path}/drafts');

  /// 日志根目录。FR-L-02 允许设置里覆盖（`AppSettings.logDir`），
  /// 那一条由调用方处理 —— 这里给的是"没覆盖时"的默认值。
  Directory get logsDir => Directory('${root.path}/logs');
}
```

创建 `lib/state/app_stores.dart`：

```dart
import '../data/credential_store.dart';
import '../data/device_store.dart';
import '../data/draft_store.dart';
import '../data/host_key_store.dart';
import '../data/settings_store.dart';
import 'app_paths.dart';

/// 持久化层的**唯一**实例集合。
///
/// 每个 store 都建在这里，且**只建一次** —— `late final` 让这件事成为构造上的
/// 事实，而不是"记得别建第二个"的纪律。两个 store 的文档都警告过它：
/// `DeviceStore` 的 `jumpHosts` 写回、`FileHostKeyStore` 的读-改-写，都曾经
/// 因为"同一个文件被两个实例各持一份状态"而**静默丢用户数据**（那两处已经
/// 各自改成不依赖实例状态，但装配层仍然只该有一份）。
class AppStores {
  AppStores({
    required this.paths,
    this.credentials = const PlaintextCredentialStore(),
  });

  final AppPaths paths;

  /// **NFR-S-01 的接缝。** V1 装的是明文实现（已接受的决策），换成系统密钥库时
  /// 只换这一个实参 —— `DeviceStore` 与 `DeviceProfile` 一行都不用改。
  final CredentialStore credentials;

  late final DeviceStore devices = DeviceStore(
    file: paths.devicesFile,
    credentials: credentials,
  );

  late final SettingsStore settings = SettingsStore(file: paths.settingsFile);

  /// `FileHostKeyStore` 而不是 `HostKeyStore`：FR-G-01 的「查看与逐条清除」
  /// 需要 `all()`，而它**刻意只加在具体类上**（见那个类的文档）。这里从具体
  /// 类型直接调用，不涉及向下转型。
  late final FileHostKeyStore hostKeys = FileHostKeyStore(
    file: paths.knownHostsFile,
  );

  late final DraftStore drafts = DraftStore(dir: paths.draftsDir);
}
```

- [ ] **Step 5: 跑用例，确认全绿**

Run: `flutter test test/state/app_stores_test.dart`
Expected: 全部通过（6 条）。

- [ ] **Step 6: 提交**

**最后两个路径是 `pub add` 的副作用，别漏。** `flutter pub add` 不只会改
`pubspec.yaml` / `pubspec.lock`：它还重写了 `linux/flutter/generated_plugins.cmake`
与 `windows/flutter/generated_plugins.cmake`，各加一行 `jni` 到
`FLUTTER_FFI_PLUGIN_LIST`（`jni` 是 `path_provider_android` 的传递 FFI 依赖）。
这两个文件**是入库的**，是 `pub get` 的确定性产物 —— 不改它们，工作树就是脏的，
而本计划的完成标准要求收尾时干净。

这一条是 Task 6 的实现者发现的，我事先没料到：我用
`flutter pub add --offline --dry-run` 量过依赖解析，可 **dry run 不写盘**，
照不出这两个文件。首次执行时它们是通过一个补交提交入库的（约束禁止 amend）。

```bash
git add pubspec.yaml pubspec.lock lib/state/app_paths.dart \
  lib/state/app_stores.dart test/state/app_stores_test.dart \
  linux/flutter/generated_plugins.cmake windows/flutter/generated_plugins.cmake
git commit -m "$(cat <<'EOF'
feat(state): 引入 riverpod/path_provider，并给持久化层一个唯一实例集合

AppPaths 只拼路径不碰文件系统；AppStores 用 late final 让"一个文件一个实例"
成为构造上的事实，而不是纪律。凭据实现留成构造参数 —— 那正是 NFR-S-01 要的接缝。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `SessionController` —— 一台设备的会话编排

**为什么：** 连接层的两个决定必须在这里落地，否则界面（5b）一定会写错：

1. **订阅 `ConnectionManager.output`，而且要在第一次连接之前就订阅。** `Session` 对象在重连时会被整个替换；直接订阅 `Session.output` 会让输出区在第一次断线后**永久静止而按钮是绿的**。
2. **`SessionReady` 携带的是本会话新造的 `CommandDispatcher`** —— 每次重连都换一个，`QueueDropped`（FR-C-10 的告警）与命令进度都从 `dispatcher.events` 来，所以必须在这里重新订阅。

另外它管日志的生命周期：FR-L-07「设置里关日志」的实现方式是**不构造 `LogWriter`**（那个类自己不做开关）。

**Files:**
- Create: `lib/state/session_controller.dart`
- Create: `test/fixtures/fake_session.dart`
- Test: `test/state/session_controller_test.dart`

- [ ] **Step 1: 建共享夹具**

创建 `test/fixtures/fake_session.dart`：

```dart
import 'dart:async';

import 'package:win_cli_tool/command/command_dispatcher.dart';
import 'package:win_cli_tool/connection/connector.dart';
import 'package:win_cli_tool/connection/known_host.dart';
import 'package:win_cli_tool/connection/session.dart';
import 'package:win_cli_tool/connection/session_factory.dart';
import 'package:win_cli_tool/models/device_profile.dart';

/// 状态层测试用的会话夹具。
///
/// 与 `test/connection/connection_manager_test.dart` 里那个私有夹具**目的不同**：
/// 那个要验证连接语义（订阅所有权、拆除顺序、退避），带着一段承重的注释；
/// 这个只验证"接线接对了没有"，所以刻意做小 —— 只有吐数据、断线、记下发过什么。
class FakeSession implements Session {
  FakeSession(this.profile, {this.failConnect = false});

  final DeviceProfile profile;
  final bool failConnect;

  final _output = StreamController<String>.broadcast();
  final _done = Completer<void>();
  final written = <String>[];
  var connectCalls = 0;
  var closed = false;

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Object? lastError;

  @override
  Future<void> connect() async {
    connectCalls++;
    if (failConnect) throw const FakeConnectFailure();
  }

  @override
  void write(String text) => written.add(text);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    // 与真实实现一致：close() 不结束 output、也不触发 done
    // （`Session` 的契约没有承诺前者，两个真实实现都这么做，但那是实现细节）。
  }

  /// 模拟对端吐数据。
  void emit(String s) {
    if (!_output.isClosed) _output.add(s);
  }

  /// 模拟对端断开。
  void drop([Object? error]) {
    if (error != null) lastError = error;
    if (!_done.isCompleted) _done.complete();
  }
}

/// 建连失败。用自定义类型避免依赖 dart:io。
class FakeConnectFailure implements Exception {
  const FakeConnectFailure();

  @override
  String toString() => 'connect failed';
}

class FakeSessionFactory implements SessionFactory {
  FakeSessionFactory({this.failConnect = false});

  bool failConnect;
  final sessions = <FakeSession>[];

  @override
  Session create(DeviceProfile profile) {
    final s = FakeSession(profile, failConnect: failConnect);
    sessions.add(s);
    return s;
  }

  @override
  HostKeyStore get hostKeyStore => InMemoryHostKeyStore();

  @override
  ConnectorResolver get connectorResolver => (p) => throw UnimplementedError();

  @override
  Duration get connectTimeout => const Duration(seconds: 15);

  @override
  bool get verifyHostKey => true;

  @override
  Future<bool> Function(KnownHost)? get onUnknownHostKey => null;
}

/// 一台测试设备。默认 `postLoginCommands` 为空 —— 状态层测试不关心 FR-C-08，
/// 让它空着才不会把"自动下发的命令"混进 `written` 的断言里。
DeviceProfile fakeProfile({
  String id = 'd1',
  String name = '核心交换机',
  bool autoConnect = false,
  List<String> postLogin = const [],
}) => DeviceProfile(
  id: id,
  name: name,
  protocol: DeviceProtocol.ssh,
  host: '10.0.0.1',
  port: 22,
  username: 'admin',
  postLoginCommands: postLogin,
  autoConnect: autoConnect,
);
```

- [ ] **Step 2: 写失败的用例**

创建 `test/state/session_controller_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connection_manager.dart';
import 'package:win_cli_tool/state/output_buffer.dart';
import 'package:win_cli_tool/state/session_controller.dart';

import '../fixtures/fake_session.dart';

void main() {
  late Directory logsRoot;
  late OutputBuffer buffer;
  late FakeSessionFactory factory;

  setUp(() async {
    logsRoot = await Directory.systemTemp.createTemp('wct_session_');
    buffer = OutputBuffer(maxLines: 5000);
    factory = FakeSessionFactory();
  });

  tearDown(() async {
    if (logsRoot.existsSync()) await logsRoot.delete(recursive: true);
  });

  SessionController make({
    bool logEnabled = true,
    void Function(Object)? onLogError,
    bool autoConnect = false,
  }) => SessionController(
    profile: fakeProfile(autoConnect: autoConnect),
    factory: factory,
    buffer: buffer,
    logsDir: logsRoot,
    logEnabled: logEnabled,
    onLogError: onLogError,
  );

  /// 输出是一条广播流，订阅与转发都在微任务里 —— 让它们跑完。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('输出在**第一次连接之前**就已经接上了', () async {
    // 这条钉的正是"订阅 Session.output 会在第一次断线后永久静止"那个坑：
    // 缓冲接的是 ConnectionManager.output，它在连接之前就存在。
    final c = make();
    addTearDown(c.dispose);

    await c.connect();
    factory.sessions.single.emit('hello');
    await settle();

    expect(buffer.lines.first.single.text, 'hello');
  });

  test('重连之后输出仍然接着来（会话对象被换掉了）', () async {
    final c = make();
    addTearDown(c.dispose);

    await c.connect();
    factory.sessions.single.emit('before');
    await settle();

    // 对端断开 → 退避重连。用真实 async，因为这条要等拆除链走完。
    factory.sessions.single.drop();
    await Future<void>.delayed(const Duration(seconds: 2));
    await settle();
    expect(factory.sessions, hasLength(2), reason: '1s 后应当已经重连');

    factory.sessions[1].emit('after');
    await settle();

    final text = buffer.lines
        .map((line) => line.map((s) => s.text).join())
        .join('\n');
    expect(text, contains('before'));
    expect(text, contains('after'), reason: '换会话之后输出区不得静止');
  });

  test('状态跟着 ConnectionManager 走', () async {
    final c = make();
    addTearDown(c.dispose);

    expect(c.status.state, DeviceConnectionState.disconnected);
    await c.connect();
    // **`status` 是事件的镜像，不是 manager 自己的 `state`。** 事件走广播流，
    // 而投递**不是**"下一个微任务"那么快：实测 `await c.connect()` 刚返回时
    // `c.status.state` 还是 `connecting`，而 `c.state`（直接问 manager）已经是
    // `connected`；让一轮事件循环跑完（`settle()`）两者才一致。
    // 断言镜像就得等投递 —— 本文件读事件驱动状态的地方都这么做（见 `settle()`
    // 的定义：它存在的理由就是这件事）。
    //
    // 顺带记一笔给 5b：`SessionController.state`（同步，直接问 manager）与
    // `SessionStatus.state`（异步镜像）是**两个真相来源**，会差一个回合。
    // 界面得**有意地**挑一个用，别混着用。
    await settle();
    expect(c.status.state, DeviceConnectionState.connected);
    await c.disconnect();
    await settle();
    expect(c.status.state, DeviceConnectionState.disconnected);
  });

  test('断开与重连在输出区各插一个标记，且**不进日志**', () async {
    final c = make();
    addTearDown(c.dispose);
    await c.connect();

    factory.sessions.single.drop();
    await Future<void>.delayed(const Duration(seconds: 2));
    await settle();

    final text = buffer.lines
        .map((line) => line.map((s) => s.text).join())
        .join('\n');
    expect(text, contains('连接断开'));
    expect(text, contains('重连成功'));

    // **读日志之前必须先逼它落盘。** `LogWriter._flush` 默认只在攒够
    // `flushEveryLines`（32）行时才真写，`start()` / `write()` / `disconnected()`
    // 都**不是**强制点 —— 唯一的强制点是 `end()`。本用例到这一步只往日志里放了
    // 四行，所以不落盘的话磁盘上**什么都没有**，下面那两条"不含"就在空串上成立。
    //
    // 这条原本写的是 `expect(log, isNot(contains('连接断开')))`，**它永远不会红**：
    // ① 如上，读到的是空串；② 就算落了盘它也不成立 —— LogWriter 自己的断开标记
    // 里就有"连接断开"这四个字（§5.6 逐字规定，见 `LogWriter.disconnected`）。
    // 一个字段名被两边共用，"不含这个词"就不可能表达"输出区的标记没混进去"。
    // 判据只能是各自的**记号**：输出区的以 `--- ` 开头、不带时间戳，LogWriter 的
    // 形如 `[时间戳] !!! 连接断开 …！！！`。
    //
    // 用 `disconnect()` 而不是 `dispose()`：前者 `await` 了 `log.end()`，落盘是
    // 确定的；后者的 `_endLogSync` 是 `unawaited(log?.end())`，读的时候可能还没写完。
    await c.disconnect();

    final log = await _readAllLogs(logsRoot);
    // 这两条是下面两条的**前提**：它们证明日志确实有内容。
    // 没有它们，"不含"两条在"日志是空的"时也会绿。
    expect(log, contains('!!! 连接断开'), reason: 'LogWriter 自己会写断开标记（§5.6）');
    expect(log, contains('=== 重连成功'), reason: 'LogWriter 自己会写重连标记（§5.6）');
    expect(log, isNot(contains('--- 连接断开')), reason: '输出区的标记不进日志');
    expect(log, isNot(contains('--- 重连成功')), reason: '输出区的标记不进日志');
  });

  test('丢弃数从 dispatcher.events 取（FR-C-10）', () async {
    final c = make();
    addTearDown(c.dispose);
    await c.connect();

    c.enqueue(const ['show version', 'show clock']);
    await settle();
    factory.sessions.single.drop();
    await settle();

    expect(
      c.status.droppedCommands,
      greaterThan(0),
      reason: '未发出的命令一律丢弃，丢弃数由 QueueDropped 承载',
    );
  });

  test('关掉日志时不构造 LogWriter（FR-L-07）', () async {
    final c = make(logEnabled: false);
    addTearDown(c.dispose);
    await c.connect();
    factory.sessions.single.emit('hello\n');
    await settle();
    // **这里也必须是 `disconnect()`。** `dispose()` 的 `_endLogSync` 是
    // `unawaited(log?.end())`，读的时候磁盘上本来就可能什么都没有（下一条用例
    // 有实测）—— 那样"没有文件"就成了**空转**：即使真的构造了 `LogWriter`，
    // 这条也照样绿。`disconnect()` 会 `await end()`，真有 writer 就必然出现文件，
    // 于是"空"才真的证明"没构造"。
    await c.disconnect();

    expect(await _readAllLogs(logsRoot), isEmpty, reason: '没构造就不该有文件');
  });

  test('日志写在 logs/ 下的日期目录里，内容与输出区同源', () async {
    final c = make();
    addTearDown(c.dispose);
    await c.connect();
    factory.sessions.single.emit('a\x1b[31mred\x1b[0m\n');
    await settle();
    // **逼日志落盘要用 `disconnect()`，不能用 `dispose()`。** `dispose()` 走的是
    // `_endLogSync()`，那是 `unawaited(log?.end())` —— 读的时候写还没落下去，
    // 而在那之前**连日期目录都还不存在**（`LogWriter._flush` 只在真正要写的那
    // 一步才 `create(recursive: true)`）。实测：`dispose()` 之后立刻读是**空串**，
    // 300ms 之后才有内容（内容本身是对的：含 `red`、无 ESC）。
    // `disconnect()` 里的 `_endLog()` 是 `await log?.end()`，落盘是确定的。
    await c.disconnect();

    final log = await _readAllLogs(logsRoot);
    expect(log, contains('red'));
    expect(log, isNot(contains('\x1b')), reason: '日志是剥干净的纯文本');
  });

  test('日志写盘失败时回调一次，且不拖垮会话（FR-L-06）', () async {
    final errors = <Object>[];
    // 日志根目录的父路径是一个**普通文件**，所以写盘必定失败。
    final blocker = File('${logsRoot.path}/blocker')
      ..writeAsStringSync('not a dir');
    final c = SessionController(
      profile: fakeProfile(),
      factory: factory,
      buffer: buffer,
      logsDir: Directory('${blocker.path}/logs'),
      logEnabled: true,
      onLogError: errors.add,
    );
    addTearDown(c.dispose);

    await c.connect();
    // **必须喂够一次真实的写盘尝试，否则下面那条断言不可达。** `LogWriter._flush`
    // 默认只在缓冲攒够 `flushEveryLines`（32）行时才真写；`start()` / `write()`
    // 都**不是**强制点（唯一的强制点是 `end()`）。只喂一行的话根本不会碰磁盘，
    // `onLogError` 无从触发 —— 实测：一行 + `settle()` ⇒ **0 次**回调。
    //
    // 一次喂 40 行，而且是**同一个 chunk**（于是只触发一次 `_flush`）：写盘必定
    // 失败 ⇒ 回调一次 ⇒ `_failed` 置位，此后本类不再碰磁盘。
    factory.sessions.single.emit('${'x\n' * 40}');

    // 失败要等两个真的 IO 回合（`stat()` → `create()`）。实测：0ms 与 5ms 时还是
    // 0 次，50ms 时是 1 次 —— 所以固定等一个 `Duration.zero` 不够。这里**轮询到
    // 条件成立**（上限 2 秒），而不是赌一个毫秒数：等不到就是下面那条断言红，
    // 不会变成"偶尔绿"。
    for (var i = 0; i < 200 && errors.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(errors, hasLength(1), reason: '失败只报一次');
    expect(
      c.status.state,
      DeviceConnectionState.connected,
      reason: '日志坏掉绝不能拖垮会话',
    );
  });

  test('dispose() 关掉会话，且不向设备发任何命令（FR-C-12）', () async {
    final c = make();
    await c.connect();
    final session = factory.sessions.single;
    session.written.clear();

    await c.dispose();

    expect(session.closed, isTrue, reason: 'FR-C-12：退出时直接关闭所有会话');
    expect(
      session.written,
      isEmpty,
      reason: 'FR-C-12：不向设备发送任何命令 —— 包括不清除分页、不发登出序列',
    );
  });
}

/// 读遍日志根目录下的所有 .log 文件，拼成一个字符串。
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
```

- [ ] **Step 3: 跑用例，确认它红**

Run: `flutter test test/state/session_controller_test.dart`
Expected: 编译失败（`lib/state/session_controller.dart` 不存在）。

- [ ] **Step 4: 写实现**

创建 `lib/state/session_controller.dart`：

```dart
import 'dart:async';
import 'dart:io';

import '../command/command_dispatcher.dart';
import '../connection/connection_failure.dart';
import '../connection/connection_manager.dart';
import '../connection/session_factory.dart';
import '../models/device_profile.dart';
import '../render/ansi_parser.dart';
import '../data/log_writer.dart';
import 'output_buffer.dart';

/// 一台设备当下的会话状态（界面直接渲染这个）。
class SessionStatus {
  const SessionStatus({
    this.state = DeviceConnectionState.disconnected,
    this.reconnect,
    this.droppedCommands = 0,
    this.lastFailure,
    this.lastDispatchEvent,
  });

  final DeviceConnectionState state;

  /// 已排程的重连（FR-C-07 的"X 秒后重连"）。null 表示没有在等。
  ///
  /// 数据源**只有** `ReconnectScheduled` 一个；重连成功后置回 null。
  final ReconnectScheduled? reconnect;

  /// 最近一次断线丢弃的命令数（FR-C-10）。数据源是 `QueueDropped`。
  final int droppedCommands;

  /// 最近一次连接失败的可读原因（FR-C-06）。
  /// **[ConnectionFailure.message] 才是展示物，[ConnectionFailure.cause] 不是。**
  final ConnectionFailure? lastFailure;

  /// 最近一条命令队列事件（FR-E-14 的 `执行中 3/8` 与超时告警都从这里算）。
  ///
  /// 只留最近一条：进度显示要的是"现在到哪了"，不是历史。**翻页不产生队列
  /// 进度变化**（`PagerContinued` 不该动进度条）。
  final DispatchEvent? lastDispatchEvent;

  SessionStatus copyWith({
    DeviceConnectionState? state,
    Object? reconnect = _unset,
    int? droppedCommands,
    Object? lastFailure = _unset,
    DispatchEvent? lastDispatchEvent,
  }) => SessionStatus(
    state: state ?? this.state,
    reconnect: identical(reconnect, _unset)
        ? this.reconnect
        : reconnect as ReconnectScheduled?,
    droppedCommands: droppedCommands ?? this.droppedCommands,
    lastFailure: identical(lastFailure, _unset)
        ? this.lastFailure
        : lastFailure as ConnectionFailure?,
    lastDispatchEvent: lastDispatchEvent ?? this.lastDispatchEvent,
  );
}

const Object _unset = Object();

/// §5.4 的断开标记与 §7.3 的命令超时告警都是**黄色**。
const AnsiStyle kMarkerWarnStyle = AnsiStyle(foreground: AnsiBasic(3));

/// 重连成功的分隔线。
const AnsiStyle kMarkerOkStyle = AnsiStyle(foreground: AnsiBasic(2));

/// 一台设备的会话编排：把 [ConnectionManager] 的事件翻译成界面能直接用的东西，
/// 并管住日志的生命周期。
///
/// **它订阅的是 `mgr.output`，不是 `Session.output`，而且是在构造时就订阅。**
/// 会话对象在重连时会被整个替换；直接订阅 Session 会让输出区在第一次断线后
/// **永久静止而按钮是绿的**（`ConnectionManager` 的类文档）。在这里订阅还保证了
/// "第一次连接之前就已经接上"—— 连接建立之前到达的输出不会丢。
///
/// **`SessionReady` 携带的 dispatcher 每次重连都是新的**，所以 `dispatcher.events`
/// 必须在那时重新订阅。类型上刻意给 dispatcher 而不给 Session，就是为了让这里
/// 没有任何理由去碰 Session。
class SessionController {
  SessionController({
    required this.profile,
    required SessionFactory factory,
    required this.buffer,
    required this.logsDir,
    required this.logEnabled,
    this.onLogError,
  }) : _manager = ConnectionManager(profile: profile, factory: factory) {
    _outputSub = _manager.output.listen(buffer.add);
    _eventsSub = _manager.events.listen(_onEvent);
  }

  final DeviceProfile profile;

  /// 输出缓冲。**与日志共用同一处边界**（见 `OutputBuffer` 的文档）。
  final OutputBuffer buffer;

  /// 日志根目录。设置里覆盖过就用覆盖值（FR-L-02），否则是应用数据目录下的
  /// `logs/`。
  final Directory logsDir;

  /// FR-L-07：**关日志的实现方式是不构造 `LogWriter`** —— 那个类自己不做开关。
  ///
  /// **本值是构造时读一次的**：会话已经跑起来之后改这个设置不会中途换行为，
  /// 下次连接才生效。这是知情的取舍（换日志文件写到一半会留下两个文件）。
  final bool logEnabled;

  /// 写盘失败的回调（FR-L-06）。**别在这里抛** —— 它在 `_flush` 的 `catch` 里
  /// **同步**被调用，抛出去会冒到会话循环里，而那正是 FR-L-06 要避免的
  /// "日志坏掉拖垮会话"。
  final void Function(Object error)? onLogError;

  final ConnectionManager _manager;
  late final StreamSubscription<String> _outputSub;
  late final StreamSubscription<ConnectionEvent> _eventsSub;

  /// 当前会话的 dispatcher 事件订阅。**每次 `SessionReady` 换一个。**
  StreamSubscription<DispatchEvent>? _dispatchSub;

  /// 当前会话的日志。**一次会话一个实例**，会话结束调 `end()`。
  LogWriter? _log;

  var _status = const SessionStatus();

  /// 状态变化时回调（界面订阅它重绘）。
  void Function(SessionStatus status)? onStatus;

  SessionStatus get status => _status;

  /// 该设备当前的连接状态。
  DeviceConnectionState get state => _manager.state;

  /// 该设备当前会话的命令队列。未连接时为 null。
  ///
  /// 界面**不该**从这里取 dispatcher（时序约定藏起来了），应该在
  /// `SessionReady` 时拿 —— 但本类已经把那些约定处理完了，所以对界面暴露的是
  /// [enqueue] 与 [abort]。
  CommandDispatcher? get dispatcher => _manager.dispatcher;

  /// 把命令排进该设备的队列（FR-E-01）。未连接时什么都不做。
  void enqueue(List<String> commands) => _manager.dispatcher?.enqueue(commands);

  /// 中止队列（FR-E-13 / Esc）：不再发送剩余命令，已发出的不做处理。
  void abort() => _manager.dispatcher?.abort();

  Future<void> connect() => _manager.connect();

  Future<void> disconnect() async {
    await _manager.disconnect();
    await _endLog();
  }

  /// 应用退出时调用（FR-C-12）。**不向设备发送任何命令。**
  Future<void> dispose() async {
    await _dispatchSub?.cancel();
    await _eventsSub.cancel();
    await _outputSub.cancel();
    // 残留的半条序列放出来，否则它永远留在缓冲里 —— 而输出区此后不再有新数据
    // 来把它补齐。
    buffer.flush();
    _endLogSync();
    await _manager.dispose();
  }

  void _onEvent(ConnectionEvent event) {
    // `ConnectionEvent` 是 `sealed`：将来新增一种会成为**编译错误**，
    // 而不是某个分支悄悄不处理。
    switch (event) {
      case ConnectionStateChanged(:final state):
        _setStatus(_status.copyWith(state: state));
      case SessionReady(:final dispatcher):
        _onSessionReady(dispatcher);
      case ReconnectScheduled():
        _setStatus(_status.copyWith(reconnect: event));
        _markWarn('--- 连接断开，${event.delay.inSeconds} 秒后重连'
            '（第 ${event.attempt} 次）---');
      case Reconnected(:final downtime, :final attempt):
        _setStatus(_status.copyWith(reconnect: null));
        _markOk('--- 重连成功（断线 ${downtime.inSeconds} 秒，'
            '第 $attempt 次尝试）---');
        _log?.reconnected();
      case ConnectionFailed(:final failure):
        _setStatus(_status.copyWith(lastFailure: failure));
      case SessionLost():
        _markWarn('--- 连接断开 ---');
        _log?.disconnected();
    }
  }

  void _onSessionReady(CommandDispatcher dispatcher) {
    _setStatus(
      _status.copyWith(
        reconnect: null,
        lastFailure: null,
        // 上一次断线的丢弃数属于上一次断线，新会话开始就归零。
        droppedCommands: 0,
      ),
    );
    // **每次重连都新建一个 dispatcher**，所以这里必须重新订阅 —— 不重订的话
    // `QueueDropped`（FR-C-10 的告警）与命令进度在第一次断线后就再也没有了。
    _dispatchSub?.cancel();
    _dispatchSub = dispatcher.events.listen(_onDispatchEvent);
    _startLog();
  }

  void _onDispatchEvent(DispatchEvent event) {
    if (event is QueueDropped) {
      _setStatus(_status.copyWith(droppedCommands: event.count));
      _markWarn('--- 连接断开，${event.count} 条未发送的命令已丢弃 ---');
      return;
    }
    if (event is CommandCompleted && event.timedOut) {
      // §7.3：超时的命令，其对应输出区域插入**黄色**告警行，
      // 注明超时的命令序号与原命令文本（FR-E-12）。
      _markWarn(
        '--- 第 ${event.index}/${event.total} 条命令执行超时，已强制放行'
        '下一条：${event.command} ---',
      );
    }
    _setStatus(_status.copyWith(lastDispatchEvent: event));
  }

  void _setStatus(SessionStatus next) {
    _status = next;
    onStatus?.call(next);
  }

  void _markWarn(String text) => buffer.addMarker(text, style: kMarkerWarnStyle);
  void _markOk(String text) => buffer.addMarker(text, style: kMarkerOkStyle);

  /// 开始一次会话的日志。**FR-L-07：关掉日志就是不构造它。**
  void _startLog() {
    if (!logEnabled) return;
    _log ??= LogWriter(
      rootDir: logsDir,
      deviceName: profile.name,
      onError: onLogError,
    );
    // **先 `start()` 再挂出口，顺序不能反。** `LogWriter.write()` 开头是
    // `if (!_started || _closed) return;` —— 出口先挂上、`start()` 还没跑的话，
    // 这中间到达的输出会被**静默丢掉**（而 `start()` 的同步部分其实立刻就跑完了，
    // 所以反着写也"能用"，只是留下一个靠时序运气维持的窗口）。
    // `unawaited` 的理由：这里在事件回调里，不该被磁盘拖住；`start()` 的同步部分
    // 已经跑完，后续 `write()` 一定排在它后面。
    unawaited(_log!.start('${profile.username}@${profile.host}:${profile.port}'));
    // 输出缓冲的日志出口指向**本次会话**的 writer。缓冲活得比一次会话长，
    // 所以这个出口是可换的 —— 会话结束后置空，那段时间攒下的输出不进任何日志。
    buffer.onText = (text) => unawaited(_log?.write(text));
  }

  Future<void> _endLog() async {
    final log = _log;
    _log = null;
    buffer.onText = null;
    await log?.end();
  }

  /// [dispose] 用的是同步版：那里已经不能安全地 await 太多东西，
  /// 而 `end()` 的落盘在进程退出前会由缓冲的 flush 兜住。
  void _endLogSync() {
    final log = _log;
    _log = null;
    buffer.onText = null;
    unawaited(log?.end());
  }
}

/// FR-C-14：启动时对 `autoConnect == true` 的设备各发起一次连接。
///
/// 写成接收回调的纯函数而不是塞进某个 provider 的 `build()`：读设备列表与
/// 连设备是两件事，后者有副作用，不该藏在任何 provider 的构造里。
void connectAutoConnectDevices({
  required List<DeviceProfile> devices,
  required void Function(String deviceId) connect,
}) {
  for (final device in devices) {
    if (!device.autoConnect) continue;
    connect(device.id);
  }
}
```

**注意 `unawaited`**：它来自 `dart:async`，上面已经 import 了。

- [ ] **Step 5: 跑用例，确认全绿**

Run: `flutter test test/state/session_controller_test.dart`
Expected: 全部通过（9 条）。

**如果 `重连之后输出仍然接着来` 超时或红**，先确认 `FakeSession.close()` **没有**关闭 `_output`（夹具里刻意如此，与真实实现不同）—— manager 会自己取消订阅，所以不需要靠关流来挡住旧数据。

**首次实跑时上面有三条是红的 —— 已按实测改正（别再改回去）：**

1. `状态跟着 ConnectionManager 走`：`status` 镜像比 manager 的 `state` 慢一个回合
   （实测：`await c.connect()` 返回时 `status=connecting` 而 `state=connected`，
   再跑一轮事件循环才一致）。断言镜像之前要 `settle()`。
2. `日志写在 logs/ 下的日期目录里，内容与输出区同源`：`dispose()` 的
   `_endLogSync` 是 `unawaited(log?.end())`，读到时磁盘上**什么都没有**（实测读到
   空串，300ms 之后才有内容）。改用 `disconnect()`（它 `await` 了 `end()`）。
3. `日志写盘失败时回调一次，且不拖垮会话`：只喂一行永远到不了 32 行的落盘阈值，
   `onLogError` 无从触发（实测 0 次）。改喂 40 行（**同一个 chunk**，只触发一次
   `_flush`），并轮询等待失败落定（实测 5ms 时仍是 0 次、50ms 时是 1 次）。

- [ ] **Step 6: 提交**

```bash
git add lib/state/session_controller.dart test/fixtures/fake_session.dart test/state/session_controller_test.dart
git commit -m "$(cat <<'EOF'
feat(state): SessionController —— 一台设备的会话编排

订阅 ConnectionManager.output（不是 Session.output），且在构造时就订阅，早于
第一次连接：会话对象在重连时会被整个替换，直接订阅 Session 会让输出区在第一次
断线后永久静止而按钮是绿的。SessionReady 携带的 dispatcher 每次重连都是新的，
所以 dispatcher.events 在那里重新订阅（QueueDropped 与命令进度都从那儿来）。

日志按 FR-L-07 用"不构造 LogWriter"关上；输出区的标记走 buffer.addMarker，
不进日志 —— LogWriter 有它自己的一套（§5.6 逐字规定）。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `lib/state/providers.dart` —— Riverpod 接线

**为什么：** spec §8.4 点名的文件。这里的每一个决定都是为了让**下游同步**：`main()` 在 `runApp` 之前把设备与设置读出来，此后没有一个 provider 需要 `AsyncValue`，界面（5b）不必为"还没读出来"写一遍在任何一次真实启动里都到不了的分支。

**Files:**
- Create: `lib/state/providers.dart`
- Test: `test/state/providers_test.dart`

- [ ] **Step 1: 写失败的用例**

创建 `test/state/providers_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/load_issue.dart';
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
```

（**"草稿读不出来"那一条不在这里重复**：`DraftUnreadableException` 带着 `deviceId`
的契约在计划 4 已经有用例钉着，本任务只验接线。）

- [ ] **Step 2: 跑用例，确认它红**

Run: `flutter test test/state/providers_test.dart`
Expected: 编译失败（`lib/state/providers.dart` 不存在）。

- [ ] **Step 3: 写实现**

创建 `lib/state/providers.dart`：

```dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/session_factory.dart';
import '../data/load_issue.dart';
import '../models/app_settings.dart';
import '../models/device_profile.dart';
import 'app_stores.dart';
import 'output_buffer.dart';
import 'session_controller.dart';

/// 启动时**一次性**读出来的东西。
///
/// 由 `main()` 在 `runApp` 之前取好，经 `ProviderScope(overrides:)` 注入；
/// 测试里用临时目录做同样的事。
///
/// **做成同步的 `Provider` 而不是 `FutureProvider` 是刻意的。** 设备与设置是
/// 界面的起点，异步会让 `AsyncValue` 传染给每一个下游 provider，而界面就得为
/// "还没读出来"写一遍分支 —— 那个分支在任何一次真实启动里都到不了，却要一直
/// 维护。这一层异步只有启动那一处，把它摁在那里。
class AppStartup {
  const AppStartup({
    required this.settings,
    required this.devices,
    this.settingsIssues = const [],
    this.deviceIssues = const [],
  });

  final AppSettings settings;
  final List<DeviceProfile> devices;

  /// 加载期发现的问题，**必须展示给用户**（`LoadIssue` 的文档：每一条都对应
  /// 一件用户需要知道的事）。
  final List<LoadIssue> settingsIssues;
  final List<LoadIssue> deviceIssues;
}

/// 启动结果。**必须被覆盖** —— 没有默认值可给，因为"应用数据目录在哪"只有
/// `main()` 知道（`path_provider` 要走平台通道）。
final startupProvider = Provider<AppStartup>(
  (ref) => throw StateError(
    'startupProvider 必须由 main() 覆盖（见 lib/main.dart）',
  ),
);

/// 持久化层的唯一实例集合。
final appStoresProvider = Provider<AppStores>(
  (ref) => throw StateError(
    'appStoresProvider 必须由 main() 覆盖（见 lib/main.dart）',
  ),
);

/// 造会话的工厂。**在 `main()` 里覆盖成真的那个**（它需要已知主机密钥库与
/// 主机密钥确认回调）；测试里覆盖成夹具。
///
/// 默认实现直接用装配好的密钥库 —— 这样"忘了覆盖"也不会静默变成不校验
/// （那会让 NFR-S-03 形同虚设）。
final sessionFactoryProvider = Provider<SessionFactory>((ref) {
  final stores = ref.watch(appStoresProvider);
  final settings = ref.watch(settingsProvider);
  return SessionFactory(
    hostKeyStore: stores.hostKeys,
    connectTimeout: Duration(milliseconds: settings.connectTimeoutMs),
    // NFR-S-03 / FR-C-11：**默认开启**，用户可在设置里关掉。
    verifyHostKey: settings.verifySshHostKey,
  );
});

/// 加载/保存期发现的问题，攒给界面展示。
class IssuesNotifier extends Notifier<List<LoadIssue>> {
  @override
  List<LoadIssue> build() {
    final startup = ref.read(startupProvider);
    return [...startup.deviceIssues, ...startup.settingsIssues];
  }

  void add(LoadIssue issue) => state = [...state, issue];

  void addAll(Iterable<LoadIssue> issues) => state = [...state, ...issues];

  /// 用户点过"知道了"。
  void dismissAll() => state = const [];
}

final issuesProvider = NotifierProvider<IssuesNotifier, List<LoadIssue>>(
  IssuesNotifier.new,
);

/// 全局设置。启动时读好的那一份是初值。
class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(startupProvider).settings;

  /// 存盘成功**之后**才改内存状态 —— 界面不会显示一个没落盘的设置。
  /// 存盘失败时异常原样抛给调用方，由界面提示（与 `DuplicateDeviceNameError`
  /// 同一种呈现方式）。
  Future<void> update(AppSettings next) async {
    await ref.read(appStoresProvider).settings.save(next);
    state = next;
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// 设备列表。数组顺序**就是**显示顺序（§13.2）。
class DevicesNotifier extends Notifier<List<DeviceProfile>> {
  @override
  List<DeviceProfile> build() => ref.read(startupProvider).devices;

  /// 新增一台设备，id 由本层生成（FR-D-01）。
  ///
  /// **id 不经用户输入**：它是 `DraftStore` 的文件名，而不区分大小写的卷上
  /// `A` 与 `a` 会落到同一个文件（两台设备共用一份草稿），Windows 的保留名
  /// （`CON`/`NUL`/`COM1`）更是"带扩展名依然保留"。小写 UUID 把这些一次排除。
  ///
  /// **逐字段重建，不要写 `draft.copyWith(id: newDeviceId())`** ——
  /// `DeviceProfile.copyWith` **不接受 `id`**（它刻意保留原 id：id 是身份，
  /// 其余字段才是可改的）。这里要的恰恰是换一个身份，所以只能重建。
  Future<DeviceProfile> add(DeviceProfile draft) async {
    final created = DeviceProfile(
      id: newDeviceId(),
      name: draft.name,
      protocol: draft.protocol,
      host: draft.host,
      port: draft.port,
      username: draft.username,
      password: draft.password,
      privateKeyPath: draft.privateKeyPath,
      jumpHostIds: draft.jumpHostIds,
      lineEnding: draft.lineEnding,
      promptRegex: draft.promptRegex,
      postLoginCommands: draft.postLoginCommands,
      autoConnect: draft.autoConnect,
      snippets: draft.snippets,
    );
    await _save([...state, created]);
    return created;
  }

  /// 按 id 替换（FR-D-05）。**不改顺序。**
  Future<void> update(DeviceProfile profile) async {
    await _save([
      for (final d in state) if (d.id == profile.id) profile else d,
    ]);
  }

  /// 删除（FR-D-06）：断开它的会话，一并删掉草稿。**日志保留。**
  Future<void> remove(String id) async {
    await _save(state.where((d) => d.id != id).toList(growable: false));
    // 顺序：先把它从列表里摘掉（内存与磁盘），再拆会话。反过来的话，
    // 拆会话期间界面还能看到一台"已经没了"的设备。
    ref.invalidate(sessionProvider(id));
    ref.invalidate(draftProvider(id));
    ref.invalidate(outputBufferProvider(id));
    await ref.read(appStoresProvider).drafts.delete(id);
  }

  /// 拖拽排序（FR-D-07）。
  ///
  /// **`devices.json` 没有 order 字段，数组顺序就是显示顺序** —— 所以排序唯一
  /// 的实现方式就是**重写整个数组**，`:memory:` 与磁盘都重写一遍。store 自己
  /// 逐条编码、不排序。
  Future<void> reorder(List<String> orderedIds) async {
    final byId = {for (final d in state) d.id: d};
    final next = <DeviceProfile>[];
    for (final id in orderedIds) {
      final device = byId.remove(id);
      if (device != null) next.add(device);
    }
    // 传进来的 id 少写了几个（界面 bug）时，剩下的**追加在后面**而不是丢掉 ——
    // 丢设备比顺序错更糟。
    next.addAll(byId.values);
    await _save(next);
  }

  /// 先存盘、成功了才改内存：界面不会显示一个没落盘的设备列表。
  ///
  /// `DeviceStore.save` 会**先全校验再动文件**，重名时抛
  /// [DuplicateDeviceNameError]（带可展示的 `message`）—— 异常原样抛给界面，
  /// 别在这里 catch 成 `'$e'`。
  Future<void> _save(List<DeviceProfile> next) async {
    await ref.read(appStoresProvider).devices.save(next);
    state = next;
  }
}

final devicesProvider =
    NotifierProvider<DevicesNotifier, List<DeviceProfile>>(DevicesNotifier.new);

/// 某台设备的编辑区草稿（FR-E-03/04）。不存在时是空串。
///
/// `build()` 会抛 [DraftUnreadableException]（不是 UTF-8，或读盘失败）——
/// **别把它降级成空串**，那会让用户以为"草稿没了"而其实文件还在。界面 catch
/// 它并提示（异常里有 `deviceId`）。
final draftProvider =
    AsyncNotifierProvider.family<DraftNotifier, String, String>(
      DraftNotifier.new,
    );

class DraftNotifier extends AsyncNotifier<String> {
  DraftNotifier(this.deviceId);

  final String deviceId;

  @override
  Future<String> build() =>
      ref.read(appStoresProvider).drafts.read(deviceId);

  /// 存草稿。**原子写**（`DraftStore` 走 `writeFileAtomically`）。
  Future<void> save(String text) async {
    await ref.read(appStoresProvider).drafts.write(deviceId, text);
    state = AsyncData(text);
  }
}

/// 某台设备的输出缓冲。**活得比一次会话长**（FR-O-09：切走再切回来还看得到
/// 完整过程），所以它在这里，不在 `SessionController` 里。
final outputBufferProvider =
    Provider.family<OutputBuffer, String>((ref, deviceId) {
  final settings = ref.watch(settingsProvider);
  return OutputBuffer(maxLines: settings.outputBufferLines);
});

/// 某台设备的会话。
///
/// **不 `watch` 设置。** `SessionController` 在构造时就把 `logEnabled` /
/// `verifyHostKey` 这些读定了；若这里 `watch`，用户改任何一个设置都会重建
/// controller，而那会把**正在跑的会话拆掉** —— 改个主题就把线断掉。所以读一次，
/// 设置的改动在下次连接时生效（知情的取舍，换日志文件写到一半会留下两个文件）。
final sessionProvider =
    NotifierProvider.family<SessionNotifier, SessionStatus, String>(
      SessionNotifier.new,
    );

class SessionNotifier extends Notifier<SessionStatus> {
  SessionNotifier(this.deviceId);

  final String deviceId;

  late final SessionController _controller;

  @override
  SessionStatus build() {
    final settings = ref.read(settingsProvider);
    final profile = ref
        .read(devicesProvider)
        .firstWhere((d) => d.id == deviceId);

    _controller = SessionController(
      profile: profile,
      factory: ref.read(sessionFactoryProvider),
      buffer: ref.read(outputBufferProvider(deviceId)),
      // FR-L-02：设置里给了就用设置里的，否则用应用数据目录下的 logs/
      // （`logsDirPath` 是 `Provider<String>`，由 `main()` 覆盖）。
      logsDir: Directory(settings.logDir ?? ref.read(logsDirPath)),
      logEnabled: settings.logEnabled,
      onLogError: (error) => ref
          .read(issuesProvider.notifier)
          .add(LoadIssue(LoadIssueKind.corruptFile, '日志写入失败：$error')),
    );
    // controller 的状态变化（含从 `ConnectionManager` 来的那些）推给 Riverpod。
    _controller.onStatus = (status) => state = status;
    ref.onDispose(_controller.dispose);
    return _controller.status;
  }

  Future<void> connect() => _controller.connect();
  Future<void> disconnect() =>
      _controller.disconnect().then((_) => state = _controller.status);

  /// 把命令排进该设备的队列（FR-E-01）。队列在后台继续跑，切设备不影响它。
  void enqueue(List<String> commands) => _controller.enqueue(commands);

  /// 中止队列（FR-E-13 / Esc）。
  void abort() => _controller.abort();
}

/// 日志根目录的默认位置。由 `main()` 覆盖成应用数据目录下的 `logs/`。
final logsDirPath = Provider<String>(
  (ref) => throw StateError('logsDirPath 必须由 main() 覆盖（见 lib/main.dart）'),
);

/// 生成一个**小写**的设备 id。
///
/// 形状是 UUID v4，但**不引 uuid 包**：这里只要 122 位密码学随机数拼成小写
/// 十六进制，八行就够，而多一个直接依赖就要多写一段"为什么需要它"。
///
/// 小写是**要求**不是偏好：`DraftStore` 拿它当文件名，在不区分大小写的卷上
/// `A` 与 `a` 会落到同一个文件。UUID 的形状还顺带排除了 Windows 的保留设备名
/// （`CON`/`NUL`/`COM1` 带上扩展名依然保留）—— 那种名字必须有确定的长度才撞不上。
String newDeviceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // 版本 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // 变体 10xx
  final hex = bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
```

最后，在 `providers.dart` **末尾**再加一个函数 —— Task 7 写的
`connectAutoConnectDevices`（在 `session_controller.dart` 里）是纯函数，需要一个
把 `deviceId` 接到 provider 上的地方：

```dart
/// FR-C-14：启动时对 `autoConnect == true` 的设备各发起一次连接。
///
/// 由 `app.dart` 在首帧之后调用一次。**只调一次** —— 它不是"设备列表一变就连"，
/// 那会在用户每加一台设备时都试图连接（见 `app.dart` 的说明）。
///
/// **参数类型是 `WidgetRef` 而不是 `Ref`，这不是随手写的。** 调用点在
/// `ConsumerState` 里，那里的 `ref` 是 `WidgetRef`；而 `Ref` 是 **sealed**
/// （riverpod 的 `core/ref.dart`），`WidgetRef` 只 implements `BaseWidgetRef`
/// —— 两者**没有**子类型关系，写成 `Ref` 编译不过（"The argument type
/// 'WidgetRef' can't be assigned to the parameter type 'Ref'"）。本函数唯一的
/// 用途就是给 widget 层调，所以取 widget 那一侧的 ref 才是诚实的类型。
void connectAutoConnectDevicesAtStartup(WidgetRef ref) {
  connectAutoConnectDevices(
    devices: ref.read(devicesProvider),
    connect: (deviceId) =>
        unawaited(ref.read(sessionProvider(deviceId).notifier).connect()),
  );
}
```

`Ref` 由 `flutter_riverpod` 导出（已在 import 里），`unawaited` 来自 `dart:async`。

- [ ] **Step 4: 跑用例，确认全绿**

Run: `flutter test test/state/providers_test.dart`
Expected: 全部通过（11 条）。

**如果 `删掉设备时它的会话被拆掉` 红**：`ref.invalidate` 触发 `onDispose` 是**异步**的，多等一轮 `Duration.zero` 再断言。

- [ ] **Step 5: 提交**

```bash
git add lib/state/providers.dart test/state/providers_test.dart
git commit -m "$(cat <<'EOF'
feat(state): Riverpod providers —— 设备/设置/草稿/输出/会话

启动结果与 store 集合都靠 main() 覆盖注入，此后没有一个 provider 是异步的：
界面不必为"还没读出来"写一遍在任何一次真实启动里都到不了的分支。

几处刻意的选择：sessionProvider 不 watch 设置（否则改个主题就会重建 controller
并把正在跑的会话拆掉）；devices 的写路径一律先落盘再改内存；reorder 靠重写整个
数组（devices.json 没有 order 字段）；设备 id 由本层生成小写 UUID，不经用户输入。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `lib/app.dart` + `lib/main.dart` —— 真正的装配

**Files:**
- Create: `lib/app.dart`
- Modify: `lib/main.dart`（整个文件替换）
- Test: `test/ui/app_test.dart`

- [ ] **Step 1: 写失败的用例**

创建 `test/ui/app_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/app.dart';
import 'package:win_cli_tool/models/app_settings.dart';
import 'package:win_cli_tool/state/app_paths.dart';
import 'package:win_cli_tool/state/app_stores.dart';
import 'package:win_cli_tool/state/providers.dart';

import '../fixtures/fake_session.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_app_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  testWidgets('外壳能起来，且用上了设置里的主题', (tester) async {
    final stores = AppStores(paths: AppPaths(root));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          startupProvider.overrideWithValue(
            const AppStartup(
              settings: AppSettings(theme: AppTheme.dark),
              devices: [],
            ),
          ),
          sessionFactoryProvider.overrideWithValue(FakeSessionFactory()),
        ],
        child: const WinCliToolApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MaterialApp), findsOneWidget);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark, reason: '主题来自设置');
  });

  testWidgets('启动时不给 autoConnect 的设备发起连接', (tester) async {
    // `app.dart` 只在首帧后跑一次 FR-C-14 的那次扫描，而这里一台设备都没有。
    final factory = FakeSessionFactory();
    final stores = AppStores(paths: AppPaths(root));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          startupProvider.overrideWithValue(
            const AppStartup(settings: AppSettings(), devices: []),
          ),
          sessionFactoryProvider.overrideWithValue(factory),
        ],
        child: const WinCliToolApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(factory.sessions, isEmpty);
  });
}
```

- [ ] **Step 2: 跑用例，确认它红**

Run: `flutter test test/ui/app_test.dart`
Expected: 编译失败（`lib/app.dart` 不存在）。

- [ ] **Step 3: 写 `app.dart`**

创建 `lib/app.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/app_settings.dart';
import 'state/providers.dart';

/// 应用外壳：主题、`MaterialApp`、以及启动后**一次**的副作用。
///
/// **计划 5a 到此为止 —— 界面在 5b。** 这里的 `home` 是一个明确写着"界面还没
/// 做"的占位页，不是脚手架残留：它证明装配是通的（设置读得到、provider 建得
/// 起来、生命周期跑得完），而 5b 把 `MainWindow` 换进来时只需要动这一个字面量。
class WinCliToolApp extends ConsumerStatefulWidget {
  const WinCliToolApp({super.key});

  @override
  ConsumerState<WinCliToolApp> createState() => _WinCliToolAppState();
}

class _WinCliToolAppState extends ConsumerState<WinCliToolApp> {
  @override
  void initState() {
    super.initState();
    // FR-C-14：启动时对 `autoConnect == true` 的设备各发起一次连接。
    //
    // 放在**首帧之后**（`addPostFrameCallback`）而不是 `initState` 里直接调：
    // 那一次扫描会 `ref.read(sessionProvider(...))`，而建 provider 的过程里
    // 会分配资源；在首帧之前做这些，用户看到的第一帧会被推迟（NFR-F-04）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      connectAutoConnectDevicesAtStartup(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(settingsProvider.select((s) => s.theme));

    return MaterialApp(
      title: '网络设备命令行工具',
      themeMode: switch (theme) {
        AppTheme.system => ThemeMode.system,
        AppTheme.light => ThemeMode.light,
        AppTheme.dark => ThemeMode.dark,
      },
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
      ),
      home: const _PlaceholderPage(),
    );
  }
}

/// 计划 5b 会用真正的主窗口换掉它。**别在这里长东西。**
class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('网络设备命令行工具')),
    body: const Center(child: Text('界面尚未实现（计划 5b）')),
  );
}
```

- [ ] **Step 4: 换掉 `main.dart`**

把 `lib/main.dart` **整个文件**替换为：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'state/app_paths.dart';
import 'state/app_stores.dart';
import 'state/providers.dart';

Future<void> main() async {
  // `path_provider` 走平台通道，必须先初始化绑定。
  WidgetsFlutterBinding.ensureInitialized();

  // NFR-P-04：Windows 在 `%APPDATA%` 下、Linux 在 `$XDG_DATA_HOME`
  // （默认 `~/.local/share`）下的应用子目录。
  final paths = AppPaths(await getApplicationSupportDirectory());
  final stores = AppStores(paths: paths);

  // **启动时把设备与设置一次性读出来**，此后所有 provider 都是同步的
  // （见 `AppStartup` 的文档）。
  //
  // 读失败不在这里兜：两个 store 的 `load()` 自己就把"文件坏了"变成
  // `LoadIssue` + 空配置（NFR-R-03），所以这里拿到的永远是个能用的结果 ——
  // 而那一堆 issue 会经 `issuesProvider` 展示给用户。
  //
  // 注意 `FileHostKeyStore` **不在**这里读：它与那两个 store 相反，坏了就
  // 响亮地失败（丢一条已知主机密钥 = 用户会在没被告知的情况下被重新问一次
  // 指纹）。它由第一次连接时的 `find()` 触发，失败会经 `ConnectionFailure`
  // 变成用户看得见的一句话。
  final deviceResult = await stores.devices.load();
  final settingsResult = await stores.settings.load();

  runApp(
    ProviderScope(
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
      ],
      child: const WinCliToolApp(),
    ),
  );
}
```

**注意**：`sessionFactoryProvider` **没有**在这里覆盖 —— 它的默认实现已经把
`FileHostKeyStore`、超时与 `verifySshHostKey` 接好了（那是它存在的理由）。
`onUnknownHostKey`（FR-C-11 的首次指纹确认）需要一个对话框，那是 5b 的事；
在那之前它保持 null，语义是**一律拒绝**（`SshSession.onUnknownHostKey` 的
文档），也就是"连不上"而不是"静默接受" —— 安全的那一侧。

- [ ] **Step 5: 跑用例，确认全绿**

Run: `flutter test test/ui/app_test.dart`
Expected: 全部通过（2 条）。

- [ ] **Step 6: 确认没有把 `flutter` 带进核心层**

Run: `grep -rn "package:flutter" lib/data lib/connection lib/command lib/render lib/models`
Expected: **无输出**。NFR-M-01 要求核心逻辑是纯 Dart、可脱离界面单测 —— `lib/state/` 与 `lib/app.dart` 是唯一允许 import `flutter` 的地方（`lib/state/` 只 import `flutter_riverpod`，那也是 flutter 生态；核心四层一个都不能碰）。

- [ ] **Step 7: 提交**

```bash
git add lib/app.dart lib/main.dart test/ui/app_test.dart
git commit -m "$(cat <<'EOF'
feat(app): 真正的 main() 与根 widget，把四层装起来

main() 在 runApp 之前把设备与设置一次性读出来并经 ProviderScope 注入，此后
所有 provider 都是同步的。app.dart 只做三件事：主题、MaterialApp、首帧后跑一次
FR-C-14 的自动连接扫描。home 是一个明确标注"计划 5b"的占位页，不是脚手架残留。

sessionFactoryProvider 不在 main 里覆盖：它的默认实现已经接好了密钥库、
超时与 verifySshHostKey（NFR-S-03 默认开启）。onUnknownHostKey 暂时为 null，
语义是一律拒绝 —— 安全的那一侧。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: 端到端装配验证（无头）

**为什么：** 前九个任务各自绿了，不代表**装起来**是通的。这一条用**真的** store（临时目录）、真的 `AppStores`、真的 provider 容器，只有会话层换成夹具，走一遍：启动读盘 → 加设备 → 连接 → 设备吐输出 → 输出进缓冲 + 落日志 → 断线 → 重连 → 切设备各自的缓冲互不串 → 退出。它验的是"缝"，不是任何单个单元。

**Files:**
- Test: `test/state/assembly_e2e_test.dart`

- [ ] **Step 1: 写用例**

创建 `test/state/assembly_e2e_test.dart`：

```dart
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
```

- [ ] **Step 2: 跑用例**

Run: `flutter test test/state/assembly_e2e_test.dart`
Expected: 4 条全绿。**如果红**，多半是两处时序：`container.dispose()` 之后
`ref.onDispose` 里的 `_controller.dispose()` 是异步的（多 `await` 一轮
`Duration.zero`）；或 A 的重连退避第一档正好 1s，`Future.delayed(2s)` 要留够。

- [ ] **Step 3: 全仓跑一遍 + 分析器**

Run: `flutter test`
Expected: 全绿（计划 4 收尾时是 372 条，本计划加上新增用例）。

Run: `dart analyze lib/ test/`
Expected: `No issues found!`

- [ ] **Step 4: 提交**

```bash
git add test/state/assembly_e2e_test.dart
git commit -m "$(cat <<'EOF'
test(state): 无头端到端装配验证

用真 store（临时目录）+ 真 provider 容器、只把会话层换成夹具，走一遍启动读盘 →
加设备 → 连接 → 输出进缓冲并落日志 → 断线重连 → 两台设备缓冲互不串 → 容器
dispose 关掉会话。验的是缝，不是任何单个单元。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## 完成标准

1. `flutter test` 全绿；`dart analyze lib/ test/` 输出 `No issues found!`。
2. `grep -rn "package:flutter" lib/data lib/connection lib/command lib/render lib/models` **无输出**（NFR-M-01）。
3. Task 1 / 2 / 3 的三条修复各有**点名变红过**的用例钉着（提交信息里写了各自的失败形状）。
4. `lib/state/` 下每个类都有一条不经过 widget 的用例。
5. `lib/main.dart` 不再是 Flutter 计数器模板。

## 未决项（**不在本计划解决**，5b 或用户拍板）

1. **决策 B / FR-C-06：`failed`（红）在产品里何时可达。** `autoReconnect` 默认 true 且没有生产代码传 false，所以 `failed` 永远到不了 —— 红按钮不会被点亮，与 FR-C-06 冲突。两种读法（首次建连失败也走退避 vs 立即变红）需要选一个；若选前者还要**新增一个设置项**来承载 `autoReconnect`，而 FR-G-01 的设置清单里没有它。`ConnectionManager` 的行为本计划**一个字没改**。
2. **`spec §13.10`：翻页状态在超时/批次结束后丢失。** 三个方案里倾向方案 2（不自动处理，改为向界面抛「设备停在翻页」事件）。它会**新增一个事件**，直接影响界面显示逻辑，所以应在 5b 之前定。
3. **`onUnknownHostKey` 暂时为 `null`**（Task 9 的说明）。语义是一律拒绝 —— 安全的那一侧，但**FR-C-11 的"首次连接显示指纹供确认"要等 5b 的对话框**。
4. **`Snippet` 的 `==`/`hashCode`。** 三个模型都没有值相等，`Snippet` 字段最少、最可能被 keyed，若要补优先补它。5b 做命令库列表时若需要 keyed，再补。
5. **`ESC ( B`（选择字符集）在 `stripAnsi` 与 `parseAnsi` 里都不被剥离**（计划 4 记录的既有问题）。两边**至少是一致的**，所以 §5.6 不受影响；输出区会看到这三个字节。修它要动已冻结的 `ansi.dart`。
6. **`TelnetSession.connect()` 没有入口守卫**（守卫在 `connector.open(...)` 之后，与 `SshSession` 不一致），以及 `Session` 契约没写「`connect()` 抛了之后仍需 `close()`」—— 计划 3 取消后这两条"顺手项"没有归属。本计划**没碰** `telnet_session.dart`。
7. **`connection_manager.dart:280` 的 `onError: (Object _) {}`** 是静默吞掉的保险。评审结论是"留着"；真触发时没有事件、没有日志、**别指望它报信**。
8. **`autoConnect` 的启动扫描只在首帧后跑一次**（`app.dart`）。5b 若要让"用户新加一台 `autoConnect: true` 的设备"也立即连接，需要另加触发点 —— 本计划**有意**不做（那会让"每加一台设备都试图连接"）。
9. **`LogWriter._flush` 的写盘失败可能报两次**，而 FR-L-06 要的是"提示**一次**"。`_failed` 只在函数入口查一次，之后要 `await` `stat()` / `create()`；两次 `_flush` 撞进这个窗口时（一次由 32 行阈值触发、一次由 `end()` 强制）会各自失败、各调一次 `onError`。实测 4/4 复现：喂 40 行再 `disconnect()` ⇒ **2 次**回调。修法是入口加一个"正在落盘"的守卫（或把 `_failed` 提到 `await` 之前）。**`LogWriter` 是计划 4 的已合并代码，本计划一个字没碰** —— Task 7 的用例因此只喂一次写盘尝试。
10. **`SessionController.state`（同步，直接问 manager）与 `SessionStatus.state`（异步镜像）是两个真相来源**，会差一个事件回合（Task 7 的用例里实测到）。5b 的按钮颜色与状态显示必须**有意地**挑一个用，别混着用 —— 混用会出现"按钮说连上了、横幅还在转圈"这种自相矛盾的画面。

## 后续计划

- **计划 5b（界面）**：`lib/ui/` 的 `main_window.dart`、四个面板、三个对话框、通用组件、四个快捷键，以及 spec §9.2 的六条界面行为测试。它会**换掉** `lib/app.dart` 里那个 `_PlaceholderPage`。本计划为它准备好的接缝：`SessionStatus`（按钮颜色/倒计时/进度/丢弃数）、`OutputBuffer.lines`（`List<List<AnsiSpan>>` → `TextSpan`）、`issuesProvider`（加载问题展示）、`FileHostKeyStore.all()`（FR-G-01 的设置项）。
- **计划 6（打包与 CI）**：Windows 构建途径仍挂在 spec 的待办表上。
