import 'dart:async';

import 'package:hive/hive.dart';
import 'dart:convert';

import '../../../core/model/track.dart';

/// 本地资料库仓库：喜欢 / 最近播放 / 自建歌单（Master Plan §9，本地优先）。
///
/// 三个 Hive Box，全部以 JSON 字符串存储，键为 `sourceId:trackId`。
class LibraryRepository {
  LibraryRepository({
    required Box<String> favoritesBox,
    required Box<String> historyBox,
    required Box<String> playlistsBox,
  }) : _favorites = favoritesBox,
       _history = historyBox,
       _playlists = playlistsBox;

  static const String favoritesBoxName = 'musaic_favorites';
  static const String historyBoxName = 'musaic_history';
  static const String playlistsBoxName = 'musaic_playlists';

  static const int historyCap = 200;

  /// 歌单名长度上限（迭代计划 §8.4）。
  static const int playlistNameMaxLength = 50;

  final Box<String> _favorites;
  final Box<String> _history;
  final Box<String> _playlists;

  /// 同名歌单写操作的串行链（迭代计划 §8.4 异步互斥锁）：
  /// 「读-改-写」期间其他协程不得插入，避免并发互相覆盖。
  final Map<String, Future<void>> _playlistOps = {};

  // ---------- 喜欢 ----------

  bool isFavorite(String trackKey) => _favorites.containsKey(trackKey);

  List<Track> get favorites =>
      _favorites.values.map(_decodeTrack).whereType<Track>().toList();

  /// 切换收藏状态，返回切换后的状态（true = 已收藏）。
  Future<bool> toggleFavorite(Track track) async {
    final key = track.key;
    if (_favorites.containsKey(key)) {
      await _favorites.delete(key);
      return false;
    }
    await _favorites.put(key, jsonEncode(track.toJson()));
    return true;
  }

  /// 批量导入收藏（一次 putAll，按 key 去重合并）。
  Future<void> addAllFavorites(Iterable<Track> tracks) async {
    await _favorites.putAll({
      for (final t in tracks) t.key: jsonEncode(t.toJson()),
    });
  }

  /// 清空全部收藏。
  ///
  /// 之所以放在仓库层而不是让调用方循环 [toggleFavorite]：
  /// 后者是 N 次「containsKey + delete」Hive 往返，大曲库下会阻塞
  /// 主 isolate；`clear()` 是一次批量删除（设置页「清空喜欢的音乐」）。
  Future<void> clearFavorites() => _favorites.clear();

  /// 全量歌单快照（备份导出用）。
  Map<String, List<Track>> playlistSnapshot() => {
    for (final name in playlistNames) name: playlistTracks(name),
  };

  /// 批量导入历史（一次到位后统一裁剪）。
  Future<void> bulkImportHistory(Iterable<Track> tracks) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var i = 0;
    await _history.putAll({
      for (final t in tracks)
        t.key: jsonEncode(<String, dynamic>{
          'at': now - (i++),
          'track': t.toJson(),
        }),
    });
    await _trimHistory();
  }

  Stream<BoxEvent> watchFavorites() => _favorites.watch();

  Stream<BoxEvent> watchHistory() => _history.watch();

  Stream<BoxEvent> watchPlaylists() => _playlists.watch();

  // ---------- 最近播放 ----------

  /// 记录一次播放（去重刷新时间，超上限裁剪最旧）。
  Future<void> addHistory(Track track) async {
    await _history.put(
      track.key,
      jsonEncode(<String, dynamic>{
        'at': DateTime.now().millisecondsSinceEpoch,
        'track': track.toJson(),
      }),
    );
    await _trimHistory();
  }

  /// 按最近优先返回历史记录。
  List<Track> recentHistory({int limit = 50}) {
    final entries = <(int, Track)>[];
    for (final value in _history.values) {
      try {
        final map = jsonDecode(value) as Map<String, dynamic>;
        final at = map['at'] as int;
        final track = Track.fromJson(
          Map<String, dynamic>.from(map['track'] as Map),
        );
        entries.add((at, track));
      } catch (_) {
        // 忽略损坏记录
      }
    }
    entries.sort((a, b) => b.$1.compareTo(a.$1));
    return entries.take(limit).map((e) => e.$2).toList();
  }

  Future<void> clearHistory() => _history.clear();

  /// 按曲目 key 批量删除历史记录（资料库「最近播放」的批量移除）。
  ///
  /// 之所以必须存在这个 API：历史与收藏是**两份独立数据**，
  /// 而此前「最近播放」的批量移除复用了 [toggleFavorite]，
  /// 结果删不掉历史、却悄悄改写了收藏（U1 数据正确性缺陷）。
  ///
  /// 一次 [Box.deleteAll] 批量删除，避免 N 次 Hive 往返。
  Future<void> removeHistory(Iterable<String> trackKeys) async {
    final keys = trackKeys.toList(growable: false);
    if (keys.isEmpty) return;
    await _history.deleteAll(keys);
  }

  Future<void> _trimHistory() async {
    if (_history.length <= historyCap) return;
    final dated = <(int, String)>[];
    for (final entry in _history.toMap().entries) {
      try {
        final map = jsonDecode(entry.value) as Map<String, dynamic>;
        dated.add((map['at'] as int? ?? 0, entry.key));
      } catch (_) {
        dated.add((0, entry.key));
      }
    }
    dated.sort((a, b) => a.$1.compareTo(b.$1)); // 最旧在前
    final overflow = _history.length - historyCap;
    for (var i = 0; i < overflow; i++) {
      await _history.delete(dated[i].$2);
    }
  }

  // ---------- 自建歌单 ----------

  List<String> get playlistNames {
    final names = _playlists.keys.cast<String>().toList()..sort();
    return names;
  }

  List<Track> playlistTracks(String name) {
    final raw = _playlists.get(name);
    if (raw == null) return const <Track>[];
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final tracks =
          (map['tracks'] as List<dynamic>)
              .map((t) => Track.fromJson(Map<String, dynamic>.from(t as Map)))
              .toList();
      return tracks;
    } catch (_) {
      return const <Track>[];
    }
  }

  /// 歌单名规范化：trim、空值与长度校验（迭代计划 §8.4）。
  String _normalizePlaylistName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', '歌单名不能为空');
    }
    if (trimmed.length > playlistNameMaxLength) {
      throw ArgumentError.value(
        trimmed.length,
        'name',
        '歌单名过长（≤$playlistNameMaxLength 字符）',
      );
    }
    return trimmed;
  }

  /// 同名歌单写操作串行化：先入队再执行，保证读-改-写不被并发打断。
  Future<T> _withPlaylistLock<T>(String name, Future<T> Function() action) {
    final previous = _playlistOps[name] ?? Future<void>.value();
    final current = Completer<void>();
    _playlistOps[name] = current.future;
    return previous.then((_) => action()).whenComplete(current.complete);
  }

  Future<void> createPlaylist(String rawName) {
    final name = _normalizePlaylistName(rawName);
    return _withPlaylistLock(name, () async {
      if (_playlists.containsKey(name)) return;
      await _playlists.put(
        name,
        jsonEncode(<String, dynamic>{
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'tracks': <dynamic>[],
        }),
      );
    });
  }

  Future<void> deletePlaylist(String rawName) {
    final name = _normalizePlaylistName(rawName);
    return _withPlaylistLock(name, () => _playlists.delete(name));
  }

  /// 重命名歌单（日常可用性计划 D4）。
  ///
  /// 歌单以**名字为键**（`_playlists` 的 key 就是名称），因此重命名 =
  /// 「读出内容 → 写新键 → 删旧键」。整个过程必须持锁，否则并发写会出现
  /// 「新旧两个歌单同时存在」或「改名后内容丢失」。
  ///
  /// 返回 false 表示：旧名不存在，或新名已被占用（**不覆盖**已有歌单）。
  Future<bool> renamePlaylist(String rawOldName, String rawNewName) {
    final oldName = _normalizePlaylistName(rawOldName);
    final newName = _normalizePlaylistName(rawNewName);
    if (oldName == newName) return Future<bool>.value(true);

    // 两个名字都要上锁：只锁一个会让另一端并发写进来。
    // 按字典序加锁可避免 A→B 与 B→A 同时发生时的死锁。
    final ascending = oldName.compareTo(newName) <= 0;
    final first = ascending ? oldName : newName;
    final second = ascending ? newName : oldName;

    return _withPlaylistLock(
      first,
      () => _withPlaylistLock(second, () async {
        final raw = _playlists.get(oldName);
        if (raw == null) return false;
        // 不覆盖已有歌单：撞名时保持原状，由 UI 提示用户
        if (_playlists.containsKey(newName)) return false;
        await _playlists.put(newName, raw);
        await _playlists.delete(oldName);
        return true;
      }),
    );
  }

  Future<void> addToPlaylist(String rawName, Track track) {
    final name = _normalizePlaylistName(rawName);
    return _withPlaylistLock(name, () async {
      final tracks = playlistTracks(name);
      if (tracks.any((t) => t.key == track.key)) return;
      tracks.add(track);
      await _writePlaylist(name, tracks);
    });
  }

  /// 批量加入歌单：只做一次「读-改-写」，避免逐条 N 次全表重写。
  Future<void> addManyToPlaylist(String rawName, Iterable<Track> tracks) {
    final name = _normalizePlaylistName(rawName);
    return _withPlaylistLock(name, () async {
      final existing = playlistTracks(name);
      final known = existing.map((t) => t.key).toSet();
      var changed = false;
      for (final track in tracks) {
        if (known.add(track.key)) {
          existing.add(track);
          changed = true;
        }
      }
      if (changed) await _writePlaylist(name, existing);
    });
  }

  /// 用给定曲目列表整体替换歌单内容（不存在则创建）。
  Future<void> replacePlaylistTracks(String rawName, Iterable<Track> tracks) {
    final name = _normalizePlaylistName(rawName);
    return _withPlaylistLock(name, () async {
      final existing = <Track>[];
      final known = <String>{};
      for (final track in tracks) {
        if (known.add(track.key)) existing.add(track);
      }
      await _writePlaylist(name, existing);
    });
  }

  Future<void> removeFromPlaylist(String rawName, int index) {
    final name = _normalizePlaylistName(rawName);
    return _withPlaylistLock(name, () async {
      final tracks = playlistTracks(name);
      if (index < 0 || index >= tracks.length) return;
      tracks.removeAt(index);
      await _writePlaylist(name, tracks);
    });
  }

  /// 按 [Track.key] 移除（计划 4.2）。
  ///
  /// 下标移除依赖「渲染时的顺序 == 执行时的顺序」。列表在两次操作之间
  /// 只要发生一次重排（另一处写入、响应式刷新、批量移除），下标就会指向
  /// 另一首歌——用户点的是 A，删掉的可能是 B。key 是内容标识，与顺序无关。
  ///
  /// 返回是否真的移除了：key 不存在时返回 false（幂等，不报错）。
  Future<bool> removeFromPlaylistByKey(String rawName, String trackKey) {
    final name = _normalizePlaylistName(rawName);
    return _withPlaylistLock(name, () async {
      final tracks = playlistTracks(name);
      final before = tracks.length;
      tracks.removeWhere((t) => t.key == trackKey);
      if (tracks.length == before) return false;
      await _writePlaylist(name, tracks);
      return true;
    });
  }

  /// 歌单排序（基准项「播放列表 · 排序」）。
  ///
  /// 排序结果**写回存储**而不是只在界面上排：歌单的顺序就是播放顺序
  /// （[playlistTracks] 的顺序即 `播放全部` 与队列顺序），只改视图会让
  /// 「看到的顺序」和「实际播放顺序」不一致。
  ///
  /// 返回 false 表示歌单不存在（幂等，不报错）。
  Future<bool> sortPlaylist(String rawName, PlaylistSortOrder order) {
    final comparator = order.comparator;
    // [PlaylistSortOrder.manual] 就是「存储顺序」本身，没有可执行的排序动作：
    // 排序不可逆（原始顺序不另存），因此不提供「恢复默认」入口，直接返回。
    if (comparator == null) return Future<bool>.value(false);
    final name = _normalizePlaylistName(rawName);
    return _withPlaylistLock(name, () async {
      final tracks = playlistTracks(name);
      if (tracks.length < 2) return false;
      tracks.sort(comparator);
      await _writePlaylist(name, tracks);
      return true;
    });
  }

  Future<void> _writePlaylist(String name, List<Track> tracks) {
    return _playlists.put(
      name,
      jsonEncode(<String, dynamic>{
        'createdAt':
            _playlistCreatedAt(name) ?? DateTime.now().millisecondsSinceEpoch,
        'tracks': tracks.map((t) => t.toJson()).toList(),
      }),
    );
  }

  int? _playlistCreatedAt(String name) {
    final raw = _playlists.get(name);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)['createdAt'] as int?;
    } catch (_) {
      return null;
    }
  }

  Track? _decodeTrack(String raw) {
    try {
      return Track.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  // ---------- 全库快照（备份导入事务回滚用，迭代计划 §8.6） ----------

  /// 捕获三个 Box 的原始 JSON 快照（key → 原始字符串）。
  LibrarySnapshot captureSnapshot() => LibrarySnapshot(
    favorites: Map<String, String>.from(_favorites.toMap()),
    history: Map<String, String>.from(_history.toMap()),
    playlists: Map<String, String>.from(_playlists.toMap()),
  );

  /// 整库回滚：先写回快照内容，再删除快照中不存在的键。
  ///
  /// 旧实现是「逐 Box clear() 后 putAll()」：中途崩溃/写失败会停在
  /// 「已清空但未写回」的状态，用户数据全部丢失。
  /// 改为「先写后删」——任一时刻磁盘上都保留完整可用数据，
  /// 最坏情况是残留少量多余条目，不会出现空库（P1 数据安全回归）。
  Future<void> restoreSnapshot(LibrarySnapshot snapshot) async {
    await _favorites.putAll(snapshot.favorites);
    await _history.putAll(snapshot.history);
    await _playlists.putAll(snapshot.playlists);
    await _pruneKeys(_favorites, snapshot.favorites.keys);
    await _pruneKeys(_history, snapshot.history.keys);
    await _pruneKeys(_playlists, snapshot.playlists.keys);
  }

  static Future<void> _pruneKeys(Box<String> box, Iterable<String> keep) async {
    final keepSet = keep.toSet();
    final stale = box.keys
        .map((k) => '$k')
        .where((k) => !keepSet.contains(k))
        .toList(growable: false);
    if (stale.isEmpty) return;
    await box.deleteAll(stale);
  }
}

/// 全库原始快照：收藏 / 历史 / 歌单三个 Box 的 key → 原始 JSON 值。
class LibrarySnapshot {
  const LibrarySnapshot({
    required this.favorites,
    required this.history,
    required this.playlists,
  });

  final Map<String, String> favorites;
  final Map<String, String> history;
  final Map<String, String> playlists;
}

/// 歌单排序方式（基准项「播放列表 · 排序」）。
///
/// 缺失元数据的兜底值参与排序，避免 `null` 让整次排序抛异常：
/// 时长缺失按 0 处理（排在最前），标题/艺术家缺失按空串处理。
/// 比较器都以 [Track.key] 收尾，保证**同值项的顺序稳定可复现**——
/// 否则两次排序可能得到不同结果，用户会以为排序没生效。
enum PlaylistSortOrder {
  /// 手动添加顺序（默认，即当前存储顺序）。
  manual('默认顺序', null),

  /// 按标题升序（中文按 Unicode 码点，与项目其余列表排序一致）。
  titleAsc('按标题', _compareTitle),

  /// 按艺术家升序，同艺术家内按标题。
  artistAsc('按艺术家', _compareArtist),

  /// 按时长升序，缺失时长视为 0。
  durationAsc('按时长', _compareDuration);

  const PlaylistSortOrder(this.label, this._compare);

  final String label;
  final int Function(Track a, Track b)? _compare;

  /// 排序比较器；[manual] 无比较器（调用方应保持原顺序）。
  Comparator<Track>? get comparator {
    final compare = _compare;
    if (compare == null) return null;
    return (a, b) {
      final result = compare(a, b);
      // 收尾比较 key：保证排序稳定，同值项不会在两次排序间跳动
      return result != 0 ? result : a.key.compareTo(b.key);
    };
  }

  static int _compareTitle(Track a, Track b) =>
      a.title.toLowerCase().compareTo(b.title.toLowerCase());

  static int _compareArtist(Track a, Track b) {
    final byArtist = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
    return byArtist != 0 ? byArtist : _compareTitle(a, b);
  }

  static int _compareDuration(Track a, Track b) =>
      (a.duration ?? Duration.zero).compareTo(b.duration ?? Duration.zero);
}
