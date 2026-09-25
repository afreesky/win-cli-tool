import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/widgets/send_range.dart';

void main() {
  group('无选中：发光标所在行', () {
    test('光标在第二行中间 → 只发第二行', () {
      const text = 'sys\ninterface GE0/0/1\nquit';
      // 'sys\n' 是 0..3，'interface GE0/0/1' 是 4..20
      const caret = TextSelection.collapsed(offset: 10);
      expect(commandsToSend(text, caret), ['interface GE0/0/1']);
    });

    test('光标停在行尾（正好在 \\n 之前）仍算该行', () {
      const text = 'sys\nquit';
      const caret = TextSelection.collapsed(offset: 3);
      expect(commandsToSend(text, caret), ['sys']);
    });

    test('光标停在 \\n 之后（下一行行首）算下一行', () {
      const text = 'sys\nquit';
      const caret = TextSelection.collapsed(offset: 4);
      expect(commandsToSend(text, caret), ['quit']);
    });

    test('光标在文末（最后一行）', () {
      const text = 'sys\nquit';
      const caret = TextSelection.collapsed(offset: 8);
      expect(commandsToSend(text, caret), ['quit']);
    });
  });

  group('有选中：发覆盖到的所有行，整行参与', () {
    test('只选中一行的中间几个字 → 整行', () {
      const text = 'sys\ninterface GE0/0/1\nquit';
      const sel = TextSelection(baseOffset: 6, extentOffset: 12);
      expect(commandsToSend(text, sel), ['interface GE0/0/1']);
    });

    test('跨两行、两端都只覆盖一部分 → 两行整行参与', () {
      const text = 'sys\ninterface GE0/0/1\nquit';
      const sel = TextSelection(baseOffset: 1, extentOffset: 15);
      expect(commandsToSend(text, sel), ['sys', 'interface GE0/0/1']);
    });

    test('拖拽方向反过来（从下往上选）结果相同', () {
      const text = 'sys\ninterface GE0/0/1\nquit';
      const forward = TextSelection(baseOffset: 1, extentOffset: 15);
      const backward = TextSelection(baseOffset: 15, extentOffset: 1);
      expect(commandsToSend(text, backward), commandsToSend(text, forward));
    });

    test('选中范围正好停在下一行行首 → 不把下一行算进来', () {
      const text = 'sys\nquit';
      // 0..4 覆盖 'sys\n' —— 第 4 个字符是下一行行首，没被覆盖到。
      const sel = TextSelection(baseOffset: 0, extentOffset: 4);
      expect(commandsToSend(text, sel), ['sys']);
    });

    test('顺序始终自上而下', () {
      const text = 'a\nb\nc';
      const sel = TextSelection(baseOffset: 0, extentOffset: 5);
      expect(commandsToSend(text, sel), ['a', 'b', 'c']);
    });
  });

  group('空白过滤', () {
    test('完全空白的行被丢掉（与 enqueue 的 trim 规则一致）', () {
      const text = 'sys\n\n   \nquit';
      const sel = TextSelection(baseOffset: 0, extentOffset: 14);
      expect(commandsToSend(text, sel), ['sys', 'quit']);
    });

    test('行的首尾空白被去掉', () {
      const text = '  sys  ';
      const caret = TextSelection.collapsed(offset: 4);
      expect(commandsToSend(text, caret), ['sys']);
    });

    test('全是空行 → 空列表（调用方据此给轻提示）', () {
      const text = '\n   \n\n';
      const caret = TextSelection.collapsed(offset: 2);
      expect(commandsToSend(text, caret), isEmpty);
    });

    test('空文本 → 空列表', () {
      expect(commandsToSend('', const TextSelection.collapsed(offset: 0)), isEmpty);
    });
  });

  group('linesToSend：行号（编辑区据此高亮已发送的行，FR-E-10）', () {
    test('行号自上而下，且与 commandsToSend 一一对应', () {
      const text = 'sys\n\ninterface GE0/0/1\nquit';
      const sel = TextSelection(baseOffset: 0, extentOffset: 25);
      expect(linesToSend(text, sel), [0, 2, 3]);
      expect(commandsToSend(text, sel), ['sys', 'interface GE0/0/1', 'quit'],
          reason: '两个函数必须同源，否则高亮的行与实际发出去的行会错位');
    });

    test('空白行不占行号（它没被发出去，不该被高亮）', () {
      const text = 'a\n   \nb';
      const sel = TextSelection(baseOffset: 0, extentOffset: 7);
      expect(linesToSend(text, sel), [0, 2]);
    });

    test('无选中时只给自己那一行', () {
      const text = 'a\nb\nc';
      expect(linesToSend(text, const TextSelection.collapsed(offset: 2)), [1]);
    });
  });

  group('\\r\\n 的行尾', () {
    test('CRLF 的行不会把 \\r 带进命令里', () {
      const text = 'sys\r\nquit';
      const sel = TextSelection(baseOffset: 0, extentOffset: 8);
      expect(commandsToSend(text, sel), ['sys', 'quit']);
    });
  });
}
