import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:musaic/features/auth/domain/source_account.dart';
import 'package:musaic/features/auth/data/account_repository.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';

/// 账号操作状态。
enum AccountAction { idle, loading, success, failure }

/// 账号状态。
class AccountState {
  const AccountState({
    required this.accounts,
    required this.action,
    this.activeSourceId,
    this.errorMessage,
  });

  factory AccountState.initial() => AccountState(
        accounts: const {},
        action: AccountAction.idle,
      );

  final Map<String, SourceAccount> accounts;
  final AccountAction action;
  final String? activeSourceId;
  final String? errorMessage;

  AccountState copyWith({
    Map<String, SourceAccount>? accounts,
    AccountAction? action,
    String? activeSourceId,
    String? errorMessage,
  }) {
    return AccountState(
      accounts: accounts ?? this.accounts,
      action: action ?? this.action,
      activeSourceId: activeSourceId ?? this.activeSourceId,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// 账号状态管理器。
class AccountNotifier extends Notifier<AccountState> {
  AccountNotifier([SourceRegistry? registry]) : _registry = registry ?? SourceRegistry();

  final SourceRegistry _registry;

  @override
  @override
  AccountState build() {
    _restore();
    return AccountState.initial();
  }

  AccountRepository get _repository =>
      AccountRepository(const FlutterSecureStorage(), Hive.box('default'));

  Future<void> _restore() async {
    final accounts = <String, SourceAccount>{};
    for (final source in _registry.all) {
      final account = await _repository.readAccount(source.sourceId);
      if (account != null) {
        accounts[source.sourceId] = account;
      }
    }
    state = state.copyWith(accounts: accounts);
  }

  Future<void> login(String sourceId, Map<String, String> credentials) async {
    final source = _registry.resolve(sourceId);
    if (source == null) return;

    state = state.copyWith(action: AccountAction.loading);

    try {
      await source.login(credentials);
      final profile = source is MusicSourceWithProfile
          ? await source.getProfile()
          : null;

      final account = SourceAccount(
        sourceId: sourceId,
        status: AccountStatus.loggedIn,
        profile: profile,
        lastCheckedAt: DateTime.now(),
      );

      await _repository.saveAccount(account);
      final accounts = Map<String, SourceAccount>.from(state.accounts);
      accounts[sourceId] = account;
      state = state.copyWith(
        accounts: accounts,
        action: AccountAction.success,
        activeSourceId: sourceId,
        errorMessage: null,
      );
    } catch (e) {
      state = state.copyWith(
        action: AccountAction.failure,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> logout(String sourceId) async {
    final source = _registry.resolve(sourceId);
    await source?.logout();
    await _repository.deleteAccount(sourceId);
    final accounts = Map<String, SourceAccount>.from(state.accounts);
    accounts[sourceId] = SourceAccount(
      sourceId: sourceId,
      status: AccountStatus.loggedOut,
    );
    state = state.copyWith(accounts: accounts);
  }

  Future<void> checkAll() async {
    final accounts = Map<String, SourceAccount>.from(state.accounts);
    for (final entry in accounts.entries) {
      final source = _registry.resolve(entry.key);
      if (source == null) continue;
      final valid = await source.checkSession();
      accounts[entry.key] = entry.value.copyWith(
        status: valid ? AccountStatus.loggedIn : AccountStatus.expired,
        lastCheckedAt: DateTime.now(),
        expiredAt: valid ? null : DateTime.now(),
      );
    }
    for (final source in _registry.all) {
      if (!accounts.containsKey(source.sourceId)) {
        final valid = await source.checkSession();
        accounts[source.sourceId] = SourceAccount(
          sourceId: source.sourceId,
          status: valid ? AccountStatus.loggedIn : AccountStatus.loggedOut,
          lastCheckedAt: DateTime.now(),
        );
      }
    }
    await _repository.saveAccount(accounts.values.first);
    state = state.copyWith(accounts: accounts);
  }

  void clearError() {
    state = state.copyWith(action: AccountAction.idle, errorMessage: null);
  }
}

/// 带用户资料查询能力的渠道扩展。
abstract class MusicSourceWithProfile extends MusicSource {
  MusicSourceWithProfile();

  Future<AccountProfile?> getProfile();
}

/// accountNotifierProvider
final accountNotifierProvider =
    NotifierProvider<AccountNotifier, AccountState>(AccountNotifier.new);

