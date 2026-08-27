import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/source_account.dart';
import '../../../core/di/app_providers.dart';
import '../../../core/model/remote_playlist.dart';
import '../../../core/source/capabilities.dart';
import '../../auth/application/account_notifier.dart';

/// 指定渠道的账号歌单（渠道需实现 [RemotePlaylistCapable]）。
///
/// 未登录 / 渠道不支持时返回空列表；账号状态变化自动重取。
final remotePlaylistsProvider =
    FutureProvider.family<List<RemotePlaylist>, String>((ref, sourceId) async {
  final account = ref.watch(sourceAccountProvider(sourceId));
  if (account.status != AccountStatus.loggedIn) {
    return const <RemotePlaylist>[];
  }
  final source = ref.watch(sourceRegistryProvider).resolve(sourceId);
  final capable = source is RemotePlaylistCapable
      ? source as RemotePlaylistCapable
      : null;
  if (capable == null) return const <RemotePlaylist>[];
  return capable.fetchRemotePlaylists(account.userId ?? '');
});
