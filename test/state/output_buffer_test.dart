import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/render/ansi_parser.dart';
import 'package:win_cli_tool/state/output_buffer.dart';

void main() {
  late List<String> logged;
  late OutputBuffer buffer;

  OutputBuffer make({int maxLines = 5000}) {
    final b = OutputBuffer(maxLines: maxLines);
    b.onText = logged.add;
    return b;
  }

  setUp(() {
    logged = <String>[];
    buffer = make();
  });

  /// 把各行拼回一个字符串，供"文本内容"断言。
  String textOf(List<List<AnsiSpan>> lines) => lines
      .map((line) => line.map((s) => s.text).join())
      .join('\n');

  group('分块', () {
    test('没有换行的输入留在同一行里', () {
      buffer.add('abc');
      expect(buffer.lines, hasLength(1));
      expect(textOf(buffer.lines), 'abc');
    });

    test('换行把内容切开，并在末尾留下一个未完成的行', () {
      buffer.add('a\nb\n');
      expect(textOf(buffer.lines), 'a\nb\n');
      expect(buffer.lines, hasLength(3), reason: '末尾的空行是"下一行还没开始"');
    });

    test('跨块的一行会接起来', () {
      buffer.add('hel');
      buffer.add('lo\n');
      expect(textOf(buffer.lines), 'hello\n');
    });
  });

  group('日志与输出区同一边界', () {
    test('喂给 onText 的文本与喂给解析器的逐字相同', () {
      const chunk = 'a\x1b[31mred\x1b[0m\n';
      buffer.add(chunk);
      expect(logged, [chunk]);
      expect(textOf(buffer.lines), 'ared\n');
    });

    test('半条控制序列被留住，两边都不吃它', () {
      buffer.add('a\x1b[');
      // 喂给日志的是**本次完整的那一段**，边界正好落在半条序列之前 ——
      // 所以这里不是 `isEmpty`：`'a'` 是完整的、该进日志；`'\x1b['` 被留住。
      expect(logged, ['a']);
      expect(textOf(buffer.lines), 'a');

      buffer.add('31mred');
      expect(
        logged,
        ['a', '\x1b[31mred'],
        reason: '等到了后半截，于是这半条与它的前半截**一次完整地**喂下去',
      );
      expect(textOf(buffer.lines), 'ared', reason: '整条序列都被吃掉了');
      expect(
        // `lines.first` 此时有**两个**片段（无色 'a' + 红色 'red'），
        // 所以取 `.last` 而不是 `.single`。
        buffer.lines.first.last.style.foreground,
        const AnsiBasic(1),
        reason: '留在缓冲里是对的：接起来之后红色才认得出来',
      );
    });

    test('样式跨块延续（否则分块会丢颜色）', () {
      buffer.add('\x1b[32m');
      expect(logged, ['\x1b[32m']);
      buffer.add('green');
      expect(
        buffer.lines.first.single.style.foreground,
        const AnsiBasic(2),
        reason: '块末样式必须接给下一块 —— spans.last.style 在这里给不出来',
      );
    });
  });

  group('flush', () {
    test('放出残留的尾巴，并同样喂给日志', () {
      buffer.add('a\x1b[');
      expect(logged, ['a'], reason: '前半截进过一次');

      buffer.flush();

      // flush 把残留的 `'\x1b['` 也喂下去：它是一条永远等不到后半截的畸形序列，
      // 按字面文本处理 —— 与 `parseAnsi` 对它的处置一致。
      expect(logged, ['a', '\x1b[']);
      expect(textOf(buffer.lines), 'a\x1b[');
    });

    test('没有残留时什么都不做', () {
      buffer.add('done\n');
      logged.clear();
      buffer.flush();
      expect(logged, isEmpty);
    });
  });

  group('行数上限（FR-O-07）', () {
    test('超出上限时丢掉最旧的行', () {
      final b = make(maxLines: 3);
      b.onText = logged.add;
      b.add('1\n2\n3\n4\n5\n');
      expect(textOf(b.lines), '3\n4\n5\n');
    });

    test('上限为 0 或负数时至少留一行（否则 add 会抛）', () {
      final b = OutputBuffer(maxLines: 0);
      b.add('a\nb\n');
      expect(b.lines, isNotEmpty);
    });
  });

  group('clear（FR-O-05）', () {
    test('清掉显示内容，但日志一点都不受影响', () {
      buffer.add('before\n');
      logged.clear();
      buffer.clear();
      expect(textOf(buffer.lines), '');
      expect(logged, isEmpty, reason: '清屏只清显示内容，不动日志');
    });

    test('不清解析状态：清屏后的样式与半条序列仍然接得上', () {
      buffer.add('\x1b[32m');
      buffer.clear();
      buffer.add('after');
      expect(
        textOf(buffer.lines),
        'after',
        reason: '半条序列与样式是解析状态，不是"显示内容"',
      );
      expect(
        buffer.lines.first.single.style.foreground,
        const AnsiBasic(2),
      );
    });
  });

  group('addMarker', () {
    test('自占一行，且不进日志', () {
      buffer.add('cmd\n');
      logged.clear();
      buffer.addMarker('--- 连接断开 ---');
      // **这条断言必须在下面那句 `add` 之前。** 原文把它写在最后，而 `add` 会把
      // `'next\n'` 喂进日志（`onText` 一直是挂着的），于是 `expect(logged, isEmpty)`
      // **永远不可能成立** —— 它钉的不是"标记不进日志"，而是"这之后什么都不许进
      // 日志"，而后者本来就是假的。
      expect(logged, isEmpty, reason: '日志有它自己的一套标记（LogWriter 负责）');

      buffer.add('next\n');
      expect(textOf(buffer.lines), 'cmd\n--- 连接断开 ---\nnext\n');
      expect(logged, ['next\n'], reason: '标记之后的设备输出照常进日志');
    });

    test('带上样式', () {
      buffer.addMarker('warn', style: const AnsiStyle(foreground: AnsiBasic(3)));
      final marker = buffer.lines[buffer.lines.length - 2].single;
      expect(marker.text, 'warn');
      expect(marker.style.foreground, const AnsiBasic(3));
    });
  });
}
