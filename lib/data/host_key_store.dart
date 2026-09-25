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
