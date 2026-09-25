import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/widgets/refresh_throttle.dart';

/// 假的变更源：测试自己决定什么时候"变了"。
class _Source extends ChangeNotifier {
  void ping() => notifyListeners();
}

void main() {
  test('第一次变更立刻放行（用户操作不能等 60ms）', () {
    fakeAsync((async) {
      final source = _Source();
      final throttle = RefreshThrottle(source: source);
      var notified = 0;
      throttle.addListener(() => notified++);

      source.ping();
      expect(notified, 1, reason: '第一次不该被压');

      throttle.dispose();
      source.dispose();
    });
  });

  test('紧接着的连串变更被压成一次', () {
    fakeAsync((async) {
      final source = _Source();
      final throttle = RefreshThrottle(source: source);
      var notified = 0;
      throttle.addListener(() => notified++);

      source.ping(); // 立刻放行，计数 1
      for (var i = 0; i < 50; i++) {
        source.ping();
      }
      expect(notified, 1, reason: '60ms 窗口内的连串变更不该各算一次');

      async.elapse(const Duration(milliseconds: 60));
      expect(notified, 2, reason: '窗口到点时补一次，把 50 次变更合并成 1 次');

      // 没有被压住的变更时，定时器不再空转。
      async.elapse(const Duration(milliseconds: 300));
      expect(notified, 2, reason: '没有新变更就不该继续通知');

      throttle.dispose();
      source.dispose();
    });
  });

  test('200 行/秒的速率下，通知数远小于变更数（NFR-F-03 的速率）', () {
    fakeAsync((async) {
      final source = _Source();
      final throttle = RefreshThrottle(source: source);
      var notified = 0;
      throttle.addListener(() => notified++);

      // 1 秒内 200 次变更 —— 每次变更对应一次 buffer.add。
      for (var i = 0; i < 200; i++) {
        source.ping();
        async.elapse(const Duration(milliseconds: 5));
      }

      expect(notified, lessThanOrEqualTo(20),
          reason: '1 秒 / 60ms ≈ 16 次，留一点余量');

      throttle.dispose();
      source.dispose();
    });
  });

  test('监听者在通知里同步回写 source 时，当场不再通知第二次', () {
    fakeAsync((async) {
      final source = _Source();
      final throttle = RefreshThrottle(source: source);
      var notified = 0;
      // 监听者在通知里**同步**回写 source。当前没有消费者这么做，但这是
      // `ChangeNotifier` 明确允许的用法，而本类的整个职责就是时序正确。
      var reentered = false;
      throttle.addListener(() {
        notified++;
        if (reentered) return;
        reentered = true;
        source.ping();
      });

      source.ping();

      // **判别力在这里，而且它是合同不是实现细节。** 本类承诺"至多每 interval
      // 一次"，而这次回写落在**同一个窗口内**，所以它只能被攒成 `_pending`，
      // 不能当场再通知一次。
      //
      // 若 `notifyListeners()` 排在武装定时器**之前**，回写那一跳会看到
      // `_timer` 还是 null，于是走进"首次变更立刻放行"分支 —— 当场嵌套通知
      // 第二次，并武装出一个随即被外层覆盖、此后再也 cancel 不到的定时器。
      // 这里断言 1 就是钉住那个形状。
      expect(notified, 1, reason: '同一窗口内的回写必须被合并，不能当场再通知');

      // 而那次回写不能被丢掉：窗口到点时要补上。
      async.elapse(const Duration(milliseconds: 60));
      expect(notified, 2, reason: '回写攒下的变更要在窗口到点时补一次');

      async.elapse(const Duration(seconds: 1));
      expect(notified, 2, reason: '没有新变更就不该继续通知');

      throttle.dispose();
      source.dispose();
    });
  });

  test('dispose 之后定时器不再触发', () {
    fakeAsync((async) {
      final source = _Source();
      final throttle = RefreshThrottle(source: source);
      var notified = 0;
      throttle.addListener(() => notified++);

      source.ping();
      source.ping();
      throttle.dispose();

      async.elapse(const Duration(seconds: 1));
      expect(notified, 1, reason: 'dispose 之后不该再有通知');
      source.dispose();
    });
  });
}
