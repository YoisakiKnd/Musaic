import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/account_notifier.dart';
import '../domain/source_account.dart';
import 'login_dialog.dart';

/// 渠道账号卡片列表（设置页「账号」区块复用）。
class SourceAccountList extends ConsumerWidget {
  const SourceAccountList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourceRegistryProvider).all;

    return Column(
      children: [
        for (final source in sources)
          _SourceAccountTile(
            key: ValueKey('account-${source.sourceId}'),
            sourceId: source.sourceId,
          ),
      ],
    );
  }
}

class _SourceAccountTile extends ConsumerWidget {
  const _SourceAccountTile({super.key, required this.sourceId});

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
                onPressed: () => ref
                    .read(accountsProvider.notifier)
                    .logout(sourceId),
              )
            : null,
        onTap: () {
          if (source.authCapability.requiresLogin) {
            showLoginDialog(context, source);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${source.displayName} 无需登录')),
            );
          }
        },
      ),
    );
  }
}
