/// 渠道账号领域模型（账号文档 §4.4）。
///
/// 三态状态机：loggedOut → loggedIn ⇄ expired。
/// 「过期」不删除凭据，仅标记状态并引导重新登录。
library;

enum AccountStatus { loggedOut, loggedIn, expired }

class SourceAccount {
  const SourceAccount({
    required this.sourceId,
    required this.status,
    this.userId,
    this.nickname,
    this.avatarUrl,
    this.updatedAt,
  });

  /// 新建一个「当前时刻」的账号状态。
  factory SourceAccount.markNow({
    required String sourceId,
    required AccountStatus status,
    String? userId,
    String? nickname,
    String? avatarUrl,
  }) {
    return SourceAccount(
      sourceId: sourceId,
      status: status,
      userId: userId,
      nickname: nickname,
      avatarUrl: avatarUrl,
      updatedAt: DateTime.now(),
    );
  }

  final String sourceId;
  final AccountStatus status;

  /// 资料字段（非敏感，可入 Hive 明文）。
  final String? userId;
  final String? nickname;
  final String? avatarUrl;

  /// 状态更新时间（用于启动恢复与调试）；从未更新时为 null。
  final DateTime? updatedAt;

  bool get isLoggedIn => status == AccountStatus.loggedIn;
  bool get isExpired => status == AccountStatus.expired;

  SourceAccount copyWith({
    AccountStatus? status,
    Object? userId = _unset,
    Object? nickname = _unset,
    Object? avatarUrl = _unset,
    bool touchUpdatedAt = true,
  }) {
    return SourceAccount(
      sourceId: sourceId,
      status: status ?? this.status,
      userId: identical(userId, _unset) ? this.userId : userId as String?,
      nickname:
          identical(nickname, _unset) ? this.nickname : nickname as String?,
      avatarUrl: identical(avatarUrl, _unset)
          ? this.avatarUrl
          : avatarUrl as String?,
      updatedAt:
          touchUpdatedAt ? DateTime.now() : updatedAt,
    );
  }

  static const Object _unset = Object();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sourceId': sourceId,
        'status': status.name,
        if (userId != null) 'userId': userId,
        if (nickname != null) 'nickname': nickname,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
        if (updatedAt != null) 'updatedAt': updatedAt!.millisecondsSinceEpoch,
      };

  factory SourceAccount.fromJson(Map<String, dynamic> json) {
    final rawUpdated = json['updatedAt'];
    return SourceAccount(
      sourceId: json['sourceId']! as String,
      status:
          AccountStatus.values.firstWhere((s) => s.name == json['status']),
      userId: json['userId'] as String?,
      nickname: json['nickname'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      updatedAt: rawUpdated == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(rawUpdated as int),
    );
  }

  @override
  String toString() =>
      'SourceAccount($sourceId, ${status.name}, user: $nickname)';
}
