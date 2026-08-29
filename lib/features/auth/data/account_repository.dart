import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';

import '../../../core/auth/source_account.dart';

/// 凭据存储的最小抽象（便于测试替身与未来后端替换）。
abstract class SecureCredentialStore {
  Future<String?> read(String key);
  Future<Map<String, String>> readAll();
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// flutter_secure_storage 适配器。
class FlutterSecureCredentialStore implements SecureCredentialStore {
  FlutterSecureCredentialStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 凭据与账号资料的唯一出入口（Master Plan §3.2 模块规则 4 / §9）。
///
/// - 凭据 → flutter_secure_storage（Keychain / Keystore / DPAPI），永不明文落盘。
/// - 资料 / 状态 → Hive `musaic_accounts`，启动恢复用。
/// - 所有日志与异常信息脱敏，永不包含凭据值。
class AccountRepository {
  AccountRepository({
    required SecureCredentialStore credentialStore,
    required Box<String> accountBox,
  }) : _secure = credentialStore,
       _accounts = accountBox;

  static const String accountBoxName = 'musaic_accounts';
  static const String _legacyCredentialPrefix = 'musaic.credential.';
  static const String _credentialBlobPrefix = 'musaic.credentials.';
  static const int _credentialSchemaVersion = 1;

  final SecureCredentialStore _secure;
  final Box<String> _accounts;

  /// 按渠道缓存的凭据快照。
  final Map<String, Map<String, String>> _credentialCache = {};

  /// 串行化同一渠道的凭据写入，避免读到中间态。
  final Map<String, Future<void>> _credentialWrites = {};

  /// 输入清洗：去首尾空白与内部换行（Cookie 粘贴常带换行）。
  static String sanitizeCredentialValue(String raw) =>
      raw.trim().replaceAll(RegExp(r'[\r\n\t]'), '');

  String _credentialKey(String sourceId) => '$_credentialBlobPrefix$sourceId';

  Future<T> _afterCredentialWrites<T>(
    String sourceId,
    Future<T> Function() operation,
  ) async {
    final pending = _credentialWrites[sourceId];
    if (pending != null) await pending;
    return operation();
  }

  Future<T> _enqueueCredentialWrite<T>(
    String sourceId,
    Future<T> Function() operation,
  ) {
    final previous = _credentialWrites[sourceId] ?? Future<void>.value();
    final next = previous.then((_) => operation());
    _credentialWrites[sourceId] = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  /// 读取某渠道全部凭据字段；优先读取 Blob，兼容旧版逐字段格式。
  Future<Map<String, String>> readCredentials(String sourceId) async {
    final cached = _credentialCache[sourceId];
    if (cached != null) return Map<String, String>.of(cached);
    return _afterCredentialWrites(sourceId, () async {
      final afterWait = _credentialCache[sourceId];
      if (afterWait != null) return Map<String, String>.of(afterWait);

      final blob = await _secure.read(_credentialKey(sourceId));
      if (blob != null) {
        try {
          final decoded = jsonDecode(blob) as Map<String, dynamic>;
          final rawCredentials = decoded['credentials'];
          if (decoded['version'] == _credentialSchemaVersion &&
              rawCredentials is Map) {
            final credentials = <String, String>{
              for (final entry in rawCredentials.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            };
            _credentialCache[sourceId] = Map<String, String>.unmodifiable(
              credentials,
            );
            return credentials;
          }
        } catch (_) {
          // Blob 损坏时继续尝试旧格式，避免升级后丢失可迁移凭据。
        }
      }

      final all = await _secure.readAll();
      final prefix = '$_legacyCredentialPrefix$sourceId.';
      final result = <String, String>{};
      for (final entry in all.entries) {
        if (entry.key.startsWith(prefix)) {
          result[entry.key.substring(prefix.length)] = entry.value;
        }
      }
      _credentialCache[sourceId] = Map<String, String>.unmodifiable(result);
      return result;
    });
  }

  /// 保存凭据：先完整写入 Blob，再清理旧格式，避免中途形成半套凭据。
  Future<void> saveCredentials(
    String sourceId,
    Map<String, String> credentials,
  ) async {
    await _enqueueCredentialWrite(sourceId, () async {
      final stored = <String, String>{};
      for (final entry in credentials.entries) {
        if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(entry.key)) continue;
        final value = sanitizeCredentialValue(entry.value);
        if (value.isNotEmpty) stored[entry.key] = value;
      }
      final blob = jsonEncode(<String, dynamic>{
        'version': _credentialSchemaVersion,
        'credentials': stored,
      });
      await _secure.write(_credentialKey(sourceId), blob);
      _credentialCache[sourceId] = Map<String, String>.unmodifiable(stored);
      await _deleteLegacyCredentials(sourceId);
    });
  }

  /// 删除某渠道凭据。
  Future<void> deleteCredentials(String sourceId) async {
    await _enqueueCredentialWrite(sourceId, () async {
      _credentialCache.remove(sourceId);
      await _secure.delete(_credentialKey(sourceId));
      await _deleteLegacyCredentials(sourceId);
    });
  }

  Future<void> _deleteLegacyCredentials(String sourceId) async {
    final all = await _secure.readAll();
    final prefix = '$_legacyCredentialPrefix$sourceId.';
    for (final key in all.keys) {
      if (key.startsWith(prefix)) await _secure.delete(key);
    }
  }

  /// 读取渠道账号状态；无记录返回 loggedOut。
  SourceAccount readAccount(String sourceId) {
    final raw = _accounts.get(sourceId);
    if (raw == null) {
      return SourceAccount(sourceId: sourceId, status: AccountStatus.loggedOut);
    }
    try {
      return SourceAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return SourceAccount(sourceId: sourceId, status: AccountStatus.loggedOut);
    }
  }

  /// 保存账号状态。
  Future<void> saveAccount(SourceAccount account) =>
      _accounts.put(account.sourceId, jsonEncode(account.toJson()));

  /// 启动恢复：返回所有有记录的渠道状态（乐观恢复用）。
  Map<String, SourceAccount> restoreAll() {
    final result = <String, SourceAccount>{};
    for (final String key in _accounts.keys.cast<String>()) {
      result[key] = readAccount(key);
    }
    return result;
  }

  /// 将已登录渠道标记为过期（不删凭据）。
  Future<void> markExpired(String sourceId) async {
    final current = readAccount(sourceId);
    if (current.status == AccountStatus.loggedIn) {
      await saveAccount(current.copyWith(status: AccountStatus.expired));
    }
  }

  /// 登出：删除凭据并重置状态。
  Future<void> logout(String sourceId) async {
    await deleteCredentials(sourceId);
    await saveAccount(
      SourceAccount(sourceId: sourceId, status: AccountStatus.loggedOut),
    );
  }

  /// 一键清除所有账号数据（安全清单要求）。
  Future<void> clearAll() async {
    _credentialCache.clear();
    final all = await _secure.readAll();
    for (final key in all.keys) {
      if (key.startsWith(_legacyCredentialPrefix) ||
          key.startsWith(_credentialBlobPrefix)) {
        await _secure.delete(key);
      }
    }
    await _accounts.clear();
  }
}
