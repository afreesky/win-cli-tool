import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/telnet_protocol.dart';

void main() {
  const iac = TelnetProtocol.iac;
  const will = TelnetProtocol.will;
  const wont = TelnetProtocol.wont;
  const doVerb = TelnetProtocol.doVerb;
  const dont = TelnetProtocol.dont;
  const sb = TelnetProtocol.sb;
  const se = TelnetProtocol.se;
  const optEcho = TelnetProtocol.optEcho;
  const optSga = TelnetProtocol.optSuppressGoAhead;

  group('TelnetProtocol 数据与协商的分离', () {
    test('纯数据原样透传', () {
      final p = TelnetProtocol();
      final r = p.feed('hello'.codeUnits);

      expect(r.data, 'hello'.codeUnits);
      expect(r.response, isEmpty);
    });

    test('协商序列不进入用户数据', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, will, optEcho, ...'ok'.codeUnits]);

      expect(r.data, 'ok'.codeUnits);
    });

    test('转义的 0xFF 还原成一个字节', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, iac, 0x41]);

      expect(r.data, [255, 0x41]);
    });

    test('子协商内容被整体吞掉', () {
      final p = TelnetProtocol();
      final r = p.feed([
        iac, sb, 24, 1, iac, se, // IAC SB TTYPE SEND IAC SE
        ...'x'.codeUnits,
      ]);

      expect(r.data, 'x'.codeUnits);
    });
  });

  group('协商应答', () {
    test('对端 DO SGA 时我方回 WILL SGA', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, doVerb, optSga]);

      expect(r.response, [iac, will, optSga]);
      expect(r.data, isEmpty);
    });

    test('对端 DO 一个我们不支持的选项时回 WONT', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, doVerb, 24]); // TTYPE

      expect(r.response, [iac, wont, 24]);
    });

    test('对端 WILL ECHO 时我方回 DO ECHO', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, will, optEcho]);

      expect(r.response, [iac, doVerb, optEcho]);
    });

    test('对端 WILL 一个我们不支持的选项时回 DONT', () {
      final p = TelnetProtocol();
      final r = p.feed([iac, will, 39]); // NEW-ENVIRON

      expect(r.response, [iac, dont, 39]);
    });

    test('对端 WONT / DONT 时不回应', () {
      final p = TelnetProtocol();
      expect(p.feed([iac, wont, optEcho]).response, isEmpty);
      expect(p.feed([iac, dont, optSga]).response, isEmpty);
    });
  });

  group('分帧边界', () {
    test('协商序列被切开在两个分片里也能正确解析', () {
      final p = TelnetProtocol();

      final r1 = p.feed([iac]);
      expect(r1.data, isEmpty);
      expect(r1.response, isEmpty);

      final r2 = p.feed([doVerb]);
      expect(r2.response, isEmpty);

      final r3 = p.feed([optSga]);
      expect(r3.response, [iac, will, optSga]);
    });

    test('数据被切成多片后拼接结果正确', () {
      final p = TelnetProtocol();
      final out = <int>[];
      out.addAll(p.feed('ab'.codeUnits).data);
      out.addAll(p.feed('cd'.codeUnits).data);
      out.addAll(p.feed('ef'.codeUnits).data);

      expect(out, 'abcdef'.codeUnits);
    });

    test('一次分片里包含多组协商与数据', () {
      final p = TelnetProtocol();
      final r = p.feed([
        iac, will, optEcho,
        ...'A'.codeUnits,
        iac, doVerb, optSga,
        ...'B'.codeUnits,
      ]);

      expect(r.data, 'AB'.codeUnits);
      expect(r.response, [
        iac, doVerb, optEcho,
        iac, will, optSga,
      ]);
    });
  });
}
