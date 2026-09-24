import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/draft_store.dart';

/// **以 root 跑测试时，"读失败"构造不出来** —— root 能读任何文件，`chmod 000`
/// 拦不住它。需要这条形状的用例要跳过，否则会因为"什么都没失败"而假红。
/// 用 `id -u` 而不是 `Platform.environment['USER']`：后者在 `su`/容器里不可靠。
final bool isRoot = () {
  final result = Process.runSync('id', ['-u']);
  return result.exitCode == 0 && (result.stdout as String).trim() == '0';
}();

void main() {
  late Directory root;
  late Directory dir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_drafts_');
    dir = Directory('${root.path}/drafts');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  DraftStore store() => DraftStore(dir: dir);

  test('没写过时返回空串（首次启动就是这个形状，不是错误路径）', () async {
    expect(await store().read('d1'), '');
  });

  test('写进去什么，读回来什么（多行 / CRLF / 中文 / 首尾空行）', () async {
    const text = 'sys\ninterface Vlanif1\n description 核心链路\r\n\n';
    await store().write('d1', text);
    expect(await store().read('d1'), text);
  });

  test('真的落盘了：换一个实例也读得到', () async {
    await store().write('d1', 'save');
    expect(await store().read('d1'), 'save');
  });

  test('两台设备互不干扰（FR-E-03）', () async {
    final s = store();
    await s.write('d1', '给第一台');
    await s.write('d2', '给第二台');
    expect(await s.read('d1'), '给第一台');
    expect(await s.read('d2'), '给第二台');
  });

  test('写空串 = 清空草稿，读回来是空串（不是"没写过"）', () async {
    final s = store();
    await s.write('d1', '有内容');
    await s.write('d1', '');
    expect(await s.read('d1'), '');
    expect(Directory(dir.path).listSync(), hasLength(1));
  });

  test('delete 之后文件真的没了，read 回到空串', () async {
    final s = store();
    await s.write('d1', '内容');
    await s.delete('d1');
    expect(await s.read('d1'), '');
    expect(dir.listSync(), isEmpty);
  });

  test('delete 不存在的设备不抛', () async {
    await store().delete('从来没有过');
  });

  test('id 里的 / 与 \\ 不会让文件跑到草稿目录外面去', () async {
    final s = store();
    await s.write('../evil', '穿越');
    await s.write(r'a\b', '穿越2');
    await s.write('/etc/passwd', '穿越3');

    expect(dir.listSync(), hasLength(3), reason: '三个都落在 drafts/ 里');
    expect(File('${root.path}/evil.txt').existsSync(), isFalse);
    expect(File('/etc/passwd.txt').existsSync(), isFalse);
    // 目录名保持不变，没有被 "../" 顶掉
    expect(Directory(dir.path).existsSync(), isTrue);
  });

  test('两个会碰撞的 id 落到两个不同的文件（FR-E-03 的独立性）', () async {
    final s = store();
    await s.write('a/b', '斜杠那份');
    await s.write('a_b', '下划线那份');
    expect(dir.listSync(), hasLength(2));
    expect(await s.read('a/b'), '斜杠那份');
    expect(await s.read('a_b'), '下划线那份');
  });

  test('id 是 ".." 也不会顶到上级目录（文件名后缀挡住了）', () async {
    final s = store();
    await s.write('..', '内容');
    expect(dir.listSync(), hasLength(1));
    expect(await s.read('..'), '内容');
    expect(root.listSync().map((e) => e.path.split('/').last).toSet(),
        {'drafts'});
  });

  test('草稿文件不是 UTF-8 时抛 DraftUnreadableException，而不是静默给空串', () async {
    Directory(dir.path).createSync(recursive: true);
    await File('${dir.path}/d1.txt').writeAsBytes([0xFF, 0xFE, 0x41]);
    expect(
      () => store().read('d1'),
      throwsA(
        isA<DraftUnreadableException>().having((e) => e.deviceId, 'deviceId', 'd1'),
      ),
    );
  });

  test('草稿文件存在但读不出来（权限）：也抛 DraftUnreadableException', () async {
    // 这条钉的是 `read` 里那个 **`readAsBytes()` 必须在 try 里面** 的决定。
    // 放到外面的话（本文件改动前的形状），这里逃出去的是原始 PathAccessException，
    // 而调用方（计划 5）catch 的正是 DraftUnreadableException —— 于是它接不到
    // 这一类，用户看到一个没头没脑的文件系统错误。
    // **实测过**：把 `readAsBytes()` 挪回 try 外面，另外 12 条用例**全绿**，
    // 只有这一条会红 —— 整条"读盘失败也算读不出来"的约定此前没有任何用例钉着。
    Directory(dir.path).createSync(recursive: true);
    final file = File('${dir.path}/d1.txt')..writeAsStringSync('内容');
    Process.runSync('chmod', ['000', file.path]);

    expect(
      () => store().read('d1'),
      throwsA(
        isA<DraftUnreadableException>()
            .having((e) => e.deviceId, 'deviceId', 'd1')
            .having((e) => e.cause, 'cause', isA<FileSystemException>()),
      ),
    );
  }, skip: isRoot ? '以 root 运行：chmod 拦不住 root，构造不出"读失败"' : null);

  test('落盘文件权限是 0600（NFR-S-04）', () async {
    await store().write('d1', '内容');
    expect((await File('${dir.path}/d1.txt').stat()).mode & 0x1FF, 0x180);
  });
}
