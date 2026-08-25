import 'package:flutter/foundation.dart';
import 'source_account.dart';

/// 登录结果。
@immutable
class AuthResult {
  const AuthResult._({
    required this.success,
    this.profile,
    this.errorCode,
    this.errorMessage,
  });

  factory AuthResult.success(AccountProfile profile) => AuthResult._(
        success: true,
        profile: profile,
      );

  factory AuthResult.failure(String code, String message) => AuthResult._(
        success: false,
        errorCode: code,
        errorMessage: message,
      );

  final bool success;
  final AccountProfile? profile;
  final String? errorCode;
  final String? errorMessage;
}
