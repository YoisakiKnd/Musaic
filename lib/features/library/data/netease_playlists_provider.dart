import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../sources/netease/netease_source.dart';
import '../../auth/application/account_notifier.dart';
import '../../auth/domain/source_account.dart';

/// 网易云账号歌单（登录后可用；账号状态变化自动重取）。
final neteaseUserPlaylistsProvider =
    FutureProvider<List<NeteaseUserPlaylist>>((ref) async {
  final account = ref.watch(sourceAccountProvider('netease'));
  if (account.status != AccountStatus.loggedIn) {
    return const <NeteaseUserPlaylist>[];
  }
  final source = ref.watch(sourceRegistryProvider).resolve('netease')
      as NeteaseSource?;
  if (source == null) return const <NeteaseUserPlaylist>[];
  return source.fetchUserPlaylists(account.userId ?? '');
});
