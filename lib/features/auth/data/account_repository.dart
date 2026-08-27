import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';

import '../../../core/auth/source_account.dart';

/// 凭据存储的最小抽象（便于测试替身与未来后端替换）。
abstract class SecureCredentialStore {
  Future<Map<String, String>> readAll();
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// flutter_secure_storage 适配器。
class FlutterSecureCredentialStore implements SecureCredentialStore {
  FlutterSecureCredentialStore(this._storage);

  final FlutterSecureStorage _storage;

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
  })  : _secure = credentialStore,
        _accounts = accountBox;

  static const String accountBoxName = 'musaic_accounts';
  static const String _credentialPrefix = 'musaic.credential';

  final SecureCredentialStore _secure;
  final Box<String> _accounts;

  /// 按渠道缓存的凭据快照。
  /// readAll() 在 Android 上需整库解密，而网络拦截器每个请求都会读取
  /// 凭据，属于热路径；这里缓存最近一次读取结果，所有写路径负责失效。
  final Map<String, Map<String, String>> _credentialCache = {};

  /// 输入清洗：去首尾空白与内部换行（Cookie 粘贴常带换行）。
  static String sanitizeCredentialValue(String raw) =>
      raw.trim().replaceAll(RegExp(r'[\r\n\t]'), '');

  String _credentialKey(String sourceId, String fieldKey) =>
      '$_credentialPrefix.$sourceId.$fieldKey';

  /// 读取某渠道全部凭据字段；未登录返回空 Map。
  Future<Map<String, String>> readCredentials(String sourceId) async {
    final cached = _credentialCache[sourceId];
    if (cached != null) return Map<String, String>.of(cached);
    final all = await _secure.readAll();
    final prefix = '$_credentialPrefix.$sourceId.';
    final result = <String, String>{};
    for (final entry in all.entries) {
      if (entry.key.startsWith(prefix)) {
        result[entry.key.substring(prefix.length)] = entry.value;
      }
    }
    _credentialCache[sourceId] = Map<String, String>.unmodifiable(result);
    return result;
  }

  /// 保存凭据（值先做输入清洗）。同一渠道整体覆盖。
  Future<void> saveCredentials(
    String sourceId,
    Map<String, String> credentials,
  ) async {
    await deleteCredentials(sourceId);
    final stored = <String, String>{};
    for (final entry in credentials.entries) {
      final value = sanitizeCredentialValue(entry.value);
      if (value.isEmpty) continue;
      stored[entry.key] = value;
      await _secure.write(
        _credentialKey(sourceId, entry.key),
        value,
      );
    }
    _credentialCache[sourceId] = Map<String, String>.unmodifiable(stored);
  }

  /// 删除某渠道凭据。
  Future<void> deleteCredentials(String sourceId) async {
    _credentialCache.remove(sourceId);
    final all = await _secure.readAll();
    final prefix = '$_credentialPrefix.$sourceId.';
    for (final key in all.keys) {
      if (key.startsWith(prefix)) {
        await _secure.delete(key);
      }
    }
  }

  /// 读取渠道账号状态；无记录返回 loggedOut。
  SourceAccount readAccount(String sourceId) {
    final raw = _accounts.get(sourceId);
    if (raw == null) {
      return SourceAccount(
        sourceId: sourceId,
        status: AccountStatus.loggedOut,
      );
    }
    try {
      return SourceAccount.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return SourceAccount(
        sourceId: sourceId,
        status: AccountStatus.loggedOut,
      );
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
      if (key.startsWith(_credentialPrefix)) {
        await _secure.delete(key);
      }
    }
    await _accounts.clear();
  }
}
