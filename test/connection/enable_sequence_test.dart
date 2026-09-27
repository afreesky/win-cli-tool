import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';
import 'package:win_cli_tool/connection/connection_failure.dart';
import 'package:win_cli_tool/connection/enable_sequence.dart';

/// 真机实录（2026-09-26，锐捷 S6990，10.166.96.41）的时序与字节。
/// 分块投喂，是为了让"同一 chunk 里同时有回显与口令提示"这条路径也被走到。
const _echoEn = 'en\r\r\n';
const _passwordPrompt = '\r\r\nPassword:';
const _privileged = 'Ruijie#';

/// 建连横幅的尾巴。**它可能在 `en` 写下去之后才落地** —— 真机实测
/// （2026-09-27，锐捷 S6990）就慢了约 13ms，见下面那条回归用例。
const _bannerTail =
    'Last login: Oct  1 2000 00:04:29 from 10.166.96.30 through ssh.\r\r\n'
    'Ruijie>';

void main() {
  test('有口令：发 en → 等口令提示 → 发口令 → 等特权提示符', () {
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: 'enable-secret',
      );

      ConnectionFailure? result;
      var completed = false;
      seq.start().then((f) {
        result = f;
        completed = true;
      });

      // 建连横幅先到（此时还没发 en）—— 它绝不能被当成提权成功。
      seq.onOutput('Ruijie>');
      async.elapse(const Duration(milliseconds: 100));
      expect(completed, isFalse, reason: '建连横幅不是提权成功');

      // settleDelay 到点 → 发 en。
      async.elapse(const Duration(milliseconds: 300));
      expect(written, ['en\n']);

      seq.onOutput(_echoEn);
      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();
      expect(written, ['en\n', 'enable-secret\n'], reason: '看到口令提示就该发口令');

      seq.onOutput('\r\r\n');
      seq.onOutput(_privileged);
      async.flushMicrotasks();
      expect(completed, isTrue);
      expect(result, isNull, reason: 'null = 提权成功');
      // 定时器都清干净了，不然 fakeAsync 会报 "pending timers"。
      async.elapse(const Duration(minutes: 1));
    });
  });

  test('无口令（Cisco 形态 en 直达 #）：不发第二笔', () {
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: null,
      );

      ConnectionFailure? result;
      var completed = false;
      seq.start().then((f) {
        result = f;
        completed = true;
      });
      async.elapse(const Duration(milliseconds: 300));

      seq.onOutput('en\r\r\n');
      seq.onOutput('Ruijie#');
      async.flushMicrotasks();

      expect(completed, isTrue);
      expect(result, isNull);
      expect(written, ['en\n'], reason: '设备不问口令就不该有第二笔写入');
      async.elapse(const Duration(minutes: 1));
    });
  });

  test('设备要口令但没配：立刻报错，不把命令当口令喂进去', () {
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: null,
      );

      ConnectionFailure? result;
      seq.start().then((f) => result = f);
      async.elapse(const Duration(milliseconds: 300));

      seq.onOutput('en\r\r\n');
      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();

      expect(result, isNotNull);
      expect(result!.kind, ConnectionFailureKind.authFailed);
      expect(result!.message, contains('提权口令'));
      expect(written, ['en\n'], reason: '没有口令可发，绝不能把别的东西写下去');
      async.elapse(const Duration(minutes: 1));
    });
  });

  test('口令被拒：重来一遍；两次都被拒就报认证失败', () {
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: '错的',
      );

      ConnectionFailure? result;
      seq.start().then((f) => result = f);
      async.elapse(const Duration(milliseconds: 300));
      expect(written, ['en\n']);

      // 第一次：要口令 → 发 → 又被要（口令错）。
      seq.onOutput('en\r\r\n$_passwordPrompt');
      async.flushMicrotasks();
      expect(written, ['en\n', '错的\n']);

      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();
      expect(written, ['en\n', '错的\n', 'en\n'], reason: '口令被拒要重来一遍');

      // 第二次又被拒 → 两次用完，报错。
      seq.onOutput('en\r\r\n$_passwordPrompt');
      async.flushMicrotasks();
      expect(written, ['en\n', '错的\n', 'en\n', '错的\n']);

      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();

      expect(result, isNotNull);
      expect(result!.kind, ConnectionFailureKind.authFailed);
      expect(result!.message, contains('提权口令被拒'));
      async.elapse(const Duration(minutes: 1));
    });
  });

  test('设备没反应：重发一次，再没反应就报超时', () {
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: 'pw',
        attemptTimeout: const Duration(seconds: 6),
      );

      ConnectionFailure? result;
      seq.start().then((f) => result = f);

      async.elapse(const Duration(milliseconds: 300));
      expect(written, ['en\n']);

      // 第一次尝试超时 → 重发。
      async.elapse(const Duration(seconds: 6));
      expect(written, ['en\n', 'en\n']);

      // 第二次也超时 → 报错。
      async.elapse(const Duration(seconds: 6));
      expect(result, isNotNull);
      expect(result!.kind, ConnectionFailureKind.timeout);
      expect(result!.message, contains('提权超时'));
    });
  });

  test('口令以 # 结尾也不会被回显骗成成功', () {
    // 部分设备会回显口令，而口令本身可能以 `#` 或 `>` 结尾 ——
    // 直接拿最后一行去匹配，`abc#` 那行就变成了"特权提示符"。
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: 'abc#',
      );

      ConnectionFailure? result;
      var completed = false;
      seq.start().then((f) {
        result = f;
        completed = true;
      });
      async.elapse(const Duration(milliseconds: 300));

      seq.onOutput('en\r\r\n$_passwordPrompt');
      async.flushMicrotasks();
      seq.onOutput('abc#\r\r\n'); // 回显，末尾就是 '#'
      async.flushMicrotasks();
      expect(completed, isFalse, reason: '口令回显不是特权提示符');

      seq.onOutput('Ruijie#');
      async.flushMicrotasks();
      expect(completed, isTrue);
      expect(result, isNull);
      async.elapse(const Duration(minutes: 1));
    });
  });

  test('建连横幅的尾巴晚于 en 落地时，不能被当成提权成功', () {
    // **真机实测翻车的那一条**（2026-09-27，锐捷 S6990，10.166.96.41）。
    //
    // 设备的时序是：`session.connect()` 返回后约 315ms 才把横幅投递完，而
    // `settleDelay` 是 300ms —— 于是横幅最后那一段（`…ssh.\r\r\nRuijie>`）
    // 落在 `_writeAndWait` **清空缓冲之后**。此时缓冲里那个换行是**横幅自己的**，
    // `after` 又正好是提示符 `Ruijie>`，只判"有换行 + 后面是提示符"就会当场宣布
    // 提权成功 —— 而口令一个字都没发出去。
    //
    // 后果不是"慢一点"：设备停在 `Password:` 上，界面却进了"已连接"，随后
    // `show clock` 被当成口令喂进去（于是又弹一次 `Password:`），10s 后报
    // 「执行超时」。修法是让 `awaitingEnable` 阶段的成功判据**要求先看到回显**
    // —— 这正是类文档「回显闸门」一直声称的事，代码此前只是近似了它。
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: 'enable-secret',
      );

      ConnectionFailure? result;
      var completed = false;
      seq.start().then((f) {
        result = f;
        completed = true;
      });
      async.elapse(const Duration(milliseconds: 300));
      expect(written, ['en\n'], reason: 'settleDelay 到点先发 en');

      // 横幅的尾巴后到 —— 分块顺序照抄真机。
      seq.onOutput(_bannerTail);
      async.flushMicrotasks();
      expect(completed, isFalse, reason: '横幅的提示符不是提权成功');

      // 真正的回应：回显 → 口令提示。
      seq.onOutput(_echoEn);
      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();
      expect(written, ['en\n', 'enable-secret\n'], reason: '看到口令提示就该发口令');

      seq.onOutput('\r\r\n');
      seq.onOutput(_privileged);
      async.flushMicrotasks();
      expect(completed, isTrue);
      expect(result, isNull);
      async.elapse(const Duration(minutes: 1));
    });
  });

  test('口令被拒后退回登录提示符：报认证失败，绝不误报已提权', () {
    // **真机实测翻车的第二条**（2026-09-27，锐捷 S6990，10.166.96.41）。
    //
    // 口令错时锐捷**不会**再要一次口令，而是打印 `% Access denied` 之后
    // 直接回到**用户模式**提示符 `Ruijie>`。而默认提示符正则 `[>#\]]\s*$`
    // 对 `>` 与 `#` 一视同仁 —— 只判"最后一个非空行是提示符"就会把
    // "被退回用户模式"判成"提权成功"：界面进"已连接"、按钮是绿的，
    // 而用户随后每条命令都吃 `% User doesn't have sufficient privilege`。
    //
    // 判据只能来自**基准**：提权前那个提示符是 `Ruijie>`，提权成功后必须
    // 换一个（`Ruijie#`）；又看到 `Ruijie>` 就说明没提上去。
    fakeAsync((async) {
      final written = <String>[];
      final seq = EnableSequence(
        write: written.add,
        promptDetector: PromptDetector(),
        command: 'en',
        password: 'definitely-wrong',
      );

      ConnectionFailure? result;
      var completed = false;
      seq.start().then((f) {
        result = f;
        completed = true;
      });
      async.elapse(const Duration(milliseconds: 300));
      expect(written, ['en\n']);

      // 横幅的尾巴晚到（真机如此）—— 它给出 `Ruijie>` 这个基准。
      seq.onOutput(_bannerTail);
      async.flushMicrotasks();
      expect(completed, isFalse);

      // 第一次：要口令 → 发错口令 → 设备**又**要一次。
      seq.onOutput(_echoEn);
      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();
      expect(written, ['en\n', 'definitely-wrong\n']);

      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();
      expect(
        written,
        ['en\n', 'definitely-wrong\n', 'en\n'],
        reason: '口令被拒要重来一遍',
      );

      // 第二次：设备不再要口令，而是打印拒绝信息后**退回用户模式**。
      seq.onOutput(_echoEn);
      seq.onOutput(_passwordPrompt);
      async.flushMicrotasks();
      expect(written, [
        'en\n',
        'definitely-wrong\n',
        'en\n',
        'definitely-wrong\n',
      ]);

      seq.onOutput('\r\r\n% Access denied\r\r\nRuijie>');
      async.flushMicrotasks();

      expect(completed, isTrue);
      expect(result, isNotNull, reason: '退回用户模式提示符绝不能算提权成功');
      expect(result!.kind, ConnectionFailureKind.authFailed);
      expect(result!.message, contains('提权口令被拒'));
      async.elapse(const Duration(minutes: 1));
    });
  });
}
