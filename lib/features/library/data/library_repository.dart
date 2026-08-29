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

  /// 整库回滚：清空后按快照原样写回。
  ///
  /// 快照在导入前已完整载入内存，写回阶段不再读取外部数据，
  /// 失败时本地数据要么是导入前状态、要么是完整导入结果。
  Future<void> restoreSnapshot(LibrarySnapshot snapshot) async {
    await _favorites.clear();
    await _favorites.putAll(snapshot.favorites);
    await _history.clear();
    await _history.putAll(snapshot.history);
    await _playlists.clear();
    await _playlists.putAll(snapshot.playlists);
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
