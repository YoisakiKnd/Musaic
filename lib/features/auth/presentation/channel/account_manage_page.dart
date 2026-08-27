import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/source_account.dart';
import '../../../../core/di/app_providers.dart';
import '../../../../core/source/capabilities.dart';
import '../../../../core/source/music_source.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../application/account_notifier.dart';
import '../login_launcher.dart';

/// 渠道是否有值得在账号列表展示的登录能力（本地文件等免登录渠道不展示）。
bool _hasAccountUi(MusicSource source) =>
    source is QrLoginCapable ||
    source is PasswordLoginCapable ||
    source is WebLoginCapable ||
    source.authCapability.requiresLogin;

/// 账号管理（设置二级页）：各渠道状态一览，点进通用登录页。
///
/// 登录页的选择完全由渠道能力（[QrLoginCapable]/[PasswordLoginCapable]/
/// [WebLoginCapable]/[AuthCapability]）驱动，不含任何渠道 id 硬编码；
/// 新渠道注册即出现在此列表并可登录。
class AccountManagePage extends ConsumerWidget {
  const AccountManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 免登录且无账号 UI 的渠道（如本地文件，已独立到「设置 → 本地音乐」）
    // 不在账号列表展示
    final sources = ref
        .watch(sourceRegistryProvider)
        .all
        .where(_hasAccountUi)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: const Text('账号管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          for (final source in sources)
            _ChannelEntry(
              key: ValueKey('manage-${source.sourceId}'),
              sourceId: source.sourceId,
            ),
          const SizedBox(height: 16),
          Center(
            child: TextButton.icon(
              style:
                  TextButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('清除所有账号数据？'),
                    content: const Text('将删除全部渠道的登录凭据与本地资料记录。'),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            Navigator.of(dialogContext).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.redAccent),
                        onPressed: () =>
                            Navigator.of(dialogContext).pop(true),
                        child: const Text('清除'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ref
                      .read(accountsProvider.notifier)
                      .clearAllAccountsData();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('账号数据已清除')),
                  );
                }
              },
              icon: const Icon(Icons.delete_sweep_rounded, size: 20),
              label: const Text('一键清除所有账号数据'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelEntry extends ConsumerWidget {
  const _ChannelEntry({super.key, required this.sourceId});

  final String sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(sourceRegistryProvider);
    final source = registry.resolve(sourceId);
    if (source == null) return const SizedBox.shrink();

    final account = ref.watch(accountsProvider).of(sourceId);
    final scheme = Theme.of(context).colorScheme;

    final (statusLabel, statusColor) = switch (account.status) {
      AccountStatus.loggedOut =>
        ('未登录', scheme.onSurface.withValues(alpha: 0.5)),
      AccountStatus.loggedIn => (
          account.nickname ?? '已登录',
          Colors.greenAccent.withValues(alpha: 0.9),
        ),
      AccountStatus.expired => ('已过期，请重新登录', Colors.orangeAccent),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusCard - 4),
        ),
        leading: CircleAvatar(
          backgroundColor: AppTokens.accent.withValues(alpha: 0.15),
          backgroundImage: account.avatarUrl == null
              ? null
              : NetworkImage(account.avatarUrl!),
          child: account.avatarUrl == null
              ? Text(
                  source.displayName.characters.first,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTokens.accent,
                  ),
                )
              : null,
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                account.isLoggedIn && account.nickname != null
                    ? account.nickname!
                    : source.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (account.isLoggedIn && account.nickname != null) ...[
              const SizedBox(width: 6),
              Text(source.displayName,
                  style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withValues(alpha: 0.45))),
            ],
            if (account.vipLabel != null) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  gradient: AppTokens.brandGradient,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  account.vipLabel!,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration:
                  BoxDecoration(color: statusColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(statusLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.65))),
            ),
          ],
        ),
        trailing: account.isLoggedIn
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '刷新资料',
                    icon: Icon(Icons.refresh_rounded,
                        size: 20,
                        color: scheme.onSurface.withValues(alpha: 0.6)),
                    onPressed: () => _refreshAccount(context, ref, sourceId),
                  ),
                  IconButton(
                    tooltip: '退出账号',
                    icon: Icon(Icons.logout_rounded,
                        size: 20,
                        color: scheme.onSurface.withValues(alpha: 0.6)),
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: Text('退出 ${source.displayName}？'),
                          content:
                              const Text('将删除本机保存的登录凭据。'),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                  backgroundColor: AppTokens.accent),
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(true),
                              child: const Text('退出'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        await ref
                            .read(accountsProvider.notifier)
                            .logout(sourceId);
                      }
                    },
                  ),
                ],
              )
            : const Icon(Icons.chevron_right_rounded),
        onTap: () => _openChannelLogin(context, ref, source),
      ),
    );
  }

  Future<void> _refreshAccount(
    BuildContext context,
    WidgetRef ref,
    String sourceId,
  ) async {
    try {
      final updated =
          await ref.read(accountsProvider.notifier).refreshAccount(sourceId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updated == null
              ? '该渠道暂不支持刷新资料'
              : '已更新：${updated.nickname ?? ''}'
                  '${updated.vipLabel != null ? ' · ${updated.vipLabel}' : ''}'),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('刷新失败，请检查网络或重新登录')),
      );
    }
  }

  void _openChannelLogin(
    BuildContext context,
    WidgetRef ref,
    MusicSource source,
  ) {
    if (source is QrLoginCapable ||
        source is PasswordLoginCapable ||
        source is WebLoginCapable ||
        source.authCapability.requiresLogin) {
      launchChannelLogin(context, ref, source);
    } else {
      _showComingSoon(context, source.displayName, '账号登录');
    }
  }

  void _showComingSoon(BuildContext context, String channel, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$channel $feature 开发中，敬请期待')),
    );
  }
}
