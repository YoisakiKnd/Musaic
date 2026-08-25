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
  })  : _favorites = favoritesBox,
        _history = historyBox,
        _playlists = playlistsBox;

  static const String favoritesBoxName = 'musaic_favorites';
  static const String historyBoxName = 'musaic_history';
  static const String playlistsBoxName = 'musaic_playlists';

  static const int historyCap = 200;

  final Box<String> _favorites;
  final Box<String> _history;
  final Box<String> _playlists;

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
        final track =
            Track.fromJson(Map<String, dynamic>.from(map['track'] as Map));
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
      final tracks = (map['tracks'] as List<dynamic>)
          .map((t) =>
              Track.fromJson(Map<String, dynamic>.from(t as Map)))
          .toList();
      return tracks;
    } catch (_) {
      return const <Track>[];
    }
  }

  Future<void> createPlaylist(String name) async {
    assert(name.trim().isNotEmpty, '歌单名不能为空');
    if (_playlists.containsKey(name)) return;
    await _playlists.put(
      name,
      jsonEncode(<String, dynamic>{
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'tracks': <dynamic>[],
      }),
    );
  }

  Future<void> deletePlaylist(String name) => _playlists.delete(name);

  Future<void> addToPlaylist(String name, Track track) async {
    final tracks = playlistTracks(name);
    if (tracks.any((t) => t.key == track.key)) return;
    tracks.add(track);
    await _writePlaylist(name, tracks);
  }

  Future<void> removeFromPlaylist(String name, int index) async {
    final tracks = playlistTracks(name);
    if (index < 0 || index >= tracks.length) return;
    tracks.removeAt(index);
    await _writePlaylist(name, tracks);
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
}
