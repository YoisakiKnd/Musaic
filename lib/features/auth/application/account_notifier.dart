import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/auth/auth_result.dart';
import '../../../core/auth/source_account.dart';

/// 全部渠道账号状态。
class AccountsState {
  const AccountsState({this.bySource = const <String, SourceAccount>{}});

  final Map<String, SourceAccount> bySource;

  SourceAccount of(String sourceId) =>
      bySource[sourceId] ??
      SourceAccount(
        sourceId: sourceId,
        status: AccountStatus.loggedOut,
      );

  AccountsState withAccount(SourceAccount account) {
    final next = Map<String, SourceAccount>.of(bySource);
    next[account.sourceId] = account;
    return AccountsState(bySource: next);
  }
}

/// 账号状态管理（Master Plan §6 / 账号文档生命周期）。
///
/// - 启动：乐观恢复缓存状态（<200ms），后台异步校验，失效标记「已过期」。
/// - 运行：401/301 被动捕获同样标记过期；过期不删凭据，引导重新登录。
class AccountNotifier extends Notifier<AccountsState> {
  @override
  AccountsState build() {
    final restored =
        ref.read(accountRepositoryProvider).restoreAll();
    unawaited(Future.microtask(() => _verifyAll(restored)));
    return AccountsState(bySource: restored);
  }

  /// 完成登录（二维码 / 手机密码等流程共用）：
  /// 渠道验证成功后由页面调用，凭据入安全存储、资料入 Hive、状态广播。
  Future<void> completeLogin(
    String sourceId,
    Map<String, String> credentials,
    SourceAccount account,
  ) async {
    final repository = ref.read(accountRepositoryProvider);
    await repository.saveCredentials(sourceId, credentials);
    await repository.saveAccount(account);
    state = state.withAccount(account);
  }

  /// 登录：渠道验证成功后凭据入安全存储、资料入 Hive、状态广播。
  Future<AuthResult> login(
    String sourceId,
    Map<String, String> credentials,
  ) async {
    final source =
        ref.read(sourceRegistryProvider).resolve(sourceId);
    if (source == null) {
      return const AuthFailure(
        reason: AuthFailureReason.unsupported,
        message: '渠道未注册',
      );
    }
    final result = await source.login(credentials);
    if (result is AuthSuccess) {
      final repository = ref.read(accountRepositoryProvider);
      await repository.saveCredentials(sourceId, credentials);
      await repository.saveAccount(result.account);
      state = state.withAccount(result.account);
    }
    return result;
  }

  Future<void> logout(String sourceId) async {
    final source =
        ref.read(sourceRegistryProvider).resolve(sourceId);
    try {
      await source?.logout();
    } catch (_) {
      // 渠道侧登出失败不阻塞本地清理
    }
    await ref.read(accountRepositoryProvider).logout(sourceId);
    state = state.withAccount(
      SourceAccount(sourceId: sourceId, status: AccountStatus.loggedOut),
    );
  }

  /// 刷新账号资料（昵称 / 会员状态）。
  ///
  /// 渠道不支持时返回 null；网络失败时抛出由 UI 提示。
  Future<SourceAccount?> refreshAccount(String sourceId) async {
    final account = state.of(sourceId);
    if (!account.isLoggedIn) return null;
    final source = ref.read(sourceRegistryProvider).resolve(sourceId);
    final updated = await source?.refreshAccountInfo(account);
    if (updated == null) return null;
    await ref.read(accountRepositoryProvider).saveAccount(updated);
    state = state.withAccount(updated);
    return updated;
  }

  /// 网络层被动捕获到会话过期时调用。
  void markExpiredIfLoggedIn(String sourceId) {
    if (state.of(sourceId).status != AccountStatus.loggedIn) return;
    unawaited(_markExpired(sourceId));
  }

  Future<void> _markExpired(String sourceId) async {
    final repository = ref.read(accountRepositoryProvider);
    await repository.markExpired(sourceId);
    state = state.withAccount(repository.readAccount(sourceId));
  }

  Future<void> _verifyAll(Map<String, SourceAccount> restored) async {
    for (final entry in restored.entries) {
      if (entry.value.status != AccountStatus.loggedIn) continue;
      unawaited(_verify(entry.key));
    }
  }

  /// 后台校验：无效则标记过期；网络异常保持乐观状态不打扰用户。
  Future<void> _verify(String sourceId) async {
    final source =
        ref.read(sourceRegistryProvider).resolve(sourceId);
    if (source == null) return;
    try {
      final valid =
          await source.checkSession().timeout(const Duration(seconds: 8));
      if (!valid && state.of(sourceId).status == AccountStatus.loggedIn) {
        await _markExpired(sourceId);
      }
    } on TimeoutException {
      // 校验超时：保留乐观登录态
    } catch (_) {
      // 网络异常：保留乐观登录态
    }
  }

  /// 一键清除所有账号数据。
  Future<void> clearAllAccountsData() async {
    await ref.read(accountRepositoryProvider).clearAll();
    state = const AccountsState();
  }
}

final accountsProvider =
    NotifierProvider<AccountNotifier, AccountsState>(AccountNotifier.new);

/// 单个渠道账号状态的便捷选择器。
final sourceAccountProvider = Provider.family<SourceAccount, String>(
  (ref, sourceId) => ref.watch(accountsProvider).of(sourceId),
);
