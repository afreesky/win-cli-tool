import 'dart:io';

import 'package:clock/clock.dart';

import '../render/ansi_parser.dart';
import 'json_file.dart';

/// 日志文件名的净化（FR-L-05）。**替换 → 去首尾空白与点号 → 截断到 64。**
///
/// 截断之后再修一次尾点：FR-L-05 把截断排在最后，而"第 64 个字符恰好是点号"
/// 是可能的（`'a'*63 + '.' + 'b'*10`）—— 那时 Windows 会把这个尾点吃掉，
/// 落盘的文件名与 `file.path` 对不上。修完仍然 ≤64，两条要求都满足。
String sanitizeLogFileName(String deviceName) {
  var name = deviceName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  name = name.replaceAll(RegExp(r'^[\s.]+'), '').replaceAll(RegExp(r'[\s.]+$'), '');
  if (name.length > 64) name = name.substring(0, 64);
  name = name.replaceAll(RegExp(r'[\s.]+$'), '');
  return name.isEmpty ? '未命名设备' : name;
}

/// `YYYY-MM-DD HH:mm:ss.SSS`，本地时间（§5.6）。
String _stamp(DateTime t) {
  String p(int n, int width) => n.toString().padLeft(width, '0');
  return '${t.year}-${p(t.month, 2)}-${p(t.day, 2)} '
      '${p(t.hour, 2)}:${p(t.minute, 2)}:${p(t.second, 2)}.'
      '${p(t.millisecond, 3)}';
}

/// 一次会话的日志（FR-L-01~07）。
///
/// **一次会话一个实例**，会话结束调 [end]。FR-L-07（设置里关日志）由调用方
/// 决定要不要构造 —— 本类不做开关。
class LogWriter {
  LogWriter({
    required this.rootDir,
    required this.deviceName,
    this.onError,
    this.flushEveryLines = 32,
  });

  /// 日志根目录（计划 5 从设置里取，见 FR-L-02 的"根目录为应用数据目录"）。
  final Directory rootDir;

  final String deviceName;

  /// 写盘失败时调用**一次**（FR-L-06 的"失败时在输出区提示一次"）。
  ///
  /// **实现方不要在这里抛异常。** 它在 `_flush` 的 `catch` 里被**同步**调用，
  /// 抛出去就会从 `write()` / `end()` 冒到会话循环里 —— 那正是 FR-L-06 要避免的
  /// "日志坏掉拖垮会话"。要弹提示就把异常的处置留在回调内部。
  final void Function(Object error)? onError;

  /// 攒够多少行就落盘。可注入是为了让测试不必写 32 行才能观察缓冲。
  final int flushEveryLines;

  final _buffer = <String>[];
  File? _file;
  bool _started = false;
  bool _closed = false;
  bool _failed = false;

  /// 日志文件。`start()` 之前为 null。
  File? get file => _file;

  /// 会话开始（FR-L-04）。**日期目录在这一刻定死** —— 一次会话跨过午夜也只写
  /// 同一个文件，否则一次操作会被劈成两半。
  Future<void> start(String description) async {
    if (_started || _closed) return;
    _started = true;
    final at = clock.now();
    _file = File(
      '${rootDir.path}/${_stamp(at).substring(0, 10)}/'
      '${sanitizeLogFileName(deviceName)}.log',
    );
    // 这一行**没有** `[时间戳] ` 前缀，与 §5.6 逐字一致 —— 别顺手统一。
    _buffer.add('===== 会话开始 ${_stamp(at)} ($description) =====');
    await _flush();
  }

  /// 会话输出。文本会先剥离控制符。
  ///
  /// 剥离规则来自 `render/ansi_parser.dart`，与输出区**同源** —— 输出区要颜色
  /// 所以调 [parseAnsi]，这里只要文本所以调 [stripToPlainText]（就是它的拼接）。
  /// §5.6 的「与输出区所见一致」因此不靠两边各自遵守约定。
  /// 别换回 `render/ansi.dart` 的 `stripAnsi`（命令层在用）：它在不含 ESC 的
  /// 输入上会提前返回、把 `\r` 留下，日志就与输出区不一致了。
  ///
  /// **前提是"喂进来的边界相同"**：剥离函数每次调用独立，把一条控制序列从中间
  /// 切开分两次调用，后一次会把前半个序列当普通文本留下（实测
  /// `'\x1b['` + `'31mred'` → `'\x1b[31mred'`）。所以计划 5 要么**按行**调用
  /// （一行之内不会有半个序列，除非设备把序列跨行发），要么让输出区与日志
  /// 从**同一处缓冲**取文本 —— 别让两边各自攒各自的。
  Future<void> write(String text) async {
    if (!_started || _closed) return;
    final clean = stripToPlainText(text);
    if (clean.isEmpty) return;
    // 末尾换行会在 split 后留下一个空尾元素，那只是行尾符的产物，丢掉它；
    // 中间的空白行是真实内容，保留。
    final parts = clean.split('\n');
    if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
    final prefix = '[${_stamp(clock.now())}] ';
    for (final line in parts) {
      _buffer.add('$prefix$line');
    }
    await _flush();
  }

  /// 连接断开（FR-L-04）。
  Future<void> disconnected() async {
    if (!_started || _closed) return;
    final at = _stamp(clock.now());
    _buffer.add('[$at] !!! 连接断开 $at ！！！');
    await _flush();
  }

  /// 重连成功（FR-L-04）。
  Future<void> reconnected() async {
    if (!_started || _closed) return;
    final at = _stamp(clock.now());
    _buffer.add('[$at] === 重连成功 $at ===');
    await _flush();
  }

  /// 会话结束，并把缓冲全部落盘。
  Future<void> end() async {
    if (!_started || _closed) return;
    _closed = true;
    final at = _stamp(clock.now());
    _buffer.add('[$at] ===== 会话结束 $at =====');
    await _flush(force: true);
  }

  /// 落盘。**默认只在攒够 [flushEveryLines] 行时真写**（FR-L-06 的缓冲）。
  ///
  /// 唯一的强制点是 [end]：会话结束必须把剩下的全写出去。注意 [start] **不是**
  /// 强制点 —— 一次会话只发了一行头就被杀掉时磁盘上什么都没有，这正是"带缓冲"
  /// 的代价，spec 选了缓冲就必须接受它。别为了"头一行马上可见"把 start 改成
  /// 强制，那会让"缓冲"退化成"逐行 flush"。
  Future<void> _flush({bool force = false}) async {
    if (!force && _buffer.length < flushEveryLines) return;
    final target = _file;
    if (_buffer.isEmpty || target == null || _failed) {
      _buffer.clear();
      return;
    }
    final lines = List<String>.of(_buffer);
    _buffer.clear();
    try {
      // 判据是**"当前权限对不对"**，不是"文件是不是这次新建的"。
      // 用后者会留下一个补不回来的窗口：进程在 `writeAsString` 与
      // `restrictToOwner` 之间被杀掉（或文件被外部以更松的权限重建），此后每次
      // flush 都会看到"文件已存在"而跳过收紧 —— 一个装着设备配置的日志就**永久**
      // 停在 umask 默认的 0644 上，而 NFR-S-04 存在的理由正是这些文件。
      // `stat()` 本来就要调（原先是拿它判存在），顺带看一眼 mode 不额外花钱；
      // 权限已经对了就不 chmod —— 每次追加都 chmod 是每次 flush 起一个进程，
      // 一次长时间的会话能起几万个。
      final stat = await target.stat();
      await target.parent.create(recursive: true);
      await target.writeAsString(
        '${lines.join('\n')}\n',
        mode: FileMode.append,
        flush: true,
      );
      final loose = stat.type == FileSystemEntityType.notFound ||
          (stat.mode & 0x1FF) != 0x180;
      if (loose) await restrictToOwner(target);
    } catch (e) {
      // **一次失败就停**（FR-L-06）：磁盘满 / 无权限会一直失败，每行回调一次
      // 会把输出区刷爆，而用户从第一条提示就已经知道了。停掉之后本类不再碰
      // 磁盘，会话照常跑 —— 日志坏掉绝不能拖垮会话。
      _failed = true;
      onError?.call(e);
    }
  }
}
