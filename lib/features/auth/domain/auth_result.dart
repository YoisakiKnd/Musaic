import 'source_account.dart';

/// 登录失败原因分类（账号文档 §4.5）。
enum AuthFailureReason {
  /// 网络不通 / 超时。
  network,

  /// 凭据无效（Cookie 失效、密码错误等）。
  invalidCredentials,

  /// 服务端错误。
  serverError,

  /// 该渠道不支持程序化登录。
  unsupported,

  /// 其他未知错误。
  unknown,
}

/// 登录结果。
sealed class AuthResult {
  const AuthResult();
}

class AuthSuccess extends AuthResult {
  const AuthSuccess(this.account);

  final SourceAccount account;
}

class AuthFailure extends AuthResult {
  const AuthFailure({required this.reason, required this.message});

  final AuthFailureReason reason;
  final String message;
}
