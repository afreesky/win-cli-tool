import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/render/ansi_parser.dart';
import 'package:win_cli_tool/ui/widgets/ansi_text.dart';

void main() {
  group('颜色：一律委托给 AnsiColor.rgb', () {
    test('没有颜色时给 null（调用方据此用主题默认色，而不是硬编码黑白）', () {
      expect(ansiColorOf(null), isNull);
    });

    test('16 色走 rgb getter —— 用 4 号色钉住"没有第二份表"', () {
      // **4 号色是这一节存在的理由。** 我最初那版在这里自己维护了一份 16 色表，
      // 而它把 4 号色抄成了 205（真实是 238）。下面第一行断言的是 render 层的
      // 事实，第二行断言的是本文件确实**委托**给了它 —— 一旦有人再抄一份表，
      // 露馅的第一个就是这一格。
      expect(const AnsiBasic(4).rgb, (0, 0, 238), reason: '前提：render 层的值');
      expect(ansiColorOf(const AnsiBasic(4)), const Color(0xFF0000EE));
      expect(ansiColorOf(const AnsiBasic(1)), const Color(0xFFCD0000));
      expect(ansiColorOf(const AnsiBasic(15)), const Color(0xFFFFFFFF));
    });

    test('256 色与真彩色同样走 rgb', () {
      expect(ansiColorOf(const Ansi256(196)), const Color(0xFFFF0000));
      expect(ansiColorOf(const Ansi256(240)), const Color(0xFF585858));
      expect(ansiColorOf(const AnsiRgb(0x12, 0x34, 0x56)), const Color(0xFF123456));
    });

    test('256 个索引逐个走一遍都不抛（把 rgb 的断言暴露出来）', () {
      for (var i = 0; i < 256; i++) {
        expect(ansiColorOf(Ansi256(i)), isNotNull);
      }
    });
  });

  group('样式映射', () {
    test('前/背景色直接落到 TextStyle', () {
      final span = ansiSpanOf(
        const AnsiSpan('x', AnsiStyle(foreground: AnsiBasic(1), background: AnsiBasic(4))),
      );
      expect(span.style!.color, const Color(0xFFCD0000));
      expect(span.style!.backgroundColor, const Color(0xFF0000EE),
          reason: '4 号色的真实值 —— 抄错表的那一版会在这里红');
    });

    test('bold 与 underline 落到字重与装饰', () {
      final span = ansiSpanOf(
        const AnsiSpan('x', AnsiStyle(bold: true, underline: true)),
      );
      expect(span.style!.fontWeight, FontWeight.bold);
      expect(span.style!.decoration, TextDecoration.underline);
    });

    test('reverse 交换前背景色，且在没有前背景时给出一对可看的默认值', () {
      final span = ansiSpanOf(
        const AnsiSpan('x', AnsiStyle(foreground: AnsiBasic(1), reverse: true)),
      );
      // 原本 fg=红 无背景 → 反转后 背景=红、前景=「默认背景色」
      expect(span.style!.backgroundColor, const Color(0xFFCD0000));
      expect(span.style!.color, isNotNull, reason: '反转后前景必须有值，否则等于没反转');

      final bare = ansiSpanOf(const AnsiSpan('x', AnsiStyle(reverse: true)));
      expect(bare.style!.backgroundColor, isNotNull);
      expect(bare.style!.color, isNotNull);
    });
  });

  group('整棵树', () {
    test('行之间用 \\n 连接，片段样式各归各的', () {
      final lines = <List<AnsiSpan>>[
        [const AnsiSpan('a', AnsiStyle(foreground: AnsiBasic(1)))],
        [const AnsiSpan('b', AnsiStyle.none)],
      ];
      final root = ansiLinesToTextSpan(lines);

      final flat = <TextSpan>[];
      root.visitChildren((s) {
        flat.add(s as TextSpan);
        return true;
      });
      // 3 个子节点：'a'、'\n'、'b'
      expect(flat, hasLength(3));
      expect(flat[0].text, 'a');
      expect(flat[1].text, '\n');
      expect(flat[2].text, 'b');
      expect(flat[0].style!.color, const Color(0xFFCD0000));
      expect(flat[2].style?.color, isNull, reason: '无色的片段不该被硬塞一个颜色');
    });

    test('空缓冲给得出一个空的根节点，不抛', () {
      final root = ansiLinesToTextSpan([<AnsiSpan>[]]);
      expect(root.children, isEmpty);
    });
  });
}
