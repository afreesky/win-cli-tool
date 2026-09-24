import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/render/ansi.dart';
import 'package:win_cli_tool/render/ansi_parser.dart';

void main() {
  /// 把片段拼回纯文本。与日志用的是同一个出口。
  String textOf(String input) => stripToPlainText(input);

  group('基本形状', () {
    test('纯文本就是一个 none 样式的片段', () {
      final spans = parseAnsi('interface Vlanif1');
      expect(spans, hasLength(1));
      expect(spans.single.text, 'interface Vlanif1');
      expect(spans.single.style, AnsiStyle.none);
    });

    test('空串没有任何片段', () {
      expect(parseAnsi(''), isEmpty);
    });

    test('只有 SGR 时也没有片段（不产生空 span）', () {
      expect(parseAnsi('\x1b[31m\x1b[0m'), isEmpty);
    });
  });

  group('SGR', () {
    test('前景色 30–37', () {
      final spans = parseAnsi('\x1b[31m红\x1b[0m');
      expect(spans, hasLength(1));
      expect(spans.single.text, '红');
      expect(spans.single.style.foreground, const AnsiBasic(1));
    });

    test('组合参数 1;31;44', () {
      final style = parseAnsi('\x1b[1;31;44mx').single.style;
      expect(style.bold, isTrue);
      expect(style.foreground, const AnsiBasic(1));
      expect(style.background, const AnsiBasic(4));
    });

    test('ESC[m 等价于 ESC[0m（空参数就是 0）', () {
      expect(parseAnsi('\x1b[1mA\x1b[mB').last.style, AnsiStyle.none);
    });

    test('22 / 24 / 27 各自只关掉自己那一项', () {
      final s = parseAnsi('\x1b[1;4;7mA\x1b[22mB\x1b[24mC\x1b[27mD');
      expect(s[0].style.bold && s[0].style.underline && s[0].style.reverse,
          isTrue);
      expect(s[1].style.bold, isFalse);
      expect(s[1].style.underline, isTrue);
      expect(s[2].style.underline, isFalse);
      expect(s[2].style.reverse, isTrue);
      expect(s[3].style.reverse, isFalse);
    });

    test('39 / 49 恢复默认色而不是留下一个"淡色"', () {
      final s = parseAnsi('\x1b[31;44mA\x1b[39mB\x1b[49mC');
      expect(s[0].style.foreground, const AnsiBasic(1));
      expect(s[0].style.background, const AnsiBasic(4));
      expect(s[1].style.foreground, isNull);
      expect(s[1].style.background, const AnsiBasic(4));
      expect(s[2].style.background, isNull);
    });

    test('90–97 是亮前景，100–107 是亮背景', () {
      expect(parseAnsi('\x1b[90mA').single.style.foreground,
          const AnsiBasic(8));
      expect(parseAnsi('\x1b[97mA').single.style.foreground,
          const AnsiBasic(15));
      expect(parseAnsi('\x1b[100mA').single.style.background,
          const AnsiBasic(8));
      expect(parseAnsi('\x1b[107mA').single.style.background,
          const AnsiBasic(15));
    });

    test('38;5;n 是 256 色索引', () {
      expect(parseAnsi('\x1b[38;5;196mA').single.style.foreground,
          const Ansi256(196));
      expect(parseAnsi('\x1b[48;5;17mA').single.style.background,
          const Ansi256(17));
    });

    test('38;2;r;g;b 是真彩', () {
      expect(parseAnsi('\x1b[38;2;10;20;30mA').single.style.foreground,
          const AnsiRgb(10, 20, 30));
      expect(parseAnsi('\x1b[48;2;1;2;3mA').single.style.background,
          const AnsiRgb(1, 2, 3));
    });

    test('写残的扩展色不抛，也不把后面的数字当成颜色', () {
      for (final bad in [
        '\x1b[38;5;mA',
        '\x1b[38;5;300mA',
        '\x1b[38;2;1;2mA',
        '\x1b[38;2;1;2;999mA',
      ]) {
        final spans = parseAnsi(bad);
        expect(spans, hasLength(1), reason: bad);
        expect(spans.single.text, 'A', reason: bad);
        expect(spans.single.style, AnsiStyle.none, reason: bad);
      }
    });

    test('认不出的数字参数被忽略，而不是当成 0（0 会把样式清空）', () {
      final style = parseAnsi('\x1b[1;99999999999999999999mA').single.style;
      expect(style.bold, isTrue);
    });

    test('不支持的 SGR（闪烁、隐藏）静默忽略，文本照常', () {
      final spans = parseAnsi('\x1b[5;8mA');
      expect(spans.single.text, 'A');
      expect(spans.single.style, AnsiStyle.none);
    });
  });

  group('非 SGR 的控制序列被剥离', () {
    test('光标移动 / 擦除 / 定位', () {
      expect(textOf('\x1b[2J\x1b[H\x1b[10;20H清屏'), '清屏');
      expect(textOf('\x1b[K清行尾\x1b[1A上移'), '清行尾上移');
      expect(textOf('\x1b[?25l隐藏\x1b[?25h'), '隐藏');
    });

    test('OSC 标题序列，BEL 与 ST 两种终止符', () {
      expect(textOf('\x1b]0;标题\x07正文'), '正文');
      expect(textOf('\x1b]0;标题\x1b\\正文'), '正文');
    });

    test('\\r 一律被丢掉', () {
      expect(textOf('a\r\nb'), 'a\nb');
      expect(parseAnsi('a\r\nb').single.text, 'a\nb');
      // 与 stripAnsi 不同：它只在输入含 ESC 时才走到 \\r 清理那一步
      // （见「与 stripAnsi 对拍」那组里的分叉用例）。
      expect(stripAnsi('a\r\nb'), 'a\r\nb');
    });
  });

  group('边界', () {
    test('残缺的 ESC 序列不抛异常', () {
      expect(textOf('\x1b'), '\x1b');
      expect(textOf('\x1b[31'), '\x1b[31');
      expect(textOf('\x1b['), '\x1b[');
      expect(textOf('尾部\x1b'), '尾部\x1b');
    });

    test('没终止符的 OSC：ESC 与 ] 被两字节规则吃掉（与 stripAnsi 一致）', () {
      // 这条是"优先级顺序"的钉子：先试 CSI、再试 OSC、再试两字节，
      // 最后才当普通字符。顺序错了这条就红。
      expect(textOf('\x1b]0;未终止'), '0;未终止');
      expect(stripAnsi('\x1b]0;未终止'), '0;未终止');
    });

    test('选择字符集 ESC ( B 在两边都不被剥离（既有行为，见计划说明）', () {
      expect(textOf('\x1b(B字符集'), '\x1b(B字符集');
      expect(stripAnsi('\x1b(B字符集'), '\x1b(B字符集');
    });

    test('相邻同样式的片段合并成一个', () {
      final spans = parseAnsi('a\x1b[0mb');
      expect(spans, hasLength(1));
      expect(spans.single.text, 'ab');
    });

    test('任意字节流都不抛', () {
      const garbage = '\x1b\x1b\x1b[;\x1b]0\x07\x1b[999;;;m\x1b(\x00\x1bZ';
      expect(() => parseAnsi(garbage), returnsNormally);
      expect(() => stripToPlainText(garbage), returnsNormally);
      expect(() => stripAnsi(garbage), returnsNormally);
    });
  });

  group('颜色到 RGB', () {
    test('前 16 色的表', () {
      expect(const AnsiBasic(0).rgb, (0, 0, 0));
      expect(const AnsiBasic(1).rgb, (205, 0, 0));
      expect(const AnsiBasic(7).rgb, (229, 229, 229));
      expect(const AnsiBasic(9).rgb, (255, 0, 0));
      expect(const AnsiBasic(15).rgb, (255, 255, 255));
    });

    test('256 色表的三段：0–15 同基本色、16–231 是 6×6×6、232–255 是灰阶', () {
      expect(const Ansi256(0).rgb, (0, 0, 0));
      expect(const Ansi256(196).rgb, (255, 0, 0));
      expect(const Ansi256(21).rgb, (0, 0, 255));
      expect(const Ansi256(240).rgb, (88, 88, 88));
      expect(const Ansi256(255).rgb, (238, 238, 238));
    });

    test('真彩原样返回', () {
      expect(const AnsiRgb(10, 20, 30).rgb, (10, 20, 30));
    });
  });

  group('与 stripAnsi 对拍（只覆盖现实输入）', () {
    // 语料里**不放**"没有 ESC 却带 \r"的输入：那种输入两边必然不同，
    // 见下面「分叉一」。这里要的是"对良构控制序列两边给同一份文本"。
    const corpus = <String>[
      '',
      '普通文本',
      '\x1b[31m红\x1b[0m',
      '\x1b[1;31;44m粗\x1b[22m体',
      '\x1b[38;5;196m索引\x1b[39m',
      '\x1b[38;2;10;20;30m真彩\x1b[49m',
      '\x1b[2J\x1b[H\x1b[10;20H清屏',
      '\x1b]0;标题\x07正文',
      '\x1b]0;标题\x1b\\正文',
      '\x1b[?25l隐藏\x1b[?25h',
      '\x1b(B字符集',
      '\x1b[31',
      '\x1b',
      '\x1b[0m',
      '\x1b[7m反显\x1b[27m',
      '中文\x1b[90m亮黑\x1b[100m亮黑底\x1b[0m',
      '\x1b[K清行尾\x1b[1A上移',
      '\x1b]0;未终止',
      '\x1bZ',
      '尾部\x1b',
      '\x1b[1m\x1b[31m两层\x1b[0m',
      '\x1b[2J\x1b]0;标题\x07\x1b[1m[CoreSW]\x1b[0m\r\n',
    ];

    test('每一条的纯文本都与 stripAnsi 相同', () {
      for (final input in corpus) {
        expect(
          stripToPlainText(input),
          stripAnsi(input),
          reason:
              '对拍失败：${input.codeUnits.map((c) => c.toRadixString(16)).join(' ')}',
        );
      }
    });

    test('分叉一：不含 ESC 时 stripAnsi 不删 \\r，本解析器一律删', () {
      // stripAnsi 的 \r 清理写在 `if (!input.contains('\x1b')) return input;`
      // 之后 —— 没有 ESC 就提前返回了，\r 原样留下。**现实输入会撞上**：
      // 一段不带颜色的纯回显就是这个形状。
      const plain = '[CoreSW]sys\r\nEnter system view\r\n[CoreSW]';
      expect(stripAnsi(plain), plain);
      expect(stripToPlainText(plain), '[CoreSW]sys\nEnter system view\n[CoreSW]');
      // 同一段只要带上任意一条 ESC，两边就都删 \r 了 —— 分叉只在"这一整段
      // 没有任何控制序列"时出现。
      expect(stripAnsi('\x1b[0m\r\n'), '\n');
      expect(stripToPlainText('\x1b[0m\r\n'), '\n');
    });

    test('分叉二：退化输入里"删掉一条序列后新拼出一条"，两边不同（不改）', () {
      // stripAnsi 是三次全串 replaceAll：删掉 `\x1b[\` 之后，最前面那个孤立的
      // ESC 与后面的 `\` 新拼成一条两字节序列，于是被吃掉。逐字符扫描看不到
      // 这种"事后拼出来"的序列。实测只在 `\x1b\x1b[…` 这类相邻/嵌套的畸形
      // 输入上出现，设备不会这样发。
      const degenerate = '\x1b\x1b[\\\\]]';
      expect(stripAnsi(degenerate), ']]');
      expect(stripToPlainText(degenerate), '\x1b\\]]');
    });
  });
}
