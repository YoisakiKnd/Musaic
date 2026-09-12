/// YouTube Music 歌词解析（InnerTube `next` / `player` 响应 → 原始 LRC 文本）。
///
/// YTM 不提供官方 LRC 接口，但 timedtext 有两种可得形态：
/// 1. `player` 响应 `captions.playerCaptionsTracklistRenderer.captionTracks[]`
///    给出 `baseUrl`，直接 GET 可拿到 `<transcript><text start=".." dur="..">`
///    XML（部分曲目为 srv3 XML，需转 LRC）；
/// 2. `next` 响应 `engagementPanels[].lyrics` 里的
///    `timedLyricsModel.lyricsData` 直接是带时间戳的文本。
///
/// 本模块只做纯解析，网络请求留在渠道实现里，便于 fixture 单测。
library;

import 'dart:convert';

import '../../core/network/response_decoder.dart';

/// 从 `player` 响应提取歌词轨道的 baseUrl（第一个非空者）。
///
/// 带 `&fmt=srv3` 时返回 srv3 XML；不带则为经典 `<transcript>` XML。
String? extractCaptionTrackUrl(Map<String, dynamic>? root) {
  final renderer = asMap(
    asMap(root?['captions'])?['playerCaptionsTracklistRenderer'],
  );
  final tracks = asList(renderer?['captionTracks']);
  if (tracks == null) return null;
  for (final raw in tracks) {
    final url = asStringOrNull(asMap(raw)?['baseUrl']);
    if (url != null && url.isNotEmpty) return url;
  }
  return null;
}

/// 从 `next` 响应提取 `timedLyricsModel.lyricsData` 文本（可能为空）。
String? extractTimedLyricsText(Map<String, dynamic>? root) {
  final panels = asList(root?['engagementPanels']);
  if (panels == null) return null;
  for (final raw in panels) {
    final panel = asMap(raw);
    // 结构在不同客户端版本下略有差异，逐层宽松探测。
    final data =
        asStringOrNull(
          asMap(panel?['lyrics'])?['timedLyricsModel']?['lyricsData'],
        ) ??
        asStringOrNull(
          asMap(panel?['musicDescriptionShelfRenderer'])?['description'],
        ) ??
        asStringOrNull(
          asMap(
            asMap(panel?['engagementPanelSectionListRenderer'])?['content'],
          )?['timedLyricsModel']?['lyricsData'],
        );
    if (data != null && data.trim().isNotEmpty) return data;
  }
  return null;
}

/// 把 YouTube timedtext XML 转成 LRC 文本。
///
/// 支持两种形态：
/// - `<transcript><text start="1.23" dur="4.5">行</text>...</transcript>`
/// - srv3：`<timedtext><body><p t="1230" d="4500"><s>词</s>...</p></body></timedtext>`
///
/// 解析失败返回 null（由调用方回退到无歌词）。
String? timedTextXmlToLrc(String xml) {
  final text = xml.trim();
  if (text.isEmpty) return null;

  final buffer = StringBuffer();
  var count = 0;

  // 形态 1：经典 transcript
  final classic = RegExp(
    r'<text[^>]*\bstart="([0-9.]+)"[^>]*\bdur="([0-9.]+)"[^>]*>(.*?)</text>',
    dotAll: true,
  );
  for (final match in classic.allMatches(text)) {
    final start = double.tryParse(match.group(1) ?? '');
    if (start == null) continue;
    final content = _unescapeXml(_stripTags(match.group(3) ?? ''));
    if (content.trim().isEmpty) continue;
    buffer.writeln('${_lrcTimestamp(start)}$content');
    count++;
  }
  if (count > 0) return buffer.toString();

  // 形态 2：srv3（毫秒 + 内嵌 <s> 分段）
  final srv3 = RegExp(r'<p\b[^>]*\bt="(\d+)"[^>]*>(.*?)</p>', dotAll: true);
  for (final match in srv3.allMatches(text)) {
    final ms = int.tryParse(match.group(1) ?? '');
    if (ms == null) continue;
    final content = _unescapeXml(_stripTags(match.group(2) ?? ''));
    if (content.trim().isEmpty) continue;
    buffer.writeln('${_lrcTimestamp(ms / 1000)}$content');
    count++;
  }
  if (count > 0) return buffer.toString();

  // 形态 3：JSON 的 events（部分客户端返回 json3）
  if (text.startsWith('{')) {
    try {
      final decoded = asMap(jsonDecode(text));
      final events = asList(decoded?['events']);
      if (events != null) {
        for (final raw in events) {
          final event = asMap(raw);
          final startMs = asIntOrNull(event?['tStartMs']);
          final segs = asList(event?['segs']);
          if (startMs == null || segs == null) continue;
          final content =
              segs
                  .map((s) => asStringOrNull(asMap(s)?['utf8']) ?? '')
                  .join()
                  .replaceAll('\n', ' ')
                  .trim();
          if (content.isEmpty) continue;
          buffer.writeln('${_lrcTimestamp(startMs / 1000)}$content');
          count++;
        }
      }
    } catch (_) {
      return null;
    }
  }

  return count > 0 ? buffer.toString() : null;
}

/// 秒 → LRC 时间戳 `[mm:ss.xx]`。
String _lrcTimestamp(double seconds) {
  if (seconds < 0) seconds = 0;
  final total = (seconds * 100).round();
  final centis = total % 100;
  final totalSeconds = total ~/ 100;
  final s = totalSeconds % 60;
  final m = totalSeconds ~/ 60;
  return '[${m.toString().padLeft(2, '0')}:'
      '${s.toString().padLeft(2, '0')}.'
      '${centis.toString().padLeft(2, '0')}]';
}

String _stripTags(String input) => input.replaceAll(RegExp(r'<[^>]*>'), '');

String _unescapeXml(String input) => input
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&nbsp;', ' ');
