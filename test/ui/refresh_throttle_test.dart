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
