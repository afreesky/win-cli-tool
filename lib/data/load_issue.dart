/// 持久化层加载时发现的问题。**必须上报给用户**，不能只写日志：
/// 每一条都对应一件用户需要知道的事（数据没读全 / 被迁移 / 某个意图被忽略）。
///
/// 放在独立文件里而不是各自的 store 里，是因为 `DeviceStore` 与
/// `SettingsStore` 都要用它。两个 store 各自定义一份的话，「整个文件坏了」
/// 在两处的含义会慢慢漂开，而用户看到的是同一类提示。
enum LoadIssueKind {
  /// 某一条记录坏了，已跳过。其余记录不受影响。
  corruptEntry,

  /// 整个文件读不出设备，按空配置启动。
  ///
  /// **留档与否取决于是哪一步发现的**，别照字面读成"一定留了档"：解析失败那条路
  /// 会 `quarantine()`；`devices` 数组缺失或形状不对那条路**不留档** —— 那种文件是
  /// **可以手改修好的**（键名写成 `Devices` 就是这样），改名留档反而先把用户的原件
  /// 挪走了。代价是它可能被下一次 `save()` 覆盖掉，这是知情的取舍，不是疏忽。
  corruptFile,

  /// 文件是更老的版本（或没有版本号），已按当前语义读入。
  migrated,

  /// 这台设备写了 `jumpHostIds`，但 V1 不支持跳板机 —— 它会**直连**。
  /// 不上报的话，用户以为走了堡垒机，实际没走，而且看不出来（spec §8.6）。
  jumpHostIgnored,

  /// 文件的 `schemaVersion` 比本程序认识的新。仍然按当前语义读，
  /// 但可能读错 —— 沉默地读错比报错更糟。
  newerSchema,
}

/// 一条加载问题。[message] 面向用户，必须能直接展示。
class LoadIssue {
  const LoadIssue(this.kind, this.message);

  final LoadIssueKind kind;
  final String message;

  @override
  String toString() => 'LoadIssue(${kind.name}): $message';
}
