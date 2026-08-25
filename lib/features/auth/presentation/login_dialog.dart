import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musaic/features/auth/domain/auth_capability.dart';
import 'package:musaic/features/auth/application/account_notifier.dart';
import 'package:musaic/core/source/music_source.dart';

class LoginDialog extends ConsumerStatefulWidget {
  const LoginDialog({super.key, required this.source});

  final MusicSource source;

  @override
  ConsumerState<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends ConsumerState<LoginDialog> {
  final _formKey = GlobalKey<FormState>();
  final _values = <String, String>{};
  bool _submitting = false;
  String? _error;
  late AuthCapability _capability;

  @override
  void initState() {
    super.initState();
    _capability = (widget.source as dynamic).authCapability ?? const AuthCapability(authType: AuthType.none);
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('登录 ${widget.source.sourceName}'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_capability.helpMarkdown != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _capability.helpMarkdown!,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ..._capability.fields.map(
                (field) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextFormField(
                    decoration: InputDecoration(
                      labelText: field.label,
                      hintText: field.placeholder,
                      helperText: field.helperText,
                    ),
                    obscureText: field.isSecret,
                    onSaved: (value) => _values[field.key] = value ?? '',
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return '请输入${field.label}';
                      }
                      return null;
                    },
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await ref
          .read(accountNotifierProvider.notifier)
          .login(widget.source.sourceId, _values);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _submitting = false;
        });
      }
    }
  }
}

