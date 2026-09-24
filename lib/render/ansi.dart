/// CSI 序列：ESC [ 参数 中间字节 终止字节。
/// 覆盖颜色（SGR）、光标移动、擦除等绝大多数控制序列。
final _csi = RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]');

/// OSC 序列：ESC ] ... BEL 或 ESC \。
final _osc = RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)');

/// 其余两字节转义序列，如 ESC ( B（选择字符集）。
final _twoByte = RegExp(r'\x1b[@-Z\\-_]');

/// 剥离所有 ANSI 控制序列，只留可读文本。
///
/// 提示符判定必须先做这一步：设备可能给提示符上色，带颜色的
/// `\x1b[1m[CoreSW]\x1b[0m` 直接用正则匹配末尾的 `]` 是匹配不上的。
String stripAnsi(String input) {
  if (!input.contains('\x1b')) return input;
  return input
      .replaceAll(_csi, '')
      .replaceAll(_osc, '')
      .replaceAll(_twoByte, '')
      // 单独出现的 \r 是终端覆盖写，行内清掉避免污染行尾判定
      .replaceAll('\r', '');
}
