import 'package:flutter/foundation.dart';

/// 账号登录状态。
enum AccountStatus { loggedOut, loggedIn, expired }

/// 渠道账号资料。
@immutable
class SourceAccount {
  const SourceAccount({
    required this.sourceId,
    required this.status,
    this.profile,
    this.lastCheckedAt,
    this.expiredAt,
  });

  final String sourceId;
  final AccountStatus status;
  final AccountProfile? profile;
  final DateTime? lastCheckedAt;
  final DateTime? expiredAt;

  SourceAccount copyWith({
    String? sourceId,
    AccountStatus? status,
    AccountProfile? profile,
    DateTime? lastCheckedAt,
    DateTime? expiredAt,
  }) {
    return SourceAccount(
      sourceId: sourceId ?? this.sourceId,
      status: status ?? this.status,
      profile: profile ?? this.profile,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      expiredAt: expiredAt ?? this.expiredAt,
    );
  }
}

/// 账号公开资料。
@immutable
class AccountProfile {
  const AccountProfile({
    required this.userId,
    this.nickname,
    this.avatarUrl,
    this.extra = const {},
  });

  final String userId;
  final String? nickname;
  final String? avatarUrl;
  final Map<String, dynamic> extra;
}
