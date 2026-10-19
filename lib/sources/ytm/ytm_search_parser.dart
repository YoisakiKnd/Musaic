import '../../core/model/track.dart';
import '../../core/network/response_decoder.dart';

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
  // 续页响应：continuationContents.musicShelfContinuation.contents
  final continued = asList(
    _path(root, ['continuationContents', 'musicShelfContinuation', 'contents']),
  );
  if (continued != null) {
    for (final item in continued) {
      final track = parseYtmListItem(_asMap(item), sourceId: sourceId);
      if (track != null) results.add(track);
    }
    return results;
  }
  for (final section in _searchSections(root)) {
    final shelf =
        _asMap(section)?['musicShelfRenderer'] ??
        _asMap(section)?['musicCardShelfRenderer'];
    final items = asList(_asMap(shelf)?['contents']);
    for (final item in items ?? const <dynamic>[]) {
      final track = parseYtmListItem(_asMap(item), sourceId: sourceId);
      if (track != null) results.add(track);
    }
  }
  return results;
}

/// 搜索结果的下一页 token（首屏与续页响应两种结构）；没有下一页返回 null。
String? extractYtmContinuation(Map<String, dynamic>? root) {
  List<dynamic>? continuations = asList(
    _path(root, [
      'continuationContents',
      'musicShelfContinuation',
      'continuations',
    ]),
  );
  if (continuations == null) {
    for (final section in _searchSections(root)) {
      final shelf = _asMap(_asMap(section)?['musicShelfRenderer']);
      continuations = asList(shelf?['continuations']);
      if (continuations != null) break;
    }
  }
  if (continuations == null || continuations.isEmpty) return null;
  final token = asStringOrNull(
    _path(_asMap(continuations.first), [
      'nextContinuationData',
      'continuation',
    ]),
  );
  return token == null || token.isEmpty ? null : token;
}

List<dynamic> _searchSections(Map<String, dynamic>? root) {
  final tabbed = _path(root, [
    'contents',
    'tabbedSearchResultsRenderer',
    'tabs',
  ]);
  if (tabbed is List && tabbed.isNotEmpty) {
    final tabContent = _asMap(_asMap(tabbed.first)?['tabRenderer'])?['content'];
    final sections = _asMap(tabContent)?['sectionListRenderer']?['contents'];
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

  final videoId =
      asStringOrNull(_path(renderer, ['playlistItemData', 'videoId'])) ??
      asStringOrNull(
        _path(renderer, ['navigationEndpoint', 'watchEndpoint', 'videoId']),
      );
  if (videoId == null || videoId.isEmpty) return null;

  final flexColumns = asList(renderer['flexColumns']) ?? const <dynamic>[];
  String title = '';
  final artists = <String>[];
  String? album;
  Duration? duration;

  // 列布局（2026-10 实测，WEB_REMIX 歌曲筛选）：
  //   第 1 列：标题
  //   第 2 列：歌手(ARTIST 链接) • 专辑(ALBUM 链接) • 时长
  //   第 3 列：「播放次数：2亿」
  // 此前把第 2、3 列里所有不带 watch 链接的文字都当成歌手，得到
  // 「周杰倫/葉惠美/播放次数：2亿」——既难看，也让跨渠道作品识别失效。
  // 现在按链接的 pageType 分类，且只从第 2 列取信息。
  for (var i = 0; i < flexColumns.length && i < 2; i++) {
    final runs = asList(
      _path(_asMap(flexColumns[i]), [
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ]),
    );
    if (runs == null || runs.isEmpty) continue;
    if (i == 0) {
      title = asStringOrNull(_asMap(runs.first)?['text']) ?? '';
      continue;
    }
    // 未带链接的歌手名（少数自建频道）：只取第一个「•」分段里的纯文本
    final unlinkedFirstSegment = <String>[];
    var segment = 0;
    // 未筛选搜索时第一段是类型标签（「歌曲 • 歌手 • …」），歌手在下一段
    var artistSegment = 0;
    for (final rawRun in runs) {
      final run = _asMap(rawRun);
      final text = (asStringOrNull(run?['text']) ?? '').trim();
      if (text.isEmpty) continue;
      if (text == '•') {
        segment++;
        continue;
      }
      final pageType = _path(run, [
        'navigationEndpoint',
        'browseEndpoint',
        'browseEndpointContextSupportedConfigs',
        'browseEndpointContextMusicConfig',
        'pageType',
      ]);
      if (pageType == 'MUSIC_PAGE_TYPE_ARTIST' ||
          pageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL') {
        artists.add(text);
      } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') {
        album = text;
      } else if (RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(text)) {
        duration = _parseDuration(text);
      } else if (segment == 0 && _typeLabels.contains(text)) {
        artistSegment = 1;
      } else if (segment == artistSegment && text != '&' && text != ',') {
        unlinkedFirstSegment.add(text);
      }
    }
    if (artists.isEmpty) artists.addAll(unlinkedFirstSegment);
  }
  if (title.isEmpty) return null;

  final thumbs = asList(
    _path(renderer, [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails',
    ]),
  );
  String? coverUrl;
  if (thumbs != null && thumbs.isNotEmpty) {
    coverUrl = asStringOrNull(_asMap(thumbs.last)?['url']);
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

/// 未筛选搜索时第 2 列开头的类型标签（「歌曲 • 周杰倫 • …」），不是歌手。
const Set<String> _typeLabels = <String>{
  '歌曲',
  '视频',
  '影片',
  'Song',
  'Video',
  'Single',
  '单曲',
  'EP',
};

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

Map<String, dynamic>? _asMap(dynamic value) => asMap(value);
