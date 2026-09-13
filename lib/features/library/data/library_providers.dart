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
///
/// autoDispose 必需：列表页每行 TrackTile 都会 watch 一个 family 实例，
/// 不释放会让 200 首历史留下 200 个常驻 Provider（P1 内存回归）。
final isFavoriteProvider = Provider.autoDispose.family<bool, String>((
  ref,
  trackKey,
) {
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

/// 单个歌单的曲目内容（**响应式**，U2）。
///
/// 为什么需要它：歌单详情页原先直接调用 `repository.playlistTracks(name)`，
/// 而它 watch 的 `libraryRepositoryProvider` 是普通 `Provider`——永远不变，
/// 因此本页在别处（搜索页加入、批量加入、备份导入、移除单曲）发生变更后
/// **不会刷新**，用户看到的是过期内容，只能退出重进。
///
/// `autoDispose`：离开详情页即释放，不为每个歌单常驻一个订阅。
final playlistTracksProvider = StreamProvider.autoDispose
    .family<List<Track>, String>((ref, name) async* {
      final repository = ref.watch(libraryRepositoryProvider);
      yield repository.playlistTracks(name);
      // 歌单 Box 的任一变更都会推送；内容可能来自其它页面的写入，
      // 故此处按名重读，而不是依赖事件里的 value。
      await for (final _ in repository.watchPlaylists()) {
        yield repository.playlistTracks(name);
      }
    });

/// 网易云账号歌单（登录后可用；账号状态变化自动重取）。
