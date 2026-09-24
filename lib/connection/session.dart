/// 与一台设备的一条会话。
abstract class Session {
  /// 会话输出流。已完成 UTF-8 解码，且已剥离传输层的协商字节。
  Stream<String> get output;

  /// 会话意外断开时完成。主动调用 [close] 不会触发它。
  Future<void> get done;

  /// 建立连接。
  Future<void> connect();

  /// 写入一段文本。行尾符由调用方负责。
  void write(String text);

  /// 关闭会话。
  Future<void> close();
}
