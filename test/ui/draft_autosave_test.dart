import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/draft_autosave.dart';

void main() {
  test('编辑停顿之后才落盘，连串编辑只落一次', () {
    fakeAsync((async) {
      final saved = <String>[];
      final autosave = DraftAutosave(
        save: (text) async => saved.add(text),
        debounce: const Duration(milliseconds: 500),
      );

      autosave.schedule('a');
      async.elapse(const Duration(milliseconds: 100));
      autosave.schedule('ab');
      async.elapse(const Duration(milliseconds: 100));
      autosave.schedule('abc');
      expect(saved, isEmpty, reason: '停顿还没到，不该落盘');

      async.elapse(const Duration(milliseconds: 500));
      expect(saved, ['abc'], reason: '只落最后那一次');

      autosave.dispose();
    });
  });

  test('flush 立刻落盘并取消待定的防抖（退出兜底，FR-E-04）', () {
    fakeAsync((async) {
      final saved = <String>[];
      final autosave = DraftAutosave(
        save: (text) async => saved.add(text),
        debounce: const Duration(milliseconds: 500),
      );

      autosave.schedule('写了一半');
      autosave.flush();
      expect(saved, ['写了一半'], reason: '退出时必须立刻落盘，不能等防抖');

      // 防抖定时器**应当**被取消。但下面这一条断言**钉不住"取消"本身** ——
      // 即便那个定时器漏掉了，它到点时 `_pending` 已被 `flush` 清空，`_write`
      // 会当场早退，写不出第二次。我构造不出让漏取消咬人的用例（要 `_pending`
      // 非空才有效，而 `schedule` 又会先取消旧定时器），所以这里只把"退出后不
      // 再多写一次"当作依据，**不声称它验了取消**。
      async.elapse(const Duration(seconds: 2));
      expect(saved, ['写了一半']);

      autosave.dispose();
    });
  });

  test('内容没变就不落盘（切设备/重建不该产生无谓的写）', () {
    fakeAsync((async) {
      final saved = <String>[];
      final autosave = DraftAutosave(
        save: (text) async => saved.add(text),
        debounce: const Duration(milliseconds: 100),
      );

      autosave.schedule('same');
      async.elapse(const Duration(milliseconds: 200));
      expect(saved, ['same']);

      autosave.schedule('same');
      async.elapse(const Duration(milliseconds: 200));
      expect(saved, ['same'], reason: '与上次落盘的内容相同就不再写');

      autosave.dispose();
    });
  });

  test('落盘失败不抛出（FR-E-04 不该拖垮界面）', () {
    fakeAsync((async) {
      final errors = <Object>[];
      final autosave = DraftAutosave(
        save: (text) async => throw StateError('磁盘满了'),
        debounce: const Duration(milliseconds: 50),
        onError: errors.add,
      );

      autosave.schedule('x');
      async.elapse(const Duration(milliseconds: 100));

      expect(errors, hasLength(1), reason: '失败要报给调用方去提示');
      // 关键：异常没有冒到 zone 外 —— fakeAsync 里未捕获的异步异常会让用例红。

      autosave.dispose();
    });
  });

  test('dispose 之后不再落盘', () {
    fakeAsync((async) {
      final saved = <String>[];
      final autosave = DraftAutosave(
        save: (text) async => saved.add(text),
        debounce: const Duration(milliseconds: 50),
      );

      autosave.schedule('x');
      autosave.dispose();
      async.elapse(const Duration(seconds: 1));
      expect(saved, isEmpty, reason: 'dispose 要取消待定的写');
    });
  });
}
