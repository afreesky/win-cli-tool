import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/ui/widgets/sent_line_controller.dart';

void main() {
  Future<TextSpan> spanOf(
    WidgetTester tester,
    SentLineController controller,
  ) async {
    late TextSpan span;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              style: const TextStyle(fontSize: 14),
              withComposing: false,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    return span;
  }

  testWidgets('没有已发送行时就是普通控制器', (tester) async {
    final controller = SentLineController()..text = '第一行\n第二行';
    addTearDown(controller.dispose);
    final span = await spanOf(tester, controller);
    expect(span.toPlainText(), '第一行\n第二行');
  });

  testWidgets('被标记的行用暗色，其余行不指定颜色', (tester) async {
    final controller = SentLineController()..text = '已发\n未发';
    addTearDown(controller.dispose);
    controller.sentLines.add(0);

    final span = await spanOf(tester, controller);
    expect(span.toPlainText(), '已发\n未发', reason: '高亮不能改动文本内容本身');

    final children = span.children!.cast<TextSpan>();
    final sent = children.firstWhere((s) => s.text == '已发');
    final unsent = children.firstWhere((s) => s.text == '未发');
    expect(sent.style?.color, isNotNull, reason: '已发送的行要被标出来');
    expect(unsent.style?.color, isNull, reason: '未发送的行保持主题默认色');
  });

  testWidgets('组字期间不改写 span（中文输入法靠这个）', (tester) async {
    final controller = SentLineController()..text = 'zhong';
    addTearDown(controller.dispose);
    controller.sentLines.add(0);
    controller.value = controller.value.copyWith(
      composing: TextRange(start: 0, end: 5),
    );

    late TextSpan span;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              style: const TextStyle(fontSize: 14),
              withComposing: true,
            );
            return const SizedBox();
          },
        ),
      ),
    );

    // 走的是父类实现 —— 组字下划线由此保留。
    //
    // **下划线不在根节点上。** `TextEditingController.buildTextSpan`（实测
    // SDK 源码）返回的是 `TextSpan(style: style, children: [前, 组字段, 后])`，
    // 根节点的 style 就是传进来的 `style`（这里是 `TextStyle(fontSize: 14)`，
    // 没有 decoration），**带下划线的是中间那个子节点**。所以断言必须落在
    // 那个子节点上 —— 写成 `expect(span.style?.decoration, ...)` 会**恒红**。
    expect(span.toPlainText(), 'zhong');
    final composing = span.children!
        .cast<TextSpan>()
        .firstWhere((s) => s.text == 'zhong');
    expect(composing.style?.decoration, TextDecoration.underline,
        reason: '组字下划线必须还在，否则中文输入法的候选提示会没有锚点');
  });

  testWidgets('标记按行号落在对应的行上', (tester) async {
    final controller = SentLineController()..text = 'a\nb\nc';
    addTearDown(controller.dispose);
    controller.sentLines
      ..clear()
      ..add(2);
    final span = await spanOf(tester, controller);
    final children = span.children!.cast<TextSpan>();
    expect(children.firstWhere((s) => s.text == 'c').style?.color, isNotNull);
    expect(children.firstWhere((s) => s.text == 'a').style?.color, isNull);
  });
}
