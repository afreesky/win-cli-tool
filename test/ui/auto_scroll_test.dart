import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/widgets/auto_scroll.dart';

void main() {
  /// 造一个 200 逻辑像素高的滚动区，每项 50 高。
  Future<(ScrollController, ValueNotifier<int>)> pumpList(
    WidgetTester tester, {
    int items = 5,
  }) async {
    final controller = ScrollController();
    final count = ValueNotifier<int>(items);
    addTearDown(controller.dispose);
    addTearDown(count.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: ValueListenableBuilder<int>(
              valueListenable: count,
              builder: (_, n, _) => ListView.builder(
                controller: controller,
                itemCount: n,
                itemBuilder: (_, i) => SizedBox(height: 50, child: Text('第 $i 行')),
              ),
            ),
          ),
        ),
      ),
    );
    return (controller, count);
  }

  testWidgets('一开始就是贴底的', (tester) async {
    final (controller, _) = await pumpList(tester);
    final auto = AutoScroll(controller: controller);
    expect(auto.stickToBottom, isTrue,
        reason: '刚打开输出区应当看到最新的一行，而不是最旧的一行');
  });

  testWidgets('内容变长时跟到底部', (tester) async {
    final (controller, count) = await pumpList(tester);
    final auto = AutoScroll(controller: controller);
    expect(controller.position.maxScrollExtent, 50, reason: '5×50 - 200');

    count.value = 30;
    await tester.pump();
    auto.onContentChanged();

    expect(controller.offset, controller.position.maxScrollExtent,
        reason: '新内容到达时应当滚到最新一行');
  });

  testWidgets('用户滚上去之后不再被拽回底部', (tester) async {
    final (controller, count) = await pumpList(tester);
    final auto = AutoScroll(controller: controller);

    count.value = 30;
    await tester.pump();
    auto.onContentChanged();
    expect(controller.offset, controller.position.maxScrollExtent);

    // 用户滚到顶 —— 这一步是直接改 offset，不经过手势。
    controller.jumpTo(0);
    auto.onUserScroll();
    expect(auto.stickToBottom, isFalse, reason: '滚离底部就该停止跟底');

    count.value = 60;
    await tester.pump();
    auto.onContentChanged();

    expect(controller.offset, 0,
        reason: '**这是这个类存在的理由**：用户在看上面的行时，新输出不该把他拽走');
  });

  testWidgets('用户滚回底部之后恢复跟底', (tester) async {
    final (controller, count) = await pumpList(tester);
    final auto = AutoScroll(controller: controller);

    count.value = 30;
    await tester.pump();
    auto.onContentChanged();
    controller.jumpTo(0);
    auto.onUserScroll();
    expect(auto.stickToBottom, isFalse);

    controller.jumpTo(controller.position.maxScrollExtent);
    auto.onUserScroll();
    expect(auto.stickToBottom, isTrue);

    count.value = 60;
    await tester.pump();
    auto.onContentChanged();
    expect(controller.offset, controller.position.maxScrollExtent);
  });

  testWidgets('jumpToBottom 无条件恢复跟底（"回到底部"按钮）', (tester) async {
    final (controller, count) = await pumpList(tester);
    final auto = AutoScroll(controller: controller);

    count.value = 30;
    await tester.pump();
    auto.onContentChanged();
    controller.jumpTo(0);
    auto.onUserScroll();
    expect(auto.stickToBottom, isFalse);

    auto.jumpToBottom();
    expect(auto.stickToBottom, isTrue);
    expect(controller.offset, controller.position.maxScrollExtent);
  });
}
