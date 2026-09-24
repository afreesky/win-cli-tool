import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/render/ansi.dart';

void main() {
  group('stripAnsi', () {
    test('剥离 SGR 颜色序列', () {
      expect(stripAnsi('\x1b[1m[CoreSW]\x1b[0m'), '[CoreSW]');
    });

    test('剥离光标移动序列', () {
      expect(stripAnsi('\x1b[2K\x1b[1Ghello'), 'hello');
    });

    test('无转义序列时原样返回', () {
      expect(stripAnsi('plain text'), 'plain text');
    });

    test('保留中文与普通文本', () {
      expect(stripAnsi('\x1b[31m错误：接口 down\x1b[0m'), '错误：接口 down');
    });
  });
}
