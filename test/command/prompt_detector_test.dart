import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';

void main() {
  group('PromptDetector 默认正则', () {
    final d = PromptDetector();

    test('华为用户视图 <Huawei> 命中', () {
      expect(d.matches('<Huawei>'), isTrue);
    });

    test('华为系统视图 [Huawei] 命中', () {
      expect(d.matches('[Huawei]'), isTrue);
    });

    test('华为接口视图 [Huawei-GE0/0/1] 命中', () {
      expect(d.matches('[Huawei-GigabitEthernet0/0/1]'), isTrue);
    });

    test('Cisco 特权模式 Router# 命中', () {
      expect(d.matches('Router#'), isTrue);
    });

    test('Cisco 配置模式 Router(config)# 命中', () {
      expect(d.matches('Router(config)#'), isTrue);
    });

    test('提示符后带空格也命中', () {
      expect(d.matches('[CoreSW] '), isTrue);
    });

    test('匹配的是最后一个非空行', () {
      expect(d.matches('some output\r\nmore output\r\n[CoreSW]'), isTrue);
    });

    test('最后一行是普通内容时不命中', () {
      expect(d.matches('[CoreSW]\r\nInterface GE0/0/1 is UP'), isFalse);
    });

    test('以 ] 结尾的内容行会误判 —— 这是已知限制', () {
      // 记录该行为：静默去抖与"只看最后一非空行"是主要的缓解手段
      expect(d.matches('GigabitEthernet0/0/1 is up [OK]'), isTrue);
    });

    test('空缓冲区不命中', () {
      expect(d.matches(''), isFalse);
    });

    test('只有空白字符时不命中', () {
      expect(d.matches('\r\n   \r\n'), isFalse);
    });

    test('能穿透 ANSI 颜色码', () {
      expect(d.matches('\x1b[1m[CoreSW]\x1b[0m'), isTrue);
    });
  });

  group('PromptDetector 自定义正则', () {
    test('使用自定义正则', () {
      final d = PromptDetector(pattern: RegExp(r'>>>\s*$'));
      expect(d.matches('>>>'), isTrue);
      expect(d.matches('[CoreSW]'), isFalse);
    });
  });
}
