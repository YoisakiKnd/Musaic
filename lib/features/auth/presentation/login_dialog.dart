import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/source/music_source.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/account_notifier.dart';
import '../../../core/auth/auth_capability.dart';
import '../../../core/auth/auth_result.dart';

/// 声明式动态登录弹窗（账号文档 §7）。
///
/// 表单字段完全由渠道 [AuthCapability.fields] 驱动；
/// 内嵌「如何获取 MUSIC_U」图文指引；新增渠道 UI 零改动。
Future<void> showLoginDialog(BuildContext context, MusicSource source) {
  return showDialog<void>(
    context: context,
    builder: (_) => _LoginDialog(source: source),
  );
}

class _LoginDialog extends ConsumerStatefulWidget {
  const _LoginDialog({required this.source});

  final MusicSource source;

  @override
  ConsumerState<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends ConsumerState<_LoginDialog> {
  final Map<String, TextEditingController> _controllers = {};
  bool _submitting = false;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(CredentialField field) {
    return _controllers.putIfAbsent(
      field.key,
      TextEditingController.new,
    );
  }

  Future<void> _submit() async {
    final capability = widget.source.authCapability;
    final credentials = <String, String>{
      for (final field in capability.fields)
        field.key: _controllerFor(field).text,
    };
    setState(() => _submitting = true);
    final result = await ref
        .read(accountsProvider.notifier)
        .login(widget.source.sourceId, credentials);
    if (!mounted) return;
    setState(() => _submitting = false);

    switch (result) {
      case AuthSuccess(:final account):
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('欢迎，${account.nickname ?? '用户'}')),
        );
      case AuthFailure(:final message):
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final capability = widget.source.authCapability;
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusSheet),
      ),
      title: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: AppTokens.accent.withValues(alpha: 0.15),
            child: Text(
              widget.source.displayName.characters.first,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppTokens.accent,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('登录${widget.source.displayName}',
              style: const TextStyle(fontSize: 18)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final field in capability.fields) ...[
              TextField(
                controller: _controllerFor(field),
                obscureText: field.obscure,
                decoration: InputDecoration(
                  labelText: field.label,
                  hintText: field.placeholder,
                  helperText: field.hint,
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(AppTokens.radiusChip),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (capability.guide != null)
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  leading: const Icon(Icons.help_outline_rounded,
                      color: AppTokens.accent),
                  title: Text(capability.guide!.title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  children: [
                    for (var i = 0;
                        i < capability.guide!.steps.length;
                        i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${i + 1}. ',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: AppTokens.accent,
                                )),
                            Expanded(
                              child: Text(
                                capability.guide!.steps[i],
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                  color: scheme.onSurface
                                      .withValues(alpha: 0.75),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTokens.accent),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('登录'),
        ),
      ],
    );
  }
}
