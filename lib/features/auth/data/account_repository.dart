import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../domain/source_account.dart';

/// 账号存储仓库。
///
/// 凭据走安全存储，资料与状态走 Hive。
class AccountRepository {
  AccountRepository(this._secureStorage, this._hive);

  final FlutterSecureStorage _secureStorage;
  final Box<dynamic> _hive;

  static const _credentialPrefix = 'credential_';

  Future<void> saveCredential(String sourceId, Map<String, String> credentials) async {
    final key = '$_credentialPrefix$sourceId';
    await _secureStorage.write(key: key, value: jsonEncode(credentials));
  }

  Future<Map<String, String>?> readCredential(String sourceId) async {
    final key = '$_credentialPrefix$sourceId';
    final raw = await _secureStorage.read(key: key);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteCredential(String sourceId) async {
    final key = '$_credentialPrefix$sourceId';
    await _secureStorage.delete(key: key);
  }

  Future<void> saveAccount(SourceAccount account) async {
    await _hive.put(account.sourceId, _accountToMap(account));
  }

  Future<SourceAccount?> readAccount(String sourceId) async {
    final raw = _hive.get(sourceId);
    if (raw is Map) {
      return _accountFromMap(Map<String, dynamic>.from(raw));
    }
    return null;
  }

  Future<void> deleteAccount(String sourceId) async {
    await _hive.delete(sourceId);
    await deleteCredential(sourceId);
  }

  Future<void> clearAll() async {
    final keys = _hive.keys.toList();
    for (final key in keys) {
      await _hive.delete(key);
    }
    final secureKeys = await _secureStorage.readAll();
    for (final key in secureKeys.keys) {
      if (key.startsWith(_credentialPrefix)) {
        await _secureStorage.delete(key: key);
      }
    }
  }

  Map<String, dynamic> _accountToMap(SourceAccount account) => {
        'sourceId': account.sourceId,
        'status': account.status.name,
        if (account.profile != null)
          'profile': {
            'userId': account.profile!.userId,
            if (account.profile!.nickname != null) 'nickname': account.profile!.nickname,
            if (account.profile!.avatarUrl != null) 'avatarUrl': account.profile!.avatarUrl,
            'extra': account.profile!.extra,
          },
        if (account.lastCheckedAt != null)
          'lastCheckedAt': account.lastCheckedAt!.toIso8601String(),
        if (account.expiredAt != null)
          'expiredAt': account.expiredAt!.toIso8601String(),
      };

  SourceAccount _accountFromMap(Map<String, dynamic> map) => SourceAccount(
        sourceId: map['sourceId'] as String,
        status: AccountStatus.values.firstWhere(
          (e) => e.name == map['status'] as String,
          orElse: () => AccountStatus.loggedOut,
        ),
        profile: map['profile'] != null
            ? AccountProfile(
                userId: map['profile']['userId'] as String,
                nickname: map['profile']['nickname'] as String?,
                avatarUrl: map['profile']['avatarUrl'] as String?,
                extra: Map<String, dynamic>.from(map['profile']['extra'] ?? {}),
              )
            : null,
        lastCheckedAt: map['lastCheckedAt'] != null
            ? DateTime.tryParse(map['lastCheckedAt'] as String)
            : null,
        expiredAt: map['expiredAt'] != null
            ? DateTime.tryParse(map['expiredAt'] as String)
            : null,
      );
}
