import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';

/// 文本输入对话框：**对话框自己持有并销毁** [TextEditingController]。
///
/// ## 为什么必须独立成 StatefulWidget
///
/// 在调用方创建 controller、`await showDialog(...)` 返回后立刻 `dispose()`，
/// 会踩到 Flutter 的一个经典陷阱：`showDialog` 的 Future 在**退场动画开始前**
/// 就 resolve 了，而退场动画期间 [TextField] 仍然存活并继续读 controller，
/// 于是抛出 `A TextEditingController was used after being disposed`。
///
/// 反过来（在方法内 `TextEditingController()` 创建后从不 dispose）则是
/// 静默内存泄漏——不崩溃，所以更难发现。
///
/// 两种写法都在本项目出现过（歌单重命名、新建歌单、保存全部结果为歌单）。
/// 统一走这里：controller 的创建与销毁都与对话框的 State 同生命周期，
/// 调用方只 `await` 拿结果，**不持有也不销毁** controller。
///
/// 返回值为**已 trim** 的输入；取消 / 点击遮罩 / 返回键 → `null`。
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? initialValue,
  String? hintText,
}) {
  return showDialog<String>(
    context: context,
    builder:
        (_) => _TextInputDialog(
          title: title,
          confirmLabel: confirmLabel,
          initialValue: initialValue,
          hintText: hintText,
        ),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.confirmLabel,
    this.initialValue,
    this.hintText,
  });

  final String title;
  final String confirmLabel;
  final String? initialValue;
  final String? hintText;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(hintText: widget.hintText ?? '歌单名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTokens.accent),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
