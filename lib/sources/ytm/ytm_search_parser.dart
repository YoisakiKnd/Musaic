import '../../core/model/track.dart';

/// InnerTube 搜索结果解析（WEB_REMIX）。
///
/// 同时兼容 `tabbedSearchResultsRenderer` 与较新的
/// `twoColumnSearchResultsRenderer`；列表项可能包在
/// `musicResponsiveListItemRenderer` 里。
List<Track> extractYtmSearchTracks(
  Map<String, dynamic>? root, {
  required String sourceId,
}) {
  final results = <Track>[];
  for (final section in _searchSections(root)) {
    final shelf = _asMap(section)?['musicShelfRenderer'] ??
        _asMap(section)?['musicCardShelfRenderer'];
    final items = _asMap(shelf)?['contents'] as List<dynamic>?;
    for (final item in items ?? const <dynamic>[]) {
      final track = parseYtmListItem(_asMap(item), sourceId: sourceId);
      if (track != null) results.add(track);
    }
  }
  return results;
}

List<dynamic> _searchSections(Map<String, dynamic>? root) {
  final tabbed = _path(root, [
    'contents',
    'tabbedSearchResultsRenderer',
    'tabs',
  ]);
  if (tabbed is List && tabbed.isNotEmpty) {
    final tabContent =
        _asMap(_asMap(tabbed.first)?['tabRenderer'])?['content'];
    final sections =
        _asMap(tabContent)?['sectionListRenderer']?['contents'];
    if (sections is List) return sections;
  }
  final twoCol = _path(root, [
    'contents',
    'twoColumnSearchResultsRenderer',
    'primaryContents',
    'sectionListRenderer',
    'contents',
  ]);
  if (twoCol is List) return twoCol;
  return const <dynamic>[];
}

Track? parseYtmListItem(
  Map<String, dynamic>? item, {
  required String sourceId,
}) {
  if (item == null) return null;
  final renderer = _asMap(item['musicResponsiveListItemRenderer']) ?? item;

  final videoId = _path(renderer, ['playlistItemData', 'videoId']) as String? ??
      _path(renderer, [
        'navigationEndpoint',
        'watchEndpoint',
        'videoId',
      ]) as String?;
  if (videoId == null || videoId.isEmpty) return null;

  final flexColumns =
      renderer['flexColumns'] as List<dynamic>? ?? const <dynamic>[];
  String title = '';
  final artists = <String>[];
  String? album;
  Duration? duration;

  for (var i = 0; i < flexColumns.length; i++) {
    final runs = _path(_asMap(flexColumns[i]), [
          'musicResponsiveListItemFlexColumnRenderer',
          'text',
          'runs',
        ]) as List<dynamic>?;
    if (runs == null || runs.isEmpty) continue;
    if (i == 0) {
      title = _asMap(runs.first)?['text'] as String? ?? '';
      continue;
    }
    for (final rawRun in runs) {
      final run = _asMap(rawRun);
      final text = run?['text'] as String? ?? '';
      final watch = _path(run, ['navigationEndpoint', 'watchEndpoint']);
      final pageType = _path(run, [
        'navigationEndpoint',
        'watchEndpoint',
        'watchEndpointMusicSupportedConfigs',
        'watchEndpointMusicConfig',
        'musicVideoType',
      ]);
      if (watch != null) {
        if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') album = text;
      } else if (RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(text)) {
        duration = _parseDuration(text);
      } else if (text.trim().isNotEmpty && text != ' • ') {
        artists.add(text.trim());
      }
    }
  }
  if (title.isEmpty) return null;

  final thumbs = _path(renderer, [
        'thumbnail',
        'musicThumbnailRenderer',
        'thumbnail',
        'thumbnails',
      ]) as List<dynamic>?;
  String? coverUrl;
  if (thumbs != null && thumbs.isNotEmpty) {
    coverUrl = _asMap(thumbs.last)?['url'] as String?;
  }

  return Track(
    id: videoId,
    sourceId: sourceId,
    title: title,
    artist: artists.isEmpty ? 'Unknown Artist' : artists.join('/'),
    album: album,
    duration: duration,
    coverUrl: coverUrl,
    sourceData: <String, dynamic>{'videoId': videoId},
  );
}

Duration? _parseDuration(String text) {
  final parts = text.split(':');
  if (parts.length == 2) {
    final m = int.tryParse(parts[0]);
    final s = int.tryParse(parts[1]);
    if (m != null && s != null) return Duration(minutes: m, seconds: s);
  } else if (parts.length == 3) {
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final s = int.tryParse(parts[2]);
    if (h != null && m != null && s != null) {
      return Duration(hours: h, minutes: m, seconds: s);
    }
  }
  return null;
}

dynamic _path(Map<String, dynamic>? map, List<String> keys) {
  dynamic current = map;
  for (final key in keys) {
    if (current is! Map) return null;
    current = current[key];
  }
  return current;
}

Map<String, dynamic>? _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;
