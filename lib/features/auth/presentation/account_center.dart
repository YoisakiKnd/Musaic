import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musaic/features/auth/domain/source_account.dart';
import 'package:musaic/features/auth/application/account_notifier.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/features/auth/presentation/login_dialog.dart';

class AccountCenter extends ConsumerWidget {
  const AccountCenter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountState = ref.watch(accountNotifierProvider);
    final registry = SourceRegistry();

    return Scaffold(
      appBar: AppBar(title: const Text('账号')),
      body: ListView(
        children: registry.all.map((source) {

          final account = accountState.accounts[source.sourceId];
          return _AccountTile(
            source: source,
            account: account,
            onTap: () => _handleTap(context, ref, source),
          );
        }).toList(),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => ref
            .read(accountNotifierProvider.notifier)
            .checkAll(),
        icon: const Icon(Icons.refresh),
        label: const Text('刷新状态'),
      ),
    );
  }

  void _handleTap(
    BuildContext context,
    WidgetRef ref,
    MusicSource source,
  ) {
    final account = ref
        .read(accountNotifierProvider)
        .accounts[source.sourceId];

    if (account?.status == AccountStatus.loggedIn) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('${source.sourceName}'),
          content: Text('当前账号：${account?.profile?.nickname ?? account?.profile?.userId ?? ''}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: () {
                ref
                    .read(accountNotifierProvider.notifier)
                    .logout(source.sourceId);
                Navigator.pop(context);
              },
              child: const Text('登出'),
            ),
          ],
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (_) => LoginDialog(source: source),
      );
    }
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.source,
    required this.account,
    required this.onTap,
  });

  final MusicSource source;
  final SourceAccount? account;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: account?.profile?.avatarUrl != null
            ? NetworkImage(account!.profile!.avatarUrl!)
            : null,
        child: account?.profile?.avatarUrl == null
            ? const Icon(Icons.person)
            : null,
      ),
      title: Text(source.sourceName),
      subtitle: Text(
        account?.status == AccountStatus.loggedIn
            ? (account?.profile?.nickname ?? '已登录')
            : '未登录',
      ),
      trailing: Icon(
        account?.status == AccountStatus.loggedIn
            ? Icons.check_circle
            : Icons.login,
        color: account?.status == AccountStatus.loggedIn
            ? theme.colorScheme.primary
            : null,
      ),
      onTap: onTap,
    );
  }
}
