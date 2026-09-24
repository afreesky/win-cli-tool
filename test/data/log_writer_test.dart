import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/log_writer.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_logs_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  final t0 = DateTime(2026, 9, 24, 14, 30, 12, 1);

  LogWriter writer({
    String deviceName = 'CoreSW',
    void Function(Object)? onError,
    int flushEveryLines = 32,
  }) =>
      LogWriter(
        rootDir: root,
        deviceName: deviceName,
        onError: onError,
        flushEveryLines: flushEveryLines,
      );

  Future<String> logged(LogWriter w) async => (await w.file!.readAsString());

  test('会话开始行的形状与 §5.6 一致，且**没有** [时间戳] 前缀', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.end();
      final text = await logged(w);
      expect(
        text.split('\n').first,
        '===== 会话开始 2026-09-24 14:30:12.001 (ssh admin@10.0.0.1:22) =====',
      );
    });
  });

  test('路径是 <root>/logs 由调用方给，内部是 <日期>/<设备名>.log（FR-L-02）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      expect(w.file!.path, '${root.path}/2026-09-24/CoreSW.log');
    });
  });

  test('write 每行一个 [时间戳] 前缀，末尾换行不产生空行', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('[CoreSW]\n');
      await w.write('Enter system view, return user view with Ctrl+Z.\n');
      await w.end();
      final lines = (await logged(w)).split('\n');
      expect(lines[1], '[2026-09-24 14:30:12.001] [CoreSW]');
      expect(lines[2],
          '[2026-09-24 14:30:12.001] Enter system view, return user view with Ctrl+Z.');
      expect(lines[3], startsWith('[2026-09-24 14:30:12.001] ===== 会话结束'));
    });
  });

  test('中间的空行按原样保留（不静默丢内容）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('a\n\nb');
      await w.end();
      final lines = (await logged(w)).split('\n');
      expect(lines[1], '[2026-09-24 14:30:12.001] a');
      expect(lines[2], '[2026-09-24 14:30:12.001] ');
      expect(lines[3], '[2026-09-24 14:30:12.001] b');
    });
  });

  test('日志里落的是剥离控制符后的文本（§5.6「与输出区所见一致」）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('\x1b[1m[CoreSW]\x1b[0m\r\n');
      await w.end();
      final lines = (await logged(w)).split('\n');
      expect(lines[1], '[2026-09-24 14:30:12.001] [CoreSW]',
          reason: 'SGR 与 \\r 都不该出现在日志里');
    });
  });

  test('断线行与重连行的形状（前缀时间戳与正文时间戳相同）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.disconnected();
      await w.reconnected();
      await w.end();
      final lines = (await logged(w)).split('\n');
      expect(lines[1],
          '[2026-09-24 14:30:12.001] !!! 连接断开 2026-09-24 14:30:12.001 ！！！');
      expect(lines[2],
          '[2026-09-24 14:30:12.001] === 重连成功 2026-09-24 14:30:12.001 ===');
    });
  });

  test('日期目录在 start 定死：跨过午夜仍是同一个文件', () async {
    var now = t0;
    await withClock(Clock(() => now), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      final path = w.file!.path;
      now = DateTime(2026, 9, 25, 0, 0, 1);
      await w.write('午夜之后的内容');
      await w.end();
      expect(w.file!.path, path);
      expect(path, contains('/2026-09-24/'));
      expect(await logged(w), contains('午夜之后的内容'));
    });
  });

  test('start 之前 write 不写任何东西，也不建文件', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.write('还没开始');
      await w.disconnected();
      expect(w.file, isNull);
      expect(root.listSync(), isEmpty);
    });
  });

  test('end 之后的 write / disconnected 不再追加', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.end();
      final after = await logged(w);
      await w.write('结束之后');
      await w.disconnected();
      expect(await logged(w), after);
    });
  });

  test('缓冲：写完但没到阈值时磁盘上还没有，end 之后全都在', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer(flushEveryLines: 32);
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('第一行\n第二行');
      expect(await w.file!.exists(), isFalse, reason: '还没 flush（FR-L-06 的缓冲）');
      await w.end();
      final text = await logged(w);
      expect(text, contains('第一行'));
      expect(text, contains('第二行'));
      expect(text, contains('===== 会话结束'));
    });
  });

  test('缓冲：写到阈值立即落盘', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer(flushEveryLines: 3);
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('1\n2\n3');
      expect(await w.file!.exists(), isTrue);
      // **别写成 `contains('3')`。** 表头那一行的时间戳 `2026-09-24 14:30:12.001`
      // 本身就含 `3`，所以只要表头落了盘那条断言就永远绿 —— 而"表头落了盘"恰恰
      // **不**是本条要证明的事（要证明的是缓冲区到阈值就落盘）。实测过：在
      // `_flush` 里加一句 `lines.removeLast()`（正是本条想抓的"丢掉最后一行"），
      // `contains('3')` 版本照样通过，只有兄弟用例抓得到。
      // `'] N\n'` 只有正文行能满足 —— 表头行里没有任何 `]`。
      final text = await logged(w);
      expect(text, contains('] 1\n'));
      expect(text, contains('] 2\n'));
      expect(text, contains('] 3\n'));
    });
  });

  test('同一文件被两次会话追加，第一段不被覆盖', () async {
    await withClock(Clock.fixed(t0), () async {
      final first = writer();
      await first.start('ssh admin@10.0.0.1:22');
      await first.write('第一段\n');
      await first.end();

      final second = writer();
      await second.start('ssh admin@10.0.0.1:22');
      await second.write('第二段\n');
      await second.end();

      final text = await logged(second);
      expect(text, contains('第一段'));
      expect(text, contains('第二段'));
      expect('===== 会话开始'.allMatches(text).length, 2);
    });
  });

  test('落盘文件权限是 0600（NFR-S-04）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer();
      await w.start('ssh admin@10.0.0.1:22');
      await w.end();
      expect((await w.file!.stat()).mode & 0x1FF, 0x180);
    });
  });

  test('权限被改松之后，下一次 flush 会收紧回来（NFR-S-04 不只在新文件上生效）', () async {
    await withClock(Clock.fixed(t0), () async {
      final w = writer(flushEveryLines: 1);
      await w.start('ssh admin@10.0.0.1:22');
      await w.write('第一行');
      expect((await w.file!.stat()).mode & 0x1FF, 0x180);
      // 手工造出"进程在 writeAsString 与 chmod 之间被杀掉"留下的状态：
      // 文件在、权限是 umask 默认的 0664。
      Process.runSync('chmod', ['664', w.file!.path]);
      expect((await w.file!.stat()).mode & 0x1FF, 0x1B4, reason: '前提：权限确实被改松了');

      await w.write('第二行');

      expect(
        (await w.file!.stat()).mode & 0x1FF,
        0x180,
        reason: '判据必须是"当前权限"，不能是"文件是不是这次新建的" —— '
            '后者在这种情形下会永远跳过收紧，日志就永久停在 0644',
      );
    });
  },
      skip: Platform.isWindows
          ? 'chmod / mode 语义只在 Linux 上成立（NFR-S-04 本身也只针对 Linux）'
          : null);

  test('写盘失败：不抛、不阻塞会话，且 onError 只回调一次（FR-L-06）', () async {
    // 用一个同名**文件**占住目录位置，让 parent.create 必然失败。
    final blocked = File('${root.path}/blocked');
    await blocked.writeAsString('我不是目录');
    final failures = <Object>[];
    final w = LogWriter(
      rootDir: Directory(blocked.path),
      deviceName: 'CoreSW',
      onError: failures.add,
      flushEveryLines: 1,
    );
    await withClock(Clock.fixed(t0), () async {
      await w.start('ssh admin@10.0.0.1:22');
      for (var i = 0; i < 10; i++) {
        await w.write('第 $i 行');
      }
      await w.end();
    });
    expect(failures, hasLength(1),
        reason: '失败一次就够 —— 每行回调一次会把输出区刷爆');
  });

  test('文件名净化：危险字符替换为下划线，首尾空白与点号去掉（FR-L-05）', () {
    expect(sanitizeLogFileName('a/b:c*d?e"f<g>h|i\\j'), 'a_b_c_d_e_f_g_h_i_j');
    expect(sanitizeLogFileName('  核心交换机  '), '核心交换机');
    expect(sanitizeLogFileName('...core...'), 'core');
  });

  test('文件名净化：截断到 64，且截断后不留尾部点号（FR-L-05）', () {
    final long = 'x' * 100;
    expect(sanitizeLogFileName(long).length, 64);
    // 第 64 个字符恰好是点号：截断后会留一个尾点，Windows 上建不出文件。
    final tricky = '${'a' * 63}.${'b' * 10}';
    final got = sanitizeLogFileName(tricky);
    expect(got.endsWith('.'), isFalse);
    expect(got.length, lessThanOrEqualTo(64));
  });

  test('文件名净化：整名被去空之后兜底，不会产生空文件名', () {
    expect(sanitizeLogFileName('   '), '未命名设备');
    expect(sanitizeLogFileName('...'), '未命名设备');
  });
}
