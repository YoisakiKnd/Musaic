import 'package:flutter/foundation.dart';

/// 登录方式枚举。
enum AuthType { cookie, password, token, qr, none }

/// 登录能力声明。
///
/// 渠道通过该声明告诉 UI 需要哪些字段、支持哪些登录方式。
@immutable
class AuthCapability {
  const AuthCapability({
    required this.authType,
    this.fields = const [],
    this.helpUrl,
    this.helpMarkdown,
  });

  final AuthType authType;
  final List<CredentialField> fields;
  final String? helpUrl;
  final String? helpMarkdown;

  bool get requiresFields => fields.isNotEmpty;
}

/// 登录表单字段声明。
@immutable
class CredentialField {
  const CredentialField({
    required this.key,
    required this.label,
    this.isSecret = false,
    this.placeholder,
    this.helperText,
  });

  final String key;
  final String label;
  final bool isSecret;
  final String? placeholder;
  final String? helperText;
}
