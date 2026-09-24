import 'dart:io';

import '../connection/known_host.dart';
import 'json_file.dart';

/// 已知主机密钥的落盘实现（FR-C-11「首次连接确认后保存」）。
///
/// 实现的是计划 2 冻结的 [HostKeyStore] 接口，条目形状也与计划 2 的测试
/// 一致 —— 见 spec §13.5。文件形状是本计划定的：
/// `{"schemaVersion": 1, "hosts": [ {host, port, keyType, fingerprint} ]}`。
class FileHostKeyStore implements HostKeyStore {
  FileHostKeyStore({required this.file});

  final File file;

  /// 内存索引：`(host, port, keyType)` → 记录。
  ///
  /// **键是元组，不是 `'$host:$port:$keyType'` 拼接串。** spec §13.5 给了两个
  /// 修法，这里选的是"结构上不可能碰撞"那一个：拼接串的不变式要靠**三处**
  /// 同时成立才守得住（构造函数拒绝含冒号的 keyType + find/remove 不校验 +
  /// identity 的拼法），而这三处已经出现过一处不设防的形状。元组把它变成
  /// 类型系统的事。
  ///
  /// **缓存只会保存"已经落盘"的内容，而且不会失效。** `save`/`remove` 都是
  /// **写盘成功之后**才换缓存，所以进程内的状态永远不会领先于文件 —— 写盘失败时
  /// 抛出去的东西与磁盘是一致的（见 [save]）。代价有两个，与 `DeviceStore` 的
  /// 同款警告是一回事：**同一个文件不要建两个实例**（后写的会盖掉先写的），
  /// 以及一个长命实例的 [all] 是快照、文件被外部改了它不会重读。计划 5 的装配
  /// 只建一个，别改。
  Map<(String, int, String), KnownHost>? _cache;

  @override
  Future<KnownHost?> find(String host, int port, String keyType) async =>
      (await _load())[(host, port, keyType)];

  /// **先写盘，成功了才换缓存**（顺序不能反）。
  ///
  /// 反过来写（先改 `_cache` 再 `_persist`）在写盘失败时会留下一条"进程内说有、
  /// 文件里没有"的记录：`find` 会把它当已知主机直接放行，设置界面（FR-G-01）也会
  /// 把它列出来，而**重启之后它就不见了**。已知主机记录悄悄消失正是本类最想避免
  /// 的结局（见 [_load] 里那段），所以宁可让缓存晚一步。
  @override
  Future<void> save(KnownHost host) async {
    // 拷一份再改：`_load()` 可能返回的就是 `_cache` 本身，就地改就等于先动了缓存。
    final next = Map.of(await _load())
      ..[(host.host, host.port, host.keyType)] = host;
    await _persist(next);
    _cache = next;
  }

  /// 同样**先写盘，成功了才换缓存**，理由见 [save]。
  ///
  /// 删除失败却换了缓存的话，用户以为已经清掉了那把密钥、文件里却还在 ——
  /// 而"清掉一条已知主机密钥"正是用户遇到真的密钥变更时唯一的出路
  /// （`known_host.dart` 里 [HostKeyStore.remove] 的文档）。
  @override
  Future<void> remove(String host, int port, String keyType) async {
    final map = await _load();
    if (!map.containsKey((host, port, keyType))) return;
    final next = Map.of(map)..remove((host, port, keyType));
    await _persist(next);
    _cache = next;
  }

  /// 全部记录，供 FR-G-01 的「已知主机密钥记录的查看与逐条清除」使用。
  ///
  /// **刻意只加在这个具体类上，没有加到 [HostKeyStore] 接口里。**
  /// 加接口就要改计划 2 已冻结的 `known_host.dart` 与它的围栏，而
  /// "枚举"只有设置界面需要 —— 计划 5 的组合根本来就直接构造这个具体类型，
  /// 拿到的方法是具体类型上的，不涉及向下转型（spec §13.5 的要求是
  /// "别让设置界面去 downcast 具体类型"，从具体类型上直接调用不算）。
  Future<List<KnownHost>> all() async =>
      List.unmodifiable((await _load()).values);

  Future<Map<(String, int, String), KnownHost>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;

    final map = <(String, int, String), KnownHost>{};
    final raw = await readJsonObject(file);
    if (raw != null) {
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
    }
    _cache = map;
    return map;
  }

  Future<void> _persist(Map<(String, int, String), KnownHost> map) async {
    await writeJsonObject(file, {
      'schemaVersion': 1,
      'hosts': map.values.map((h) => h.toJson()).toList(growable: false),
    });
  }
}
