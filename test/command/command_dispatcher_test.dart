import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/command/command_dispatcher.dart';
import 'package:win_cli_tool/command/more_pager.dart';
import 'package:win_cli_tool/command/prompt_detector.dart';

/// 测试脚手架：记录写出的内容，暴露事件流。
class _Harness {
  _Harness({String lineEnding = '\n', void Function(String)? write}) {
    dispatcher = CommandDispatcher(
      write: write ?? (data) => written.add(data),
      promptDetector: PromptDetector(),
      morePager: MorePager(),
      lineEnding: lineEnding,
      promptDebounce: const Duration(milliseconds: 120),
      commandTimeout: const Duration(seconds: 10),
    );
    dispatcher.events.listen(events.add);
  }

  late final CommandDispatcher dispatcher;
  final written = <String>[];
  final events = <DispatchEvent>[];

  List<CommandSent> get sent => events.whereType<CommandSent>().toList();
  List<CommandCompleted> get completed =>
      events.whereType<CommandCompleted>().toList();
}

void main() {
  group('入队与空行过滤', () {
    test('纯空行被过滤掉，不下发任何内容', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['', '   ', '\t', '']);
        async.flushMicrotasks();

        expect(h.written, isEmpty);
        expect(h.dispatcher.isBusy, isFalse);
      });
    });

    test('空行被跳过，非空行按序下发', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['sys', '', 'save']);
        async.flushMicrotasks();

        expect(h.written, ['sys\n']);
        expect(h.dispatcher.isBusy, isTrue);
      });
    });

    test('行尾符可配置为 \\r\\n', () {
      fakeAsync((async) {
        final h = _Harness(lineEnding: '\r\n');
        h.dispatcher.enqueue(['sys']);
        async.flushMicrotasks();

        expect(h.written, ['sys\r\n']);
      });
    });

    test('首尾空白被去掉后再下发', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['  sys  ']);
        async.flushMicrotasks();

        expect(h.written, ['sys\n']);
      });
    });
  });

  group('串行下发', () {
    test('未收到提示符前不下发第二条', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b', 'c']);
        async.flushMicrotasks();

        expect(h.written, ['a\n']);

        // 只来了回显，还没有提示符
        h.dispatcher.onOutput('a\r\n');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.written, ['a\n'], reason: '没有提示符就不该继续');

        // 提示符到达
        h.dispatcher.onOutput('[CoreSW]');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.written, ['a\n', 'b\n']);
      });
    });

    test('三条命令依次完成，事件顺序正确', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b', 'c']);
        async.flushMicrotasks();

        for (final cmd in ['a', 'b', 'c']) {
          h.dispatcher.onOutput('$cmd\r\n[CoreSW]');
          async.elapse(const Duration(milliseconds: 200));
        }

        expect(h.written, ['a\n', 'b\n', 'c\n']);
        expect(h.sent.map((e) => e.command).toList(), ['a', 'b', 'c']);
        expect(h.sent.map((e) => e.index).toList(), [1, 2, 3]);
        expect(h.sent.every((e) => e.total == 3), isTrue);
        expect(h.completed.map((e) => e.command).toList(), ['a', 'b', 'c']);
        expect(h.completed.every((e) => e.timedOut == false), isTrue);
        expect(h.events.whereType<QueueFinished>(), hasLength(1));
        expect(h.dispatcher.isBusy, isFalse);
      });
    });

    test('发送前重置缓冲，不会用上一条的提示符蒙混过关', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('a\r\n[CoreSW]');
        async.elapse(const Duration(milliseconds: 200));
        expect(h.written, ['a\n', 'b\n']);

        // 立刻推进去一个静默期，b 不应被判为完成
        async.elapse(const Duration(milliseconds: 200));
        expect(h.completed.map((e) => e.command).toList(), ['a']);
      });
    });
  });

  group('静默去抖', () {
    test('提示符出现但数据仍在流动时不判定完成', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('[CoreSW]');
        async.elapse(const Duration(milliseconds: 60)); // 不足去抖时长
        expect(h.written, ['a\n'], reason: '去抖未满，不该发下一条');

        h.dispatcher.onOutput('more data');
        async.elapse(const Duration(milliseconds: 60));
        expect(h.written, ['a\n'], reason: '新数据重置了去抖计时');

        async.elapse(const Duration(milliseconds: 200));
        // 缓冲区末尾是 "more data"，不匹配提示符 → 仍在等
        expect(h.written, ['a\n']);
      });
    });

    test('数据停住且末尾是提示符时判定完成', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('a\r\n[CoreSW]');
        async.elapse(const Duration(milliseconds: 119));
        expect(h.written, ['a\n']);

        async.elapse(const Duration(milliseconds: 2));
        expect(h.written, ['a\n', 'b\n']);
      });
    });

    test('内容行以 ] 结尾时会误判 —— 记录已知限制', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        // 这一行以 ] 结尾，且之后设备停顿超过去抖时长，
        // 于是被误判成提示符。spec §5.2 承认这是残留风险：
        // 静默去抖只能排除"数据仍在流动"的那部分误判。
        h.dispatcher.onOutput('GE0/0/1 is up [OK]');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.written, ['a\n', 'b\n']);
        expect(h.completed.single.command, 'a');
      });
    });

    test('内容行以 ] 结尾但随后仍有数据时不会误判', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        // 关键在于停顿不超过去抖窗口 —— 数据连续流动时不会误判
        h.dispatcher.onOutput('GE0/0/1 is up [OK');
        async.elapse(const Duration(milliseconds: 60));
        h.dispatcher.onOutput(']\r\n  still more output');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.written, ['a\n'], reason: '末尾不是提示符，应继续等待');
        expect(h.completed, isEmpty);
      });
    });
  });

  group('超时', () {
    test('超时后插入告警并强制放行下一条', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['hang', 'next']);
        async.flushMicrotasks();
        expect(h.written, ['hang\n']);

        h.dispatcher.onOutput('hang\r\n'); // 只回显，永不给提示符
        async.elapse(const Duration(seconds: 11));

        expect(h.written, ['hang\n', 'next\n']);
        expect(h.completed, hasLength(1));
        expect(h.completed.single.command, 'hang');
        expect(h.completed.single.timedOut, isTrue);
      });
    });

    test('write 同步抛异常时队列仍由超时兜底放行', () {
      fakeAsync((async) {
        final written = <String>[];
        var firstWrite = true;
        final h = _Harness(
          write: (data) {
            if (firstWrite) {
              firstWrite = false;
              // 模拟 StreamSink.add 落在已关闭的 controller 上这类同步抛出
              throw StateError('模拟 write 同步抛出');
            }
            written.add(data);
          },
        );

        expect(
          () => h.dispatcher.enqueue(['hang', 'next']),
          throwsA(isA<StateError>()),
        );
        async.flushMicrotasks();

        // 异常照常向外传播，但队列不能就此永久卡在"忙"状态：
        // 超时计时器必须已经起好，兜底强制放行。
        expect(h.dispatcher.isBusy, isTrue);

        async.elapse(const Duration(seconds: 11));

        expect(written, ['next\n'], reason: '超时后必须继续下发下一条');
        expect(h.completed, hasLength(1));
        expect(h.completed.single.command, 'hang');
        expect(h.completed.single.timedOut, isTrue);
      });
    });

    test('超时计时器在正常完成时被取消', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('a\r\n[CoreSW]');
        async.elapse(const Duration(milliseconds: 200));
        expect(h.completed.single.timedOut, isFalse);

        async.elapse(const Duration(seconds: 30));
        expect(h.completed, hasLength(1), reason: '不该有第二个完成事件');
      });
    });
  });

  group('翻页', () {
    test('识别翻页提示并回送空格', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();
        expect(h.written, ['display cur\n']);

        h.dispatcher.onOutput('line1\r\nline2\r\n  ---- More ----');
        async.flushMicrotasks();

        expect(h.written, ['display cur\n', ' ']);
        expect(h.events.whereType<PagerContinued>(), hasLength(1));
      });
    });

    test('翻页不推进队列，也不被当作命令完成', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('line1\r\n  ---- More ----');
        async.elapse(const Duration(milliseconds: 500));

        expect(h.completed, isEmpty);
        expect(h.written.last, ' ');
      });
    });

    test('翻页后继续输出，最终提示符到达才算完成', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();

        h.dispatcher.onOutput('line1\r\n  ---- More ----');
        async.flushMicrotasks();
        h.dispatcher.onOutput('line2\r\n[CoreSW]');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.completed.single.command, 'display cur');
        expect(h.written, ['display cur\n', ' ', 'next\n']);
      });
    });

    test('反复翻页不重置命令超时，一条命令仍只在 10s 处超时', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();
        expect(h.written, ['display cur\n']);

        // 设备在 t≈0s、4s、9s 各翻一页，之后彻底静默。翻页提示用
        // `---- More ----`：它不以 > 结尾，本来也匹配不上提示符正则，
        // 于是这里只考察超时有没有被翻页重置，不掺入翻页-vs-提示符的判定。
        h.dispatcher.onOutput('line1\r\n  ---- More ----');
        async.elapse(const Duration(seconds: 4));
        expect(h.completed, isEmpty, reason: '4s 时还没到超时');

        h.dispatcher.onOutput('line2\r\n  ---- More ----');
        async.elapse(const Duration(seconds: 5));
        expect(h.completed, isEmpty, reason: '9s 时还没到超时');

        h.dispatcher.onOutput('line3\r\n  ---- More ----');

        // 最后一次翻页落在 9s。spec §5.3 要求翻页**不得**重置命令超时
        // ——一条命令翻十页仍然只受一个 10s 超时约束。若翻页分支调用了
        // _restartTimeout()，deadline 会被推到 19s，t=10.2s 处将没有任何
        // 完成事件；设备一直翻页就能把队列永久挂住，正是该规则要防的。
        async.elapse(const Duration(milliseconds: 1200)); // 走到 t=10.2s

        expect(h.completed, hasLength(1), reason: '10s 处必须超时收尾');
        expect(h.completed.single.command, 'display cur');
        expect(h.completed.single.timedOut, isTrue);
        expect(
          h.written,
          ['display cur\n', ' ', ' ', ' ', 'next\n'],
          reason: '超时后仍要放行下一条',
        );
      });
    });

    test('以 > 结尾的翻页提示不会被误判为命令结束', () {
      fakeAsync((async) {
        // 对照组：`---- More ----` 不以 > 结尾，本来也匹配不上提示符正则，
        // 所以它在修复前后都不会被误判 —— 两边一比就能看出问题只在尾巴形态。
        final control = _Harness();
        control.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();
        control.dispatcher.onOutput('line1\r\n  ---- More ----');
        async.elapse(const Duration(milliseconds: 200));
        expect(control.completed, isEmpty);
        expect(control.written, ['display cur\n', ' ']);

        // 缺陷组：H3C 的 `<--- More --->` 以 > 结尾，能匹配提示符正则。
        // 去抖到点后若不显式排除翻页尾巴，命令会被判为完成，下一条命令
        // 就会被写进仍在翻页的设备，并被当作翻页键吃掉。
        final h = _Harness();
        h.dispatcher.enqueue(['display cur', 'next']);
        async.flushMicrotasks();
        h.dispatcher.onOutput('line1\r\n  <--- More --->');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.completed, isEmpty, reason: '翻页提示不是提示符，命令仍在途');
        expect(h.written, ['display cur\n', ' '], reason: '不该下发下一条命令');
        expect(h.dispatcher.isBusy, isTrue);
      });
    });
  });

  group('中止队列', () {
    test('中止后不再发送剩余命令', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b', 'c']);
        async.flushMicrotasks();
        expect(h.written, ['a\n']);

        h.dispatcher.abort();
        async.flushMicrotasks();

        expect(h.written, ['a\n'], reason: '中止后不该再写任何东西');
        expect(h.dispatcher.isBusy, isFalse);
        expect(h.events.whereType<QueueAborted>(), hasLength(1));
        expect(h.events.whereType<QueueAborted>().single.dropped, 2);
        expect(h.events.whereType<QueueFinished>(), isEmpty);
      });
    });

    test('中止后可以重新入队', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();
        h.dispatcher.abort();
        async.flushMicrotasks();

        h.dispatcher.enqueue(['x']);
        async.flushMicrotasks();

        expect(h.written, ['a\n', 'x\n']);
        expect(h.sent.last.index, 1);
        expect(h.sent.last.total, 1);
      });
    });

    test('空闲时中止不产生事件', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.abort();
        async.flushMicrotasks();

        expect(h.events, isEmpty);
      });
    });
  });

  group('断线', () {
    test('断线丢弃未发完的队列并告警', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b', 'c']);
        async.flushMicrotasks();
        expect(h.written, ['a\n']);

        h.dispatcher.onDisconnected();
        async.flushMicrotasks();

        expect(h.written, ['a\n'], reason: '断线后不应重放队列');
        expect(h.dispatcher.isBusy, isFalse);
        expect(h.events.whereType<QueueDropped>().single.count, 3);
      });
    });

    test('断线后超时计时器不再触发', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a']);
        async.flushMicrotasks();
        h.dispatcher.onDisconnected();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 30));
        expect(h.events.whereType<CommandCompleted>(), isEmpty);
      });
    });

    test('空闲时断线不产生丢弃事件', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.onDisconnected();
        async.flushMicrotasks();

        expect(h.events.whereType<QueueDropped>(), isEmpty);
      });
    });
  });

  group('缓冲区', () {
    test('缓冲区超限时丢弃最旧的数据', () {
      fakeAsync((async) {
        final h = _Harness();
        h.dispatcher.enqueue(['a', 'b']);
        async.flushMicrotasks();

        // 灌入远超缓冲上限的数据，末尾放提示符
        final flood = 'x' * 20000;
        h.dispatcher.onOutput(flood);
        async.elapse(const Duration(milliseconds: 200));
        expect(h.written, ['a\n'], reason: '缓冲区被冲掉了提示符，仍在等');

        h.dispatcher.onOutput('\r\n[CoreSW]');
        async.elapse(const Duration(milliseconds: 200));

        expect(h.written, ['a\n', 'b\n']);
      });
    });
  });
}
