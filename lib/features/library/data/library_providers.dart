import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/model/track.dart';

/// 资料库响应式 Provider：基于 Hive Box 事件流的本地优先状态。
///
/// 注意：Hive 的 `box.watch()` 不会为空盒子发出初始事件，
/// 因此每个 Provider 都先主动 yield 一次当前值，再跟随变更。

final favoritesProvider = StreamProvider<List<Track>>((ref) async* {
  final repository = ref.watch(libraryRepositoryProvider);
  yield repository.favorites;
  await for (final _ in repository.watchFavorites()) {
    yield repository.favorites;
  }
});

/// 收藏 Box 变更信号（修订计数）：驱动 [isFavoriteProvider] 精确失效。
final favoritesRevisionProvider = StreamProvider<int>((ref) async* {
  final repository = ref.watch(libraryRepositoryProvider);
  var revision = 0;
  yield revision;
  await for (final _ in repository.watchFavorites()) {
    yield ++revision;
  }
});

/// O(1) 收藏判定（Hive containsKey），替代「watch 全列表 + 线性扫描」。
final isFavoriteProvider = Provider.family<bool, String>((ref, trackKey) {
  ref.watch(favoritesRevisionProvider);
  return ref.watch(libraryRepositoryProvider).isFavorite(trackKey);
});

final recentHistoryProvider = StreamProvider<List<Track>>((ref) async* {
  final repository = ref.watch(libraryRepositoryProvider);
  yield repository.recentHistory();
  await for (final _ in repository.watchHistory()) {
    yield repository.recentHistory();
  }
});

final playlistsProvider = StreamProvider<List<String>>((ref) async* {
  final repository = ref.watch(libraryRepositoryProvider);
  yield repository.playlistNames;
  await for (final _ in repository.watchPlaylists()) {
    yield repository.playlistNames;
  }
});

/// 网易云账号歌单（登录后可用；账号状态变化自动重取）。
