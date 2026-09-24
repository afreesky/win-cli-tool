import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/more_pager.dart';

void main() {
  group('MorePager', () {
    final p = MorePager();

    test('识别华为/H3C 的 ---- More ----', () {
      expect(p.matchesTail('line\r\n  ---- More ----'), isTrue);
    });

    test('识别 Cisco 的 --More--', () {
      expect(p.matchesTail('line\r\n--More--'), isTrue);
    });

    test('识别 <--- More --->', () {
      expect(p.matchesTail('<--- More --->'), isTrue);
    });

    test('翻页提示后带空格仍能识别', () {
      expect(p.matchesTail('line\r\n  ---- More ----   '), isTrue);
    });

    test('最后一行为空（已换行）时不命中', () {
      expect(p.matchesTail('line\r\n'), isFalse);
    });

    test('输出中段提到 More 但不在末尾时不命中', () {
      expect(p.matchesTail('---- More ----\r\nreal output'), isFalse);
    });

    test('空缓冲区不命中', () {
      expect(p.matchesTail(''), isFalse);
    });

    test('自定义模式', () {
      final custom = MorePager(patterns: ['<SPACE>']);
      expect(custom.matchesTail('line<SPACE>'), isTrue);
      expect(custom.matchesTail('line--More--'), isFalse);
    });
  });
}
