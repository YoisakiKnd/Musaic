import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/app_providers.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../application/account_notifier.dart';
import '../../domain/source_account.dart';
import 'netease_login_page.dart';

/// 账号管理（设置二级页）：各渠道状态一览，点进各渠道独立登录页。
class AccountManagePage extends ConsumerWidget {
  const AccountManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourceRegistryProvider).all;

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
        title: Text(source.displayName,
            style: const TextStyle(fontWeight: FontWeight.w600)),
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
            ? IconButton(
                tooltip: '登出',
                icon: Icon(Icons.logout_rounded,
                    size: 20,
                    color: scheme.onSurface.withValues(alpha: 0.6)),
                onPressed: () =>
                    ref.read(accountsProvider.notifier).logout(sourceId),
              )
            : const Icon(Icons.chevron_right_rounded),
        onTap: () => _openChannelLogin(context, sourceId, account),
      ),
    );
  }

  void _openChannelLogin(
    BuildContext context,
    String sourceId,
    SourceAccount account,
  ) {
    switch (sourceId) {
      case 'netease':
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const NeteaseLoginPage(),
          ),
        );
      case 'qqmusic':
        _showComingSoon(context, 'QQ 音乐', 'QQ 登录（扫码 / 账号密码）');
      case 'kugou':
        _showComingSoon(context, '酷狗音乐', '酷狗账号登录');
      case 'ytmusic':
        _showComingSoon(context, 'YouTube Music', 'Google 账号授权');
      default:
        _showComingSoon(context, sourceId, '账号登录');
    }
  }

  void _showComingSoon(BuildContext context, String channel, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$channel $feature 开发中，敬请期待')),
    );
  }
}
