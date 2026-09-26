import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/device_store.dart';
import '../../models/device_profile.dart';
import '../../state/providers.dart';

/// 编辑一台设备时，改动**这些**字段不动它的会话（决策①）。
///
/// **写成"显示字段"的白名单、其余一律算连接参数，是为了让漏掉一个新字段的
/// 后果是"多断一次线"（用户重连即可），而不是"改了参数还连着旧会话"** ——
/// 后者的表现是用户以为新参数生效了，而设备上跑的还是旧凭据。
const _displayOnlyFields = {'name', 'autoConnect', 'snippets'};

/// 两台设备的**连接参数**是否不同。
///
/// 比的是逐字段的值，不是 `DeviceProfile` 的相等（它没有 `==`；就算有，
/// `snippets` 也在里面 —— 加一条命令片段不该断线）。
///
/// **列表按内容比，不按 identity。** `List` 不覆写 `==`，直接 `a != b` 会让
/// 两个内容相同的 `postLoginCommands` 判成不同 —— 那样每次保存都会断线一次。
bool connectionParamsDiffer(DeviceProfile before, DeviceProfile after) {
  final a = before.toJson();
  final b = after.toJson();
  for (final key in a.keys) {
    if (_displayOnlyFields.contains(key)) continue;
    if (!_sameJsonValue(a[key], b[key])) return true;
  }
  return false;
}

bool _sameJsonValue(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJsonValue(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// 设备编辑对话框（FR-D-01…05、11、12）。
///
/// 三个出口：
/// - **保存**（FR-D-02/03）：校验通过就写 `devicesProvider`；
/// - **取消**（FR-D-02）：什么都不写；
/// - **断开**（FR-C-05）：只在编辑一台**已存在**的设备时出现。它只断开、
///   不改任何字段 —— 它的用处是"参数写错了想重来"，不是"改完再断开"
///   （后者由 Task 5 的"改了连接参数就断开"负责）。
class DeviceEditDialog extends ConsumerStatefulWidget {
  const DeviceEditDialog({super.key, this.existing});

  /// null = 新增（FR-D-01）。
  final DeviceProfile? existing;

  static Future<void> show(BuildContext context, {DeviceProfile? existing}) =>
      showDialog<void>(
        context: context,
        builder: (_) => DeviceEditDialog(existing: existing),
      );

  @override
  ConsumerState<DeviceEditDialog> createState() => _DeviceEditDialogState();
}

class _DeviceEditDialogState extends ConsumerState<DeviceEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _privateKeyPath;
  late final TextEditingController _promptRegex;
  late final TextEditingController _postLogin;

  late DeviceProtocol _protocol;
  late String _lineEnding;
  late bool _autoConnect;

  /// 端口是不是**用户自己填过**（FR-D-03 的边界）。
  ///
  /// "切协议就换成该协议的默认端口"这条只在用户没指定过端口时才该生效 ——
  /// 一台跑在 2222 的 SSH 设备被切到 telnet 又切回来，端口不该被悄悄改成 22。
  ///
  /// 判断用显式的"动过没有"，而不是"`_port.text` 是否等于另一个协议的默认
  /// 端口"：后者会把一台**本来就配在 23 上**的设备误判成"没动过"。
  bool _portTouched = false;

  /// 程序自己在改端口（跟协议走）。此时不要把"用户动过"标上 ——
  /// 不挡这一下的话，第一次切协议就会把 `_portTouched` 置真，
  /// 第二次切协议端口就不跟着走了。
  bool _settingPortProgrammatically = false;

  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _protocol = existing?.protocol ?? DeviceProtocol.ssh;
    _lineEnding = existing?.lineEnding ?? '\n';
    _autoConnect = existing?.autoConnect ?? false;

    _name = TextEditingController(text: existing?.name ?? '');
    _host = TextEditingController(text: existing?.host ?? '');
    _port = TextEditingController(
      text: '${existing?.port ?? _protocol.defaultPort}',
    );
    _username = TextEditingController(text: existing?.username ?? '');
    _password = TextEditingController(text: existing?.password ?? '');
    _privateKeyPath = TextEditingController(
      text: existing?.privateKeyPath ?? '',
    );
    _promptRegex = TextEditingController(text: existing?.promptRegex ?? '');
    _postLogin = TextEditingController(
      text: (existing?.postLoginCommands ?? const []).join('\n'),
    );

    // 新增时端口不算"填过"：那时它是 FR-D-03 给的默认值，切协议就该跟着换。
    // 编辑一台已有的设备则相反 —— 盘上那个端口是用户的选择。
    _portTouched = existing != null;
    // **必须在上面的赋值之后**，否则 `_port.text` 那一次也会把标记置真。
    _port.addListener(_markPortTouched);
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _host,
      _port,
      _username,
      _password,
      _privateKeyPath,
      _promptRegex,
      _postLogin,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _markPortTouched() {
    if (_settingPortProgrammatically) return;
    _portTouched = true;
  }

  void _setPortToDefault(DeviceProtocol protocol) {
    _settingPortProgrammatically = true;
    _port.text = '${protocol.defaultPort}';
    _settingPortProgrammatically = false;
  }

  static String? _emptyToNull(String raw) {
    final value = raw.trim();
    return value.isEmpty ? null : value;
  }

  /// 保存。校验**全部在写盘之前**，任何一条不过就原地报错、什么都不写。
  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _fail('设备名不能为空');
      return;
    }
    final host = _host.text.trim();
    if (host.isEmpty) {
      _fail('主机地址不能为空');
      return;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _fail('端口必须是 1 到 65535 之间的整数');
      return;
    }
    if (_username.text.trim().isEmpty) {
      _fail('用户名不能为空');
      return;
    }

    // FR-D-04：设备名唯一。**口径与 `DeviceStore.save` 一致**（精确匹配、
    // 区分大小写）—— 两边口径不同的表现是"对话框说没问题，保存时却抛重名"。
    // store 那道校验仍然留着当兜底（见下面的 catch）。
    final self = widget.existing?.id;
    final clash = ref
        .read(devicesProvider)
        .any((d) => d.id != self && d.name == name);
    if (clash) {
      _fail('已有一台设备叫「$name」');
      return;
    }

    final promptRegex = _promptRegex.text.trim();
    if (promptRegex.isNotEmpty) {
      try {
        RegExp(promptRegex);
      } on FormatException catch (error) {
        // 坏正则不会当场出事 —— 它会让**提示符永远匹配不上**，表现是每条命令
        // 都跑满 `commandTimeout`（FR-E-12 的超时）。在这里挡住比在设备上发现好。
        _fail('提示符正则无法编译：${error.message}');
        return;
      }
    }

    final draft = DeviceProfile(
      // 新增时这个 id 会被 `add` 丢掉（id 是身份，见它的文档）。传一个有形状
      // 的值而不是空串，是为了万一 `add` 哪天不再换 id，也不至于留下空 id。
      id: self ?? newDeviceId(),
      name: name,
      protocol: _protocol,
      host: host,
      port: port,
      username: _username.text.trim(),
      // **空串要变成 null**（`_unset` 的文档）：null 是有语义的值 ——
      // "不启用密码认证"。留一个空串进去，认证那条路会拿空密码去试。
      password: _emptyToNull(_password.text),
      privateKeyPath: _emptyToNull(_privateKeyPath.text),
      lineEnding: _lineEnding,
      promptRegex: promptRegex.isEmpty ? null : promptRegex,
      postLoginCommands: _postLogin.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(growable: false),
      autoConnect: _autoConnect,
      // **片段只在命令库里改**，对话框不碰它。带上原值是为了不让 update 把它抹掉。
      snippets: widget.existing?.snippets ?? const [],
      // 同理，而且这一条更要紧：这一版的界面里根本没有跳板机这一项（整条链路
      // 已在别处砍掉），但 `jumpHostIds` 是**会持久化的字段**，在构造函数里
      // 默认 `const []`。不带上原值的话，编辑任何一台设备都会把盘上那条链
      // **静默抹成空** —— 对话框不会提示，用户也不会知道。
      jumpHostIds: widget.existing?.jumpHostIds ?? const [],
    );

    setState(() {
      _busy = true;
      _error = null;
    });

    // **SnackBar 的 messenger 要在 pop 之前抓。** pop 之后本 widget 的 context
    // 已经不能用了，而 `ScaffoldMessengerState` 活得比对话框长。
    final messenger = ScaffoldMessenger.of(context);
    final existing = widget.existing;
    var disconnected = false;

    try {
      if (existing == null) {
        await ref.read(devicesProvider.notifier).add(draft);
      } else {
        await ref.read(devicesProvider.notifier).update(draft);
        // 决策①：**改了连接参数就断开。** 不断的话，那条活着的会话用的还是
        // 旧主机/旧凭据，而界面上的设备行看起来已经"改好了"——用户以为在跟
        // 新设备说话。只改名字/自动连接/命令库则不动会话。
        if (connectionParamsDiffer(existing, draft)) {
          await ref.read(sessionProvider(existing.id).notifier).disconnect();
          disconnected = true;
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 重名异常带可直接展示的 `message`，别把 `toString()` 摆给用户
        // （`DuplicateDeviceNameError` 的文档点名了这件事）。
        _error = error is DuplicateDeviceNameError
            ? error.message
            : '保存失败：$error';
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    if (disconnected) {
      messenger.showSnackBar(
        const SnackBar(content: Text('连接参数已改变，已断开该设备，请重新连接')),
      );
    }
  }

  void _fail(String message) => setState(() => _error = message);

  Future<void> _disconnect() async {
    final existing = widget.existing;
    if (existing == null) return;
    await ref.read(sessionProvider(existing.id).notifier).disconnect();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已断开，改动在下次连接时生效')));
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return AlertDialog(
      title: Text(existing == null ? '添加设备' : '编辑设备'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // NFR-S-02：**必须告诉用户凭据是明文存的。** V1 有意接受这一点
              // （NFR-S-01），但用户有权知道 —— 否则他可能在这里填一个别处
              // 也在用的密码，而那个密码就躺在 devices.json 里。
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '提示：设备凭据以明文保存在 devices.json 中，'
                  '任何能读到该文件的人都能看到这里填的密码。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('device-name'),
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: '显示名称'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<DeviceProtocol>(
                key: const ValueKey('device-protocol'),
                initialValue: _protocol,
                decoration: const InputDecoration(labelText: '协议'),
                items: [
                  for (final p in DeviceProtocol.values)
                    DropdownMenuItem(value: p, child: Text(p.name)),
                ],
                onChanged: (next) {
                  if (next == null) return;
                  setState(() {
                    _protocol = next;
                    // FR-D-03：没自己指定过端口时，跟着协议换成默认端口。
                    if (!_portTouched) _setPortToDefault(next);
                  });
                },
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-host'),
                controller: _host,
                decoration: const InputDecoration(labelText: '主机地址'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-port'),
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '端口'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-username'),
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-password'),
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码（明文保存）',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-key-path'),
                controller: _privateKeyPath,
                decoration: const InputDecoration(
                  labelText: '私钥文件路径（可选，填了就用密钥认证）',
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const ValueKey('device-line-ending'),
                initialValue: _lineEnding,
                decoration: const InputDecoration(labelText: '行尾符'),
                items: const [
                  DropdownMenuItem(value: '\n', child: Text('LF (\\n)')),
                  DropdownMenuItem(
                    value: '\r\n',
                    child: Text('CRLF (\\r\\n)'),
                  ),
                ],
                onChanged: (next) {
                  if (next == null) return;
                  setState(() => _lineEnding = next);
                },
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-prompt-regex'),
                controller: _promptRegex,
                decoration: const InputDecoration(
                  labelText: '提示符正则（可选，留空用全局默认）',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('device-post-login'),
                controller: _postLogin,
                maxLines: 3,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: '登录后执行（一行一条，FR-D-11）',
                  border: OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                key: const ValueKey('device-autoconnect'),
                contentPadding: EdgeInsets.zero,
                title: const Text('启动时自动连接'),
                value: _autoConnect,
                onChanged: (next) => setState(() => _autoConnect = next),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (existing != null)
          TextButton(
            onPressed: _busy ? null : _disconnect,
            child: const Text('断开'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
