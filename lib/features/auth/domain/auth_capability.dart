/// 声明式登录能力（账号文档 §4.2 / §4.3）。
///
/// 渠道通过 [AuthCapability] 声明支持的登录方式与表单字段，
/// 登录弹窗据此动态渲染，新增渠道 UI 零改动。
library;

enum AuthType {
  /// 免登录（本地文件等）。
  none,

  /// Cookie 纯值登录（网易云 MUSIC_U）。
  cookie,

  /// 账号密码登录（V1.2 新渠道预留）。
  password,

  /// Token 登录（V1.2 Subsonic 等预留）。
  token,
}

/// 登录表单字段声明。
class CredentialField {
  const CredentialField({
    required this.key,
    required this.label,
    this.obscure = false,
    this.placeholder,
    this.hint,
  });

  /// 字段键（即凭据存储键），如 `MUSIC_U`、`password`。
  final String key;

  /// 展示标签。
  final String label;

  /// 是否密文显示。
  final bool obscure;

  final String? placeholder;

  /// 输入框下方的辅助说明。
  final String? hint;
}

/// 图文指引（如「如何获取 MUSIC_U」）。
class AuthGuide {
  const AuthGuide({required this.title, required this.steps});

  final String title;
  final List<String> steps;
}

class AuthCapability {
  const AuthCapability({
    required this.type,
    this.fields = const <CredentialField>[],
    this.guide,
  });

  /// 免登录能力的共享实例。
  static const AuthCapability noAuth =
      AuthCapability(type: AuthType.none);

  final AuthType type;
  final List<CredentialField> fields;
  final AuthGuide? guide;

  bool get requiresLogin => type != AuthType.none;
}
