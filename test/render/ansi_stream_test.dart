import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/render/ansi_parser.dart';

void main() {
  group('ansiHoldBackLength', () {
    test('不含 ESC 时不留尾巴', () {
      expect(ansiHoldBackLength('hello\nworld'), 0);
    });

    test('末尾是完整的 CSI 时不留尾巴', () {
      expect(ansiHoldBackLength('a\x1b[31mb'), 0);
    });

    test('末尾是半条 CSI 时留到那个 ESC', () {
      // 这条输入正是"设备把一条序列分开发"的前半截。
      expect(ansiHoldBackLength('a\x1b['), 2);
      expect(ansiHoldBackLength('a\x1b[3'), 3);
      expect(ansiHoldBackLength('a\x1b[38;5;'), 7);
    });

    test('末尾是裸露的 ESC 时留 1', () {
      expect(ansiHoldBackLength('abc\x1b'), 1);
    });

    test('末尾是半条 OSC 时留到那个 ESC', () {
      // OSC 的终止符是 BEL 或 ST（ESC \\）；没等到就是还没完。
      expect(ansiHoldBackLength('\x1b]0;标题'), 6);
      expect(ansiHoldBackLength('\x1b]0;标题\x07'), 0);
    });

    test('OSC 的 ST 终止符本身是一个完整的 ESC 序列', () {
      // 只看**最后一个** ESC 就够，靠的就是这条：序列之间不嵌套。
      expect(ansiHoldBackLength('\x1b]0;t\x1b\\'), 0);
    });

    test('ESC 后跟的不是 [ 或 ] 时，判定已经做出，不留尾巴', () {
      // `\x1b(B`（选择字符集）解析器刻意不剥离（既有用例钉着），但它也**不会**
      // 因为后续输入而改判 —— ESC 处的判定只取决于下一个字符。
      expect(ansiHoldBackLength('a\x1b(B'), 0);
      // 真正的两字节序列（ESC + `@`-`Z` / `\]^_`）同理：已经完整。
      expect(ansiHoldBackLength('a\x1bM'), 0);
    });

    test('半条序列比 kMaxAnsiHoldBack 还长时不再留（免得永久卡住）', () {
      // 一条永远等不到后半截的畸形序列不得把输出区卡死：
      // 超过上限就当作普通文本放行。
      final pathological = '\x1b[${'1' * (kMaxAnsiHoldBack + 10)}';
      expect(ansiHoldBackLength(pathological), 0);
      expect(ansiHoldBackLength(pathological).isNegative, isFalse);
    });

    test('留住的长度永不超过 kMaxAnsiHoldBack', () {
      final long = '\x1b[${'1' * (kMaxAnsiHoldBack * 3)}';
      expect(ansiHoldBackLength(long), lessThanOrEqualTo(kMaxAnsiHoldBack));
    });
  });

  group('parseAnsiChunk', () {
    test('返回的 finalStyle 是输入走完时的样式', () {
      final r = parseAnsiChunk('\x1b[32m');
      expect(r.spans, isEmpty, reason: '只有样式、没有文本时不该产出片段');
      expect(r.finalStyle.foreground, const AnsiBasic(2));
    });

    test('finalStyle 与 spans.last.style 不是一回事', () {
      // 这正是要单开一个入口的理由：`spans.last.style` 会给出**上一段文本**的
      // 样式，而输入末尾那次换色就丢了。
      final r = parseAnsiChunk('\x1b[32mgreen\x1b[31m');
      expect(r.spans.single.text, 'green');
      expect(r.spans.single.style.foreground, const AnsiBasic(2));
      expect(r.finalStyle.foreground, const AnsiBasic(1));
    });

    test('分两块喂（样式接续）与一次喂得到同样的结果', () {
      const whole = 'a\x1b[32mgreen\x1b[0mb';
      final oneShot = parseAnsi(whole);

      final first = parseAnsiChunk('a\x1b[32mgre');
      final second = parseAnsiChunk('en\x1b[0mb', initial: first.finalStyle);
      final twoShot = [...first.spans, ...second.spans];

      expect(
        twoShot.map((s) => s.text).join(),
        oneShot.map((s) => s.text).join(),
      );
      // **按字符比样式，不按片段比。** 块边界落在同一段同样式文本中间时（这里
      // green 被切成 'gre' + 'en'），两次调用各自在块末 `flush()`，所以片段边界
      // 必然不同 —— `AnsiParseResult` 只带 spans + finalStyle，没有跨调用状态能把
      // 它们并回一段，这是设计如此（渲染上相邻同色片段本来就等价）。承重的不变量
      // 是"每个字符的样式一致"，不是"片段切法一致"。
      List<AnsiStyle> perChar(Iterable<AnsiSpan> spans) =>
          [for (final s in spans) ...List.filled(s.text.length, s.style)];
      expect(perChar(twoShot), perChar(oneShot));
    });

    test('parseAnsi 就是 parseAnsiChunk 的片段那一半', () {
      const input = '\x1b[1;31mred\x1b[0m plain';
      expect(parseAnsi(input), parseAnsiChunk(input).spans);
    });
  });
}
