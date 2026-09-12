/// 分享链接 / 裸 ID 解析（日常可用性计划 D1）。
///
/// 背景：搜索框提示写的是「搜索 / 链接 / ID」（`search_page.dart`），
/// 但此前**没有任何解析实现**——用户粘贴一条分享链接会被当成关键字
/// 原样搜索，得到空结果。这是 UI 文案对用户的虚假承诺。
///
/// 本模块是纯函数，不依赖 Widget / 网络，便于完整单测。
///
/// ## 设计原则
///
/// - **只在确有把握时判定**：宁可把无法识别的输入交回普通搜索，
///   也不要把用户的关键字误判成链接（误判会让搜索直接失败）。
/// - 因此所有规则都要求**明确的渠道域名或 scheme**，不做模糊猜测。
/// - 解析失败返回 null，调用方回退为普通搜索。
library;

import 'package:meta/meta.dart';

/// 解析结果：渠道 id + 该渠道内的曲目 id。
@immutable
class TrackLink {
  const TrackLink({required this.sourceId, required this.id});

  /// 渠道 id（与 `MusicSource.sourceId` 一致）。
  final String sourceId;

  /// 渠道内的曲目标识。
  final String id;

  @override
  bool operator ==(Object other) =>
      other is TrackLink && other.sourceId == sourceId && other.id == id;

  @override
  int get hashCode => Object.hash(sourceId, id);

  @override
  String toString() => 'TrackLink($sourceId:$id)';
}

/// YouTube Music 渠道 id。
///
/// **必须与 `YouTubeMusicSource.id` 一致**：渠道注册用的是 `ytmusic`。
/// 这里不 import 渠道实现（架构守护测试禁止 core 依赖 sources），
/// 因此以常量形式声明，并由 `test/core/di/app_providers_test.dart`
/// 断言它与真实注册的渠道 id 相同——避免再次出现「解析出的 id 找不到渠道」。
const String youtubeMusicSourceId = 'ytmusic';

/// 各渠道的已知域名（用于判定，而非用于猜测）。
const List<String> _neteaseHosts = <String>[
  'music.163.com',
  'y.music.163.com',
  '163.com',
];

const List<String> _qqHosts = <String>[
  'y.qq.com',
  'c.y.qq.com',
  'i.y.qq.com',
  'qq.com',
];

const List<String> _kugouHosts = <String>[
  'kugou.com',
  'www.kugou.com',
  'm.kugou.com',
  't1.kugou.com',
];

const List<String> _ytmHosts = <String>[
  'music.youtube.com',
  'youtube.com',
  'youtu.be',
  'www.youtube.com',
];

/// 网易云曲目 id：纯数字。
final RegExp _neteaseIdPattern = RegExp(r'^\d{1,15}$');

/// QQ songmid：14 位左右字母数字混合（如 `0039MnYb0qxYhV`）。
final RegExp _qqMidPattern = RegExp(r'^[A-Za-z0-9]{10,20}$');

/// YouTube videoId：11 位。
final RegExp _ytmVideoPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// 酷狗 hash：32 位十六进制。
final RegExp _kugouHashPattern = RegExp(r'^[A-Fa-f0-9]{32}$');

/// 解析用户输入为 [TrackLink]；无法识别时返回 null。
///
/// 支持：
/// - 完整分享链接（四渠道各自主流形态，含带 `#` 片段与多余 query 的）
/// - 裸 id（配合 [sourceHint] 使用；无 hint 时按各渠道 id 形态推断）
TrackLink? parseTrackLink(String raw, {String? sourceHint}) {
  final input = raw.trim();
  if (input.isEmpty) return null;

  // 1) 形如 `netease:347230` / `qqmusic:0039MnYb0qxYhV` 的显式前缀
  final prefixed = RegExp(r'^([a-z]+):(.+)$').firstMatch(input);
  if (prefixed != null) {
    final sourceId = prefixed.group(1)!.toLowerCase();
    final id = prefixed.group(2)!.trim();
    if (_isKnownSource(sourceId) && _looksLikeIdFor(sourceId, id)) {
      return TrackLink(sourceId: sourceId, id: id);
    }
  }

  // 2) 完整 URL
  final uri = Uri.tryParse(input);
  if (uri != null && uri.host.isNotEmpty) {
    final fromUrl = _parseUrl(uri);
    if (fromUrl != null) return fromUrl;
  }

  // 3) 裸 id + 渠道提示（UI 上用户显式选了「按某渠道解析」）
  if (sourceHint != null && _looksLikeIdFor(sourceHint, input)) {
    return TrackLink(sourceId: sourceHint, id: input);
  }

  // 4) 无提示的裸 id：仅在**形态唯一**时推断。
  //
  // 网易云（纯数字）与酷狗（32 位 hex）互不冲突，可以安全推断；
  // QQ mid 与 YTM videoId 都是字母数字混合且长度区间重叠，
  // **无法可靠区分**，故不推断——交回普通搜索。
  if (_neteaseIdPattern.hasMatch(input)) {
    return TrackLink(sourceId: 'netease', id: input);
  }
  if (_kugouHashPattern.hasMatch(input)) {
    return TrackLink(sourceId: 'kugou', id: input);
  }

  return null;
}

TrackLink? _parseUrl(Uri uri) {
  final host = uri.host.toLowerCase();

  // ---- YouTube Music / YouTube ----
  if (_hostMatches(host, _ytmHosts)) {
    // music.youtube.com/watch?v=ID
    final v = uri.queryParameters['v'];
    if (v != null && _ytmVideoPattern.hasMatch(v)) {
      return TrackLink(sourceId: youtubeMusicSourceId, id: v);
    }
    // youtu.be/ID
    if (host == 'youtu.be') {
      final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      if (_ytmVideoPattern.hasMatch(id)) {
        return TrackLink(sourceId: youtubeMusicSourceId, id: id);
      }
    }
    // youtube.com/shorts/ID 或 /embed/ID
    final segments = uri.pathSegments;
    for (var i = 0; i < segments.length - 1; i++) {
      if (segments[i] == 'shorts' || segments[i] == 'embed') {
        final id = segments[i + 1];
        if (_ytmVideoPattern.hasMatch(id)) {
          return TrackLink(sourceId: youtubeMusicSourceId, id: id);
        }
      }
    }
    return null;
  }

  // ---- 网易云 ----
  if (_hostMatches(host, _neteaseHosts)) {
    // /song?id=347230 或 /song/347230 或 #/song?id=347230
    final id = uri.queryParameters['id'];
    if (id != null && _neteaseIdPattern.hasMatch(id)) {
      return TrackLink(sourceId: 'netease', id: id);
    }
    final fromPath = _idAfterSegment(uri, 'song', _neteaseIdPattern);
    if (fromPath != null) return TrackLink(sourceId: 'netease', id: fromPath);
    // 片段形如 `#/song?id=123`（路径 + query）或 `#id=123`
    final fragmentLink = _parseFragment(uri, 'id', _neteaseIdPattern);
    if (fragmentLink != null) {
      return TrackLink(sourceId: 'netease', id: fragmentLink);
    }
    return null;
  }

  // ---- QQ 音乐 ----
  if (_hostMatches(host, _qqHosts)) {
    // /n/ryqq/songDetail/0039MnYb0qxYhV 或 songmid= 参数
    final mid = uri.queryParameters['songmid'] ?? uri.queryParameters['mid'];
    if (mid != null && _qqMidPattern.hasMatch(mid)) {
      return TrackLink(sourceId: 'qqmusic', id: mid);
    }
    final fromPath = _idAfterSegment(uri, 'songDetail', _qqMidPattern);
    if (fromPath != null) {
      return TrackLink(sourceId: 'qqmusic', id: fromPath);
    }
    return null;
  }

  // ---- 酷狗 ----
  if (_hostMatches(host, _kugouHosts)) {
    // 主流形态是 `#hash=xxx`（片段），也有 ?hash=
    final hash = uri.queryParameters['hash'];
    if (hash != null && _kugouHashPattern.hasMatch(hash)) {
      return TrackLink(sourceId: 'kugou', id: hash.toLowerCase());
    }
    final fromFragment = _parseFragment(uri, 'hash', _kugouHashPattern);
    if (fromFragment != null) {
      return TrackLink(sourceId: 'kugou', id: fromFragment.toLowerCase());
    }
    // /song/#hash=xxx 的片段本身是 query 形态
    final frag = uri.fragment;
    if (frag.isNotEmpty) {
      final inner = Uri.tryParse(
        '?${frag.replaceFirst(RegExp(r'^[/?#]*'), '')}',
      );
      final innerHash = inner?.queryParameters['hash'];
      if (innerHash != null && _kugouHashPattern.hasMatch(innerHash)) {
        return TrackLink(sourceId: 'kugou', id: innerHash.toLowerCase());
      }
    }
    return null;
  }

  return null;
}

/// 取 `/<segment>/<id>` 形态中的 id。
String? _idAfterSegment(Uri uri, String segment, RegExp pattern) {
  final segments = uri.pathSegments;
  for (var i = 0; i < segments.length - 1; i++) {
    if (segments[i] == segment) {
      final candidate = segments[i + 1];
      if (pattern.hasMatch(candidate)) return candidate;
    }
  }
  return null;
}

/// 在 URL 片段（`#...`）里找 `key=value`。
///
/// 片段有几种形态需要兼容：
/// - `#id=123`（纯 query）
/// - `#/song?id=123`（路径 + query，网易云 hash 路由的实际形态）
/// - `#/song/123`
String? _parseFragment(Uri uri, String key, RegExp pattern) {
  final frag = uri.fragment;
  if (frag.isEmpty) return null;

  // 先按「路径?query」切分，取 query 部分
  final queryStart = frag.indexOf('?');
  final queryPart = queryStart >= 0 ? frag.substring(queryStart + 1) : frag;
  final inner = Uri.tryParse('?$queryPart');
  final value = inner?.queryParameters[key];
  if (value != null && pattern.hasMatch(value)) return value;

  // 再尝试「路径末段即 id」（#/song/123）
  if (queryStart < 0) {
    final segments = frag.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty && pattern.hasMatch(segments.last)) {
      return segments.last;
    }
  }
  return null;
}

bool _hostMatches(String host, List<String> candidates) {
  for (final candidate in candidates) {
    if (host == candidate || host.endsWith('.$candidate')) return true;
  }
  return false;
}

bool _isKnownSource(String sourceId) => <String>{
  'netease',
  'qqmusic',
  'kugou',
  youtubeMusicSourceId,
  'local',
}.contains(sourceId);

bool _looksLikeIdFor(String sourceId, String id) {
  if (id.isEmpty) return false;
  return switch (sourceId) {
    'netease' => _neteaseIdPattern.hasMatch(id),
    'qqmusic' => _qqMidPattern.hasMatch(id),
    'kugou' => _kugouHashPattern.hasMatch(id),
    youtubeMusicSourceId => _ytmVideoPattern.hasMatch(id),
    // 本地路径不做形态校验（可以是任意路径）
    'local' => true,
    _ => false,
  };
}
