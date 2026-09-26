import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 读一个文件的原始字节。
///
/// **做成 provider 是为了可注入。** 「导入文件」（FR-E-15）要读用户磁盘上的
/// 文件，而 widget 测试里没有那个文件；更要紧的是 FR-E-16 那条分支（"不是
/// UTF-8"）—— 测试里换掉本 provider 就能直接喂一段非法字节，不必在临时目录
/// 里造文件再猜它怎么被读。
///
/// 返回 `List<int>` 而不是 `String`：**解码是消费方的事**。这里若先解成字符串，
/// `utf8.decode` 就只剩宽松模式可选，而那正是 FR-E-16 要挡的那件事。
typedef FileBytesReader = Future<List<int>> Function(String path);

final fileReaderProvider = Provider<FileBytesReader>(
  (ref) => (path) => File(path).readAsBytes(),
);
