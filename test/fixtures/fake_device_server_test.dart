import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fake_device_server.dart';

void main() {
  group('FakeDeviceServer', () {
    test('连接后立即收到横幅与提示符', () async {
      final device = await FakeDeviceServer.start(prompt: '[CoreSW]');
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      final received = await socket
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .firstWhere((s) => s.contains('[CoreSW]'));

      expect(received, contains('Fake Device'));
      expect(received, contains('[CoreSW]'));
    });

    test('收到命令后回显、输出响应、再给出提示符', () async {
      final device = await FakeDeviceServer.start(
        prompt: '[CoreSW]',
        responseFor: {'show ver': ['Version 8.1', 'Uptime 3 days']},
      );
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      final chunks = <String>[];
      final done = Completer<void>();
      socket.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
        chunks.add(s);
        // 横幅里也有提示符，所以等到第二次出现提示符才算命令执行完
        if (chunks.join().split('[CoreSW]').length > 2 && !done.isCompleted) {
          done.complete();
        }
      });

      socket.add(utf8.encode('show ver\r\n'));
      await done.future;

      final all = chunks.join();
      expect(all, contains('show ver'));
      expect(all, contains('Version 8.1'));
      expect(all, contains('Uptime 3 days'));
      expect(device.receivedCommands, ['show ver']);
    });

    test('开启协商时先发出 Telnet IAC 序列', () async {
      final device = await FakeDeviceServer.start(negotiate: true);
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      final first = await socket.first;
      expect(first.take(3).toList(), [255, 251, 1]);
    });

    test('关闭协商时不发 IAC 序列', () async {
      final device = await FakeDeviceServer.start(negotiate: false);
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      final first = await socket.first;
      expect(first.first, isNot(255));
    });

    test('hangCommands 中的命令不回提示符', () async {
      final device = await FakeDeviceServer.start(
        prompt: '[CoreSW]',
        hangCommands: {'reboot'},
      );
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      var text = '';
      socket.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
        text += s;
      });

      socket.add(utf8.encode('reboot\r\n'));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // 只回显了命令，没有第二个提示符
      expect(text, contains('reboot'));
      expect('[CoreSW]'.allMatches(text).length, 1);
    });

    test('分页：输出若干行后插入翻页提示，收到空格才继续', () async {
      final device = await FakeDeviceServer.start(
        prompt: '[CoreSW]',
        pagerEvery: 2,
        responseFor: {
          'display cur': ['line1', 'line2', 'line3', 'line4'],
        },
      );
      addTearDown(device.stop);

      final socket = await Socket.connect('127.0.0.1', device.port);
      addTearDown(socket.destroy);

      var text = '';
      final sub = socket.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(
        (s) {
          text += s;
        },
      );
      addTearDown(sub.cancel);

      socket.add(utf8.encode('display cur\r\n'));

      // 等到第一页与翻页提示出现
      await _waitUntil(() => text.contains('---- More ----'));
      expect(text, contains('line1'));
      expect(text, contains('line2'));
      expect(text, isNot(contains('line3')));

      // 回送空格继续
      socket.add(utf8.encode(' '));
      await _waitUntil(() => text.split('[CoreSW]').length > 2);

      expect(text, contains('line3'));
      expect(text, contains('line4'));
    });
  });
}

/// 轮询等待条件成立，超时则抛错。
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
