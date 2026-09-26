import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
// `Override` 不在 `flutter_riverpod.dart` 的主入口里（理由见 `ui_harness.dart`
// 开头那段注释）。`readerOf` 的返回类型用到它，少这一行本文件红在
// `non_type_as_type_argument`。
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/state/file_reader.dart';
import 'package:win_cli_tool/ui/dialogs/import_dialog.dart';
import 'package:win_cli_tool/ui/panels/editor_panel.dart';

import '../fixtures/fake_session.dart';
import 'ui_harness.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wct_import_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 让"磁盘上的文件"返回 [bytes]。
  List<Override> readerOf(List<int> bytes) => [
    fileReaderProvider.overrideWithValue((path) async => bytes),
  ];

  Future<void> openDialog(WidgetTester tester, {required List<int> bytes}) async {
    await pumpDialogHost(
      tester,
      root: root,
      buttonLabel: '打开',
      extra: readerOf(bytes),
      // `ImportDialog.show` 返回 `Future<ImportRequest?>`，而 `pumpDialogHost` 的
      // `open` 要的是 `Future<void> Function(BuildContext)` —— 这是合法的
      // （`Future<T> <: Future<void>`，任何类型都是 `void` 的子类型）。若分析器
      // 不认，改成 `open: (context) async { await ImportDialog.show(context); }`
      // 即可，**这属于脚手架，改完照实报告**。
      open: (context) => ImportDialog.show(context),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> typePath(WidgetTester tester) => tester.enterText(
    find.byKey(const ValueKey('import-path')),
    '/tmp/whatever.txt',
  );

  group('对话框本身', () {
    testWidgets('非 UTF-8 内容被拒，且明确说出来（FR-E-16）', (tester) async {
      // 0xFF 在任何位置都不是合法 UTF-8 的开始字节 —— GBK 文本里到处都是。
      await openDialog(tester, bytes: [0x41, 0xff, 0xfe, 0x42]);

      await typePath(tester);
      await tester.tap(find.text('替换现有内容'));
      await tester.pumpAndSettle();

      expect(find.textContaining('不是 UTF-8'), findsOneWidget);
      expect(find.text('替换现有内容'), findsOneWidget, reason: '没导入成功，对话框不该关');
    });

    testWidgets('读不到文件时给出可读的错误，不是 `FileSystemException` 原文', (tester) async {
      await pumpDialogHost(
        tester,
        root: root,
        buttonLabel: '打开',
        extra: [
          fileReaderProvider.overrideWithValue(
            (path) async => throw const FileSystemException('没有那个文件或目录', '/x'),
          ),
        ],
        open: (context) => ImportDialog.show(context),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      await typePath(tester);
      await tester.tap(find.text('替换现有内容'));
      await tester.pumpAndSettle();

      expect(find.textContaining('读不到这个文件'), findsOneWidget);
    });

    testWidgets('路径是空的时候不发 IO', (tester) async {
      await openDialog(tester, bytes: utf8.encode('x'));

      await tester.tap(find.text('追加到末尾'));
      await tester.pumpAndSettle();

      expect(find.text('请填写文件路径'), findsOneWidget);
    });
  });

  group('接到编辑区上', () {
    Future<TextEditingController> pumpEditor(
      WidgetTester tester, {
      required List<int> bytes,
    }) async {
      await pumpUi(
        tester,
        root: root,
        devices: [fakeProfile(id: 'd1', name: 'A')],
        extra: readerOf(bytes),
        child: const SizedBox(height: 400, child: EditorPanel(deviceId: 'd1')),
      );
      await settleDisk(tester);
      return tester.widget<TextField>(find.byType(TextField)).controller!;
    }

    Future<void> importAs(WidgetTester tester, String label) async {
      await tester.tap(find.byTooltip('导入文件'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('import-path')),
        '/tmp/x.txt',
      );
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('替换：编辑区变成文件内容（FR-E-15）', (tester) async {
      final editor = await pumpEditor(
        tester,
        bytes: utf8.encode('hostname R1\ninterface GE0/0/1\n'),
      );
      editor.value = const TextEditingValue(
        text: '旧内容',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await importAs(tester, '替换现有内容');

      expect(editor.text, 'hostname R1\ninterface GE0/0/1\n');
    });

    testWidgets('追加：原内容还在，接在后面（FR-E-15）', (tester) async {
      final editor = await pumpEditor(tester, bytes: utf8.encode('new'));
      editor.value = const TextEditingValue(
        text: 'old',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await importAs(tester, '追加到末尾');

      expect(editor.text, 'old\nnew');
    });

    testWidgets('追加到空编辑区：不产生开头的空行', (tester) async {
      final editor = await pumpEditor(tester, bytes: utf8.encode('new'));

      await importAs(tester, '追加到末尾');

      expect(editor.text, 'new');
    });

    testWidgets('取消：编辑区一个字都不动', (tester) async {
      final editor = await pumpEditor(tester, bytes: utf8.encode('new'));
      editor.value = const TextEditingValue(
        text: 'old',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('导入文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(editor.text, 'old');
    });
  });
}
