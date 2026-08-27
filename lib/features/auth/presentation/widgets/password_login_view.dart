import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_capability.dart';
import '../../../../core/auth/auth_result.dart';
import '../../../../core/source/capabilities.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../application/account_notifier.dart';

/// 通用密码登录表单：字段完全由 [PasswordLoginCapable.passwordFields] 驱动。
/// 成功后凭据经 [AccountNotifier.completeLogin] 落安全存储并关闭路由。
class PasswordLoginView extends ConsumerStatefulWidget {
  const PasswordLoginView({
    super.key,
    required this.sourceId,
    required this.login,
  });

  final String sourceId;
  final PasswordLoginCapable login;

  @override
  ConsumerState<PasswordLoginView> createState() => _PasswordLoginViewState();
}

class _PasswordLoginViewState extends ConsumerState<PasswordLoginView> {
  final Map<String, TextEditingController> _controllers = {};
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(CredentialField field) =>
      _controllers.putIfAbsent(field.key, TextEditingController.new);

  Future<void> _submit() async {
    final fields = widget.login.passwordFields;
    final values = <String, String>{
      for (final field in fields)
        field.key: _controllerFor(field).text.trim(),
    };
    if (values.values.any((v) => v.isEmpty)) {
      setState(() => _error = '请完整填写所有字段');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final result = await widget.login.loginWithPassword(values);
    if (!mounted) return;
    setState(() => _submitting = false);
    switch (result) {
      case AuthSuccess(:final account, :final credentials):
        await ref.read(accountsProvider.notifier).completeLogin(
              widget.sourceId,
              credentials,
              account,
            );
        if (!mounted) return;
        Navigator.of(context).pop(true);
      case AuthFailure(:final message):
        setState(() => _error = message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final field in widget.login.passwordFields) ...[
            TextField(
              controller: _controllerFor(field),
              obscureText: field.obscure,
              keyboardType:
                  field.numeric ? TextInputType.phone : TextInputType.text,
              decoration: InputDecoration(
                labelText: field.label,
                hintText: field.placeholder,
                helperText: field.hint,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(fontSize: 13, color: scheme.error),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text('登录'),
          ),
          const SizedBox(height: 12),
          Text(
            widget.login.passwordSubmitHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }
}
