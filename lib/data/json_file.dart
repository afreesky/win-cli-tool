/// 五个 store 共用的 JSON 文件工具。
///
/// 抽出来的动机不是"少写几行"，而是这三件事**必须**在每个 store 里一致：
/// 损坏怎么算、写盘怎么保证不半截、权限怎么收紧。三处各写一遍就会出现
/// "设备文件留了档、设置文件没留"这种不对称，而用户只会看到其中一个。
///
/// （`library;` 与它的文档注释必须在 `import` **之前**：Dart 要求库指令先于
/// 所有其它指令，放在后面是编译错误 `library_directive_not_first`。）
library;

import 'dart:convert';
import 'dart:io';

/// 读一个 JSON 对象文件。**文件不存在或内容全空白时返回 null**，不抛异常 ——
/// 首次启动就是这个形状，它必须走正常路径而不是错误路径。
///
/// 只接受顶层是 JSON 对象的文件；数组、数字、字符串一律按损坏抛
/// [FormatException]。三个格式都是对象信封（`{"schemaVersion": …}`），
/// 放行别的形状只会让后续转型在更深的地方炸，报错位置离原因更远。
Future<Map<String, Object?>?> readJsonObject(File file) async {
  if (!await file.exists()) return null;
  final text = await file.readAsString();
  if (text.trim().isEmpty) return null;
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, Object?>) {
    throw FormatException('顶层不是 JSON 对象', file.path);
  }
  return decoded;
}

/// 原子写一个 JSON 对象：先写同目录的 `.tmp`，`flush` 之后再 rename 覆盖。
///
/// **不要改回 `writeAsString` 直写。** 直写在中途失败（磁盘满、进程被杀）
/// 会留下一个被截断的文件，下次启动读到的就是"损坏的配置"—— 于是
/// NFR-R-03 的恢复路径被自己的写入方式反复触发，用户看到的是"配置又坏了"，
/// 而真正的原因在写的那一侧。同目录 rename 是原子的（同文件系统内）。
Future<void> writeJsonObject(File file, Map<String, Object?> json) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(
    const JsonEncoder.withIndent('  ').convert(json),
    flush: true,
  );
  await restrictToOwner(tmp);
  await tmp.rename(file.path);
  // rename 一般保留 inode 的权限位；但目标已存在时某些实现会先删后建，
  // 于是这里对最终路径再设一次。多一次 chmod 是廉价的。
  await restrictToOwner(file);
}

/// 把文件权限收紧到 0600（仅属主可读写）。对应 NFR-S-04。
///
/// **Windows 上是空操作，不是"尽力而为"。** Windows 没有 `chmod`，
/// 起进程调它只会拿到一个非零退出码；NFR-S-04 只要求 Linux，所以这里
/// 显式跳过，而不是在 Windows 上每次写文件都抛一个用户无法处理的异常。
Future<void> restrictToOwner(File file) async {
  if (Platform.isWindows) return;
  final result = await Process.run('chmod', ['600', file.path]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      '无法把权限收紧到 0600：${result.stderr}',
      file.path,
    );
  }
}

/// 把损坏的文件改名留档（`<文件名>.bad-<ISO 时间>`），返回留档后的文件；
/// 原文件不存在时返回 null。
///
/// **留档而不是删除。** NFR-R-03 说的是"备份损坏文件并以空配置启动"——
/// 文件里可能还有用户手写的二十台设备，只是其中一条坏了；删掉就把
/// 可恢复的数据一起扔了。留档名里的冒号要换掉，否则 Windows 上是非法文件名。
Future<File?> quarantine(File file, {required DateTime now}) async {
  if (!await file.exists()) return null;
  final stamp = now.toIso8601String().replaceAll(':', '-');
  return file.rename('${file.path}.bad-$stamp');
}
