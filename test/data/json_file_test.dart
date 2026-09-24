import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/data/json_file.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_json_file_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  File f(String name) => File('${root.path}/$name');

  group('readJsonObject', () {
    test('文件不存在返回 null，而不是抛异常', () async {
      expect(await readJsonObject(f('nope.json')), isNull);
    });

    test('空文件（只有空白）返回 null', () async {
      await f('empty.json').writeAsString('   \n');
      expect(await readJsonObject(f('empty.json')), isNull);
    });

    test('正常对象读得出来', () async {
      await f('ok.json').writeAsString('{"schemaVersion": 2}');
      expect(await readJsonObject(f('ok.json')), {'schemaVersion': 2});
    });

    test('顶层是数组算损坏，抛 FormatException', () async {
      await f('arr.json').writeAsString('[1, 2]');
      expect(() => readJsonObject(f('arr.json')), throwsFormatException);
    });

    test('顶层是数字算损坏，抛 FormatException', () async {
      await f('num.json').writeAsString('7');
      expect(() => readJsonObject(f('num.json')), throwsFormatException);
    });

    test('根本不是 JSON 时抛 FormatException', () async {
      await f('junk.json').writeAsString('{oops');
      expect(() => readJsonObject(f('junk.json')), throwsFormatException);
    });
  });

  group('writeJsonObject', () {
    test('写完能读回来，且不带临时文件残留', () async {
      await writeJsonObject(f('w.json'), {'a': 1, 'b': [2, 3]});
      expect(await readJsonObject(f('w.json')), {
        'a': 1,
        'b': [2, 3],
      });
      expect(f('w.json.tmp').existsSync(), isFalse);
    });

    test('父目录不存在时自动创建', () async {
      final nested = File('${root.path}/a/b/c.json');
      await writeJsonObject(nested, {'x': true});
      expect(await readJsonObject(nested), {'x': true});
    });

    test('覆盖写不会留下旧内容', () async {
      await writeJsonObject(f('o.json'), {'n': 1});
      await writeJsonObject(f('o.json'), {'n': 2});
      expect(await readJsonObject(f('o.json')), {'n': 2});
    });

    test('写盘失败时不留 .tmp（否则那是 umask 权限的明文凭据文件）', () async {
      // 让 rename 必然失败：目标路径是一个**目录**。这样写序会走到
      // "内容已落盘、chmod 也许还没跑"的那一步，正是残留出现的时刻。
      await Directory('${root.path}/t.json').create();
      await expectLater(
        writeJsonObject(f('t.json'), {'password': 'PLAINTEXT-SECRET'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        f('t.json.tmp').existsSync(),
        isFalse,
        reason: '失败路径必须删掉临时文件 —— 它带着完整内容，'
            '权限还是 umask 默认值（本仓库 0664），正是 NFR-S-04 要防的形状',
      );
    });

    test('输出是带缩进的 UTF-8，中文不被转义', () async {
      await writeJsonObject(f('cn.json'), {'name': '核心交换机'});
      final raw = await f('cn.json').readAsString();
      expect(raw, contains('核心交换机'));
      expect(raw, contains('\n'));
    });
  });

  group('restrictToOwner', () {
    test('Linux 上把权限收紧到 0600', () async {
      final file = f('perm.json');
      await file.writeAsString('{}');
      await restrictToOwner(file);
      final mode = (await file.stat()).mode & 0x1FF;
      expect(mode, 0x180, reason: '0600 八进制 = 0o600 = 0x180');
    });

    test('幂等：连续调用两次不报错', () async {
      final file = f('perm2.json');
      await file.writeAsString('{}');
      await restrictToOwner(file);
      await restrictToOwner(file);
      expect((await file.stat()).mode & 0x1FF, 0x180);
    });
  });

  group('quarantine', () {
    test('把文件改名留档，返回新文件', () async {
      final file = f('bad.json');
      await file.writeAsString('{oops');
      final moved = await quarantine(file, now: DateTime(2026, 9, 25, 1, 2, 3));
      expect(moved, isNotNull);
      expect(moved!.path, contains('bad.json.bad-'));
      expect(await moved.readAsString(), '{oops');
      expect(file.existsSync(), isFalse);
    });

    test('文件不存在时返回 null', () async {
      expect(await quarantine(f('none.json'), now: DateTime(2026)), isNull);
    });

    test('留档名不含冒号（Windows 上非法）', () async {
      final file = f('bad2.json');
      await file.writeAsString('x');
      final moved = await quarantine(file, now: DateTime(2026, 9, 25, 1, 2, 3));
      expect(moved!.path, isNot(contains(':')));
    });
  });

  group('jsonDecode 的往返', () {
    test('写进去的对象与读出来的对象逐键相等（含嵌套）', () async {
      final original = <String, Object?>{
        'schemaVersion': 2,
        'devices': [
          {'id': 'd1', 'port': 22, 'autoConnect': false, 'password': null},
        ],
      };
      await writeJsonObject(f('round.json'), original);
      final back = await readJsonObject(f('round.json'));
      expect(jsonEncode(back), jsonEncode(original));
    });
  });
}
