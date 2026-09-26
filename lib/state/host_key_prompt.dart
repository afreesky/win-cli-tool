import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/known_host.dart';

/// 一次"这台主机是首次连接，接不接受它的指纹"的询问（FR-C-11）。
///
/// 它同时是**回答的入口**（[complete]）与**等待的把手**（[answer]）——
/// `SshSession` 那边 `await` 的就是 [answer]。
class HostKeyPrompt {
  HostKeyPrompt(this.host);

  final KnownHost host;

  final _completer = Completer<bool>();

  /// 用户的回答。**容器销毁时会被判成 false**（见 [HostKeyPromptNotifier.build]）。
  Future<bool> get answer => _completer.future;

  void complete(bool accept) {
    if (!_completer.isCompleted) _completer.complete(accept);
  }
}

/// 待用户确认的主机密钥询问。
///
/// `state` 是**队头**（当前该显示的那一个），队列在 notifier 内部。
///
/// **为什么是队列而不是"只留最新一个"：** `connectAutoConnectDevicesAtStartup`
/// （FR-C-14）会同时给多台设备发起连接。只留最新的一个，前面那些的 `answer`
/// **永远不会完成**，那几台设备的 SSH 握手会永久挂着 —— 界面上一片"连接中"，
/// 而没有任何东西会把它推进下去。
class HostKeyPromptNotifier extends Notifier<HostKeyPrompt?> {
  final _queue = <HostKeyPrompt>[];

  @override
  HostKeyPrompt? build() {
    // **容器销毁 = 全部拒绝。** 不能只 drop 掉队列：那些 `answer` 还挂在
    // SSH 握手里，不完成就是泄漏一个永不结束的 Future。而"没人回答"这件事
    // 的默认答案**必须是拒绝** —— 与 `SshSession` 里
    // `onUnknownHostKey?.call(...) ?? false` 是同一个立场。
    ref.onDispose(() {
      for (final prompt in _queue) {
        prompt.complete(false);
      }
      _queue.clear();
    });
    return null;
  }

  /// 问用户。返回的 Future 在用户回答（或容器销毁）时兑现。
  Future<bool> ask(KnownHost host) {
    final prompt = HostKeyPrompt(host);
    _queue.add(prompt);
    if (state == null) state = prompt;
    return prompt.answer;
  }

  /// 回答。**只认当前队头那一个。**
  ///
  /// 身份校验是必须的：用户可能正开着 A 的对话框，而 B 的询问在此期间到达。
  /// 少了这一行，对 A 点下的"接受"会落到 B 上 —— 用户以为自己在批准 10.0.0.1
  /// 的指纹，被写进已知主机列表的却是 10.0.0.2 的那把密钥。
  void reply(HostKeyPrompt prompt, bool accept) {
    if (!identical(prompt, state)) return;
    _queue.remove(prompt);
    prompt.complete(accept);
    state = _queue.isEmpty ? null : _queue.first;
  }
}

final hostKeyPromptProvider =
    NotifierProvider<HostKeyPromptNotifier, HostKeyPrompt?>(
      HostKeyPromptNotifier.new,
    );
