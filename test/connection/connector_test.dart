import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_cli_tool/connection/connector.dart';

void main() {
  group('DirectConnector', () {
    late ServerSocket server;
    late int port;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
    });

    tearDown(() async {
      await server.close();
    });

    test('建立连接后可以收发数据', () async {
      final serverGot = Completer<String>();
      server.listen((socket) {
        socket.listen((data) {
          if (!serverGot.isCompleted) {
            serverGot.complete(utf8.decode(data));
          }
        });
      });

      const connector = DirectConnector();
      final conn = await connector.open('127.0.0.1', port);
      conn.write(utf8.encode('hello'));
      await conn.flush();
      await conn.close();

      await expectLater(serverGot.future, completion('hello'));
    });

    test('input 流能收到服务端发来的数据', () async {
      server.listen((socket) {
        socket.add(utf8.encode('from-server'));
      });

      const connector = DirectConnector();
      final conn = await connector.open('127.0.0.1', port);

      final received = await conn.input
          .transform(const Utf8Decoder(allowMalformed: true))
          .firstWhere((s) => s.contains('from-server'));

      expect(received, contains('from-server'));
      await conn.close();
    });

    test('端口无人监听时抛 SocketException', () async {
      // 先关闭 server 以释放端口
      final freePort = server.port;
      await server.close();

      const connector = DirectConnector();
      await expectLater(
        connector.open('127.0.0.1', freePort),
        throwsA(isA<SocketException>()),
      );
    });

    test('连接超时抛出 SocketException 或 TimeoutException', () async {
      // 192.0.2.0/24 是 RFC 5737 保留的测试网段，不可路由，连接会一直挂起。
      // dart:io 在不同平台上报超时用的异常类型不完全一致，两种都接受。
      const connector = DirectConnector();
      await expectLater(
        connector.open(
          '192.0.2.1',
          80,
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(anyOf(isA<SocketException>(), isA<TimeoutException>())),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
