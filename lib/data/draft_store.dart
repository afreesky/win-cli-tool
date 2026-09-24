import 'dart:convert';
import 'dart:io';

import 'json_file.dart';

/// 草稿文件读不出来（不是 UTF-8，或读盘失败）。
///
/// **不降级成空串**：空串会让用户以为"草稿没了"，而其实文件还在、只是编码
/// 不对 —— 那时用户已经把它重打了。宁可让调用方（计划 5）catch 住并提示。
class DraftUnreadableException implements Exception {
  const DraftUnreadableException(this.deviceId, this.cause);

  final String deviceId;
  final Object cause;

  @override
  String toString() => '草稿「$deviceId」读不出来：$cause';
}

/// 编辑区草稿（FR-E-03 / FR-E-04 / FR-D-06）。
///
/// 一台设备一个纯文本文件，文件内容**就是**编辑区内容。理由见计划里这一段
/// 开头的说明：草稿里必然有换行符，任何信封格式都要处理换行的转义往返，
/// 而这里不需要信封 —— 按设备分文件已经把"这是谁的草稿"表达完了。
class DraftStore {
  DraftStore({required this.dir});

  /// `drafts/` 目录。**不必预先存在**，第一次写会建。
  final Directory dir;

  /// 文件名 = `Uri.encodeComponent(deviceId)` + `.txt`。
  ///
  /// 不用 FR-L-05 那种"替换危险字符为下划线"的净化：那会把 `a/b` 与 `a_b`
  /// 映到同一个名字（两台设备共用一份草稿，破坏 FR-E-03）。百分号编码把 `/`
  /// 编成 `%2F`（单个文件名字符），**既单射又不含路径分隔符**。
  /// `..` 这类名字也被 `.txt` 后缀挡住（`...txt` 是普通文件名）。
  ///
  /// **但"单射"是编码函数单射，不等于在文件系统上一定不撞**：
  /// `Uri.encodeComponent` 原样保留字母，所以**不区分大小写的卷**（NTFS、
  /// 默认 APFS）上 `A` 与 `a` 会落到同一个文件 —— 那正是 FR-E-03 要防的
  /// "两台设备共用一份草稿"。另外 `*` 不在它转义的集合里，而 `*` 在 Windows
  /// 上是非法文件名字符（这条会**响亮地失败**，不会静默串档）。
  /// 还有 Windows 的保留设备名：`CON` / `NUL` / `COM1` 这类名字**带上扩展名
  /// 依然保留**（`CON.txt` 还是控制台设备）。它们同样被"小写 UUID"排除在外。
  ///
  /// 所以：**设备 id 由计划 5 生成，必须保证大小写唯一**（小写 UUID 就够），
  /// 不要把它做成用户可自由输入的文本。
  File _fileFor(String deviceId) =>
      File('${dir.path}/${Uri.encodeComponent(deviceId)}.txt');

  Future<String> read(String deviceId) async {
    final file = _fileFor(deviceId);
    if (!await file.exists()) return '';
    // **读盘本身也必须在 try 里。** 放到外面的话，读失败会以原始
    // FileSystemException 逃出去 —— 而上面 [DraftUnreadableException] 的文档
    // 明说读不出来包含"**或读盘失败**"，计划里也写了"宁可让调用方（计划 5）
    // catch 住并提示"：调用方 catch 的正是这个异常，于是它偏偏接不到这一类，
    // 用户看到的是一个没头没脑的文件系统错误。
    //
    // 真实的触发形状是**权限不足**（实测：`chmod 000` 之后这里抛
    // `PathAccessException`，已有用例钉住）。**别把"路径成了目录"也算进来**：
    // `File.exists()` 对目录返回 false，那种形状在上一行的提前返回就走了，
    // 根本到不了这里 —— 它反倒是"读不出来被当成没写过"的一个真实漏洞。
    //
    // 也别写成 `on FormatException catch` 再跟一个裸 catch：`utf8.decode` 只抛
    // FormatException，那个裸分支永远进不去，是**死代码**（实测过）。
    //
    // 自己 decode 而不是 readAsString()：后者在解码失败时抛
    // FileSystemException，那是文件系统的语言（带路径、带编码名），
    // 而调用方需要的是一个能指名"是哪台设备的草稿"的错误。
    try {
      final bytes = await file.readAsBytes();
      return utf8.decode(bytes);
    } catch (e) {
      throw DraftUnreadableException(deviceId, e);
    }
  }

  Future<void> write(String deviceId, String text) async {
    final file = _fileFor(deviceId);
    await file.parent.create(recursive: true);
    // 与 writeJsonObject 同一套原子写：先写临时文件、收紧权限、再改名。
    // 草稿不是关键数据，但"关掉程序时正好写了一半"会让下次启动读到一个
    // 截断的草稿 —— 而用户的第一反应是"这软件把我的配置弄丢了"。
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await restrictToOwner(tmp);
    await tmp.rename(file.path);
    await restrictToOwner(file);
  }

  /// 删除某台设备的草稿（FR-D-06：删除设备时一并删除其草稿）。
  Future<void> delete(String deviceId) async {
    final file = _fileFor(deviceId);
    if (await file.exists()) await file.delete();
  }
}
