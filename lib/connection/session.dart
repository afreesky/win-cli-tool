/// 与一台设备的一条会话。
abstract class Session {
  /// 会话输出流。已完成 UTF-8 解码，且已剥离传输层的协商字节。
  Stream<String> get output;

  /// 会话意外断开时完成。主动调用 [close] 不会触发它。
  ///
  /// **刻意不`completeError`**：断开原因是给用户看的诊断信息，不是控制流
  /// 信号 —— 以错误完成会强迫每个 `await done` 的人都处理它，而无人监听的
  /// `completeError` 还会变成未捕获的异步错误。原因改由 [lastError] 携带
  /// （spec §13.12 给的正是这两个选项，选了后者）。
  Future<void> get done;

  /// 最近一次意外断开的原始错误（FR-C-06 / spec §13.12）。正常断开为 null。
  ///
  /// 与 [done] 配合使用：`done` 完成之后读它。**刻意是抽象成员，不给
  /// `=> null` 默认实现** —— 默认值会让一个新的实现静默地返回 null，而
  /// 「失败了，但不知道为什么」正是这个字段要消灭的那个缺陷（spec §13.20）。
  /// 调用方（`ConnectionManager`）只认 [Session] 这个类型，所以它必须在这里，
  /// 而不是只在某个实现类上。
  Object? get lastError;

  /// 建立连接。
  Future<void> connect();

  /// 写入一段文本。行尾符由调用方负责。
  void write(String text);

  /// 关闭会话。
  ///
  /// **`connect()` 失败之后，调用方仍然必须调它。** 两个实现都在 `connect()`
  /// 里分配了资源（`_dataBytes`/`_output` 两个 `StreamController`，Telnet 侧
  /// 还可能有一个已经拿到的连接），而"连不上"是最常见的路径之一 ——
  /// `ConnectionManager` 每次都靠 [close] 来收尾。契约原先没写这一条，
  /// 于是"connect 抛了，那就不用 close 了吧"看起来是合理的，而它会让
  /// 那些 `StreamController` 永远挂着（spec §13.21-4）。
  ///
  /// `close()` 是幂等的：已经关过的会话再关一次直接返回。
  Future<void> close();
}
