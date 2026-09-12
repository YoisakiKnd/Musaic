/// 按作品身份对曲目分组，为跨渠道换源提供候选（日常可用性计划 D7）。
///
/// 设计文档 §2.3 的取巧之处：换源候选**不需要额外请求**——
/// 搜索结果里同一首歌往往已经同时带着多个渠道的记录，
/// 只要用 [WorkId] 把它们认出来即可。
///
/// 本模块是纯函数，便于单测；渠道接入与播放器逻辑不在此处。
library;

import 'track.dart';
import 'work_id.dart';

/// 为每个曲目 key 找出「同一作品在其它渠道的记录」。
///
/// 返回 Map 只包含**确实存在替代版本**的曲目；单渠道曲目不出现在结果里
/// （避免播放器为无意义的条目做查表）。
///
/// 结果中的替代列表**不包含曲目自身**，且保持传入顺序
/// （调用方据此决定优先级，例如把当前渠道排在最前）。
Map<String, List<Track>> buildAlternatives(List<Track> tracks) {
  if (tracks.length < 2) return const <String, List<Track>>{};

  // 1) 先按 WorkId 聚合
  final byWork = <String, List<Track>>{};
  final workOf = <String, WorkId>{};
  for (final track in tracks) {
    final id = buildWorkId(
      title: track.title,
      artist: track.artist,
      fallbackKey: track.key,
    );
    workOf[track.key] = id;
    byWork.putIfAbsent(id.value, () => <Track>[]).add(track);
  }

  // 2) 只为「一个作品有多条记录」的曲目建替代列表
  final result = <String, List<Track>>{};
  for (final track in tracks) {
    final id = workOf[track.key];
    if (id == null) continue;
    final group = byWork[id.value];
    if (group == null || group.length < 2) continue;

    // 同渠道同 id 的重复项也要排除（搜索结果里可能重复出现）
    final alternatives = group
        .where((t) => t.key != track.key)
        .toList(growable: false);
    if (alternatives.isEmpty) continue;

    result[track.key] = alternatives;
  }
  return result;
}

/// 从替代列表中挑选回退顺序。
///
/// 规则：
/// - 排除 [failedSourceId]（刚失败的那个渠道，避免原地重试）；
/// - 优先非本地文件（本地文件通常不在搜索结果里，但防御性排除，
///   避免「在线曲目失败后回退到某个本地同名文件」的怪异体验）；
/// - 其余保持传入顺序（搜索结果的渠道顺序即用户偏好顺序）。
List<Track> orderFallbackCandidates({
  required List<Track> alternatives,
  required String failedSourceId,
}) {
  final usable = alternatives
      .where((t) => t.sourceId != failedSourceId)
      .toList(growable: false);
  final online = usable.where((t) => t.sourceId != 'local').toList();
  // 若全是本地文件，仍允许回退（总比直接报错好）
  return online.isNotEmpty ? online : usable;
}
