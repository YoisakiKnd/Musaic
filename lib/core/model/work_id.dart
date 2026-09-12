/// 作品身份归一化（架构演进设计 §2.2）。
///
/// 目标：把不同渠道对**同一首歌**的不同写法归一到同一个 [WorkId]。
///
/// 设计原则（重要）：
/// - **只做确定性规则**，不做模糊匹配 / 编辑距离 / 拼音。把两首不同的歌
///   合并成一首，比不合并更糟——用户会听到错的曲子且无法理解原因。
///   宁可少合并，不可错合并。
/// - 任何输入都必须返回一个可用的 [WorkId]，**永不抛异常**（降级到原始键）。
/// - 归一化结果可解释：保留 [WorkId.normalizedTitle] / [normalizedArtist]
///   供排查「为什么这两首被合并了」。
library;

import 'package:meta/meta.dart';

/// 作品身份：跨渠道稳定。
@immutable
class WorkId implements Comparable<WorkId> {
  const WorkId({
    required this.normalizedTitle,
    required this.normalizedArtist,
    this.isrc,
  });

  /// 归一化后的标题（小写、去修饰、去标点）。
  final String normalizedTitle;

  /// 归一化后的艺人（多艺人已排序拼接）。
  final String normalizedArtist;

  /// 强标识：渠道提供的 ISRC。存在时优先用于判定同一性。
  final String? isrc;

  /// 同一性判定：ISRC 双方都有时以 ISRC 为准；
  /// 否则比较归一化后的「标题 + 艺人」。
  ///
  /// 注意：不能直接用 `==` 比较整个对象——`isrc` 一边有一边无时，
  /// 应当回退到标题/艺人比较，而不是判定为不同作品。
  bool matches(WorkId other) {
    if (isrc != null && other.isrc != null) {
      return isrc == other.isrc;
    }
    return normalizedTitle == other.normalizedTitle &&
        normalizedArtist == other.normalizedArtist;
  }

  /// 稳定哈希键：用于 Hive 键 / 去重 Map。
  ///
  /// 有 ISRC 时以 ISRC 为键，否则用「标题|艺人」。
  String get value =>
      isrc != null ? 'isrc:$isrc' : '$normalizedTitle|$normalizedArtist';

  @override
  int compareTo(WorkId other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is WorkId && matches(other);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'WorkId($value)';
}

/// 需要从标题中剥离的「修饰括号」内容。
///
/// 覆盖各渠道常见的版本标注差异。**只剥离明确的版本/规格标注**，
/// 不剥离可能属于标题本身的内容（如「(Live)」在部分曲目是标题一部分，
/// 但跨渠道差异主要来自它，权衡后剥离——误合并风险低于不合并的体验损失）。
final RegExp _bracketModifiers = RegExp(
  r'[\(\（\[\【]'
  r'(?:'
  r'live|live\s*ver\.?|live\s*version|'
  r'remaster(?:ed)?(?:\s*\d{4})?|'
  r'伴奏|纯音乐|和声伴奏|伴唱|'
  r'remix|rmx|'
  r'mono|stereo|'
  r'feat\.?.*|ft\.?.*|with\s+.*|'
  r'官方|高音质|无损|'
  r'deluxe(?:\s*edition)?|'
  r'radio\s*edit|single\s*version|album\s*version|'
  r'\d{4}\s*remaster'
  r')'
  r'[\)\）\]\】]',
  caseSensitive: false,
);

/// 需要从标题/艺人中整体移除的噪声词（不区分大小写）。
final RegExp _noiseWords = RegExp(
  r'\b(?:feat\.?|ft\.?|prod\.?|prod\s+by|op\.?|arranged\s+by)\b',
  caseSensitive: false,
);

/// 艺人分隔符：渠道间同一组艺人的书写顺序与分隔符不一致。
///
/// `feat.` / `ft.` / `prod.` / `with` 也视为**分隔符**而非可删除的噪声：
/// 若先当噪声删掉，`A feat. B` 会粘成 `ab`，与 `A/B` 归一化结果不一致
/// （实测踩到）。必须先切分、再逐段清洗。
final RegExp _artistSeparators = RegExp(
  r'[/、,，&＆;；]|\s+-\s+|\s+x\s+|\s+(?:feat\.?|ft\.?|prod\.?|with)\s+',
  caseSensitive: false,
);

/// 标题/艺人中需要剔除的标点与空白（归一化后再比较）。
final RegExp _punctuation = RegExp(
  r'''[\s\u3000!-\/:-@\[-`{-~''“”‘’—–…·。，、！？；：（）《》【】]''',
);

/// 归一化标题：小写、去修饰括号、去噪声词、去标点。
String normalizeWorkTitle(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';

  // 先剥离可能嵌套多层的修饰括号
  var previous = '';
  while (previous != text) {
    previous = text;
    text = text.replaceAll(_bracketModifiers, ' ');
  }

  text = text
      .replaceAll(_noiseWords, ' ')
      .toLowerCase()
      // 全角转半角（ASCII 区间）
      .replaceAllMapped(
        RegExp(r'[\uFF01-\uFF5E]'),
        (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFEE0),
      )
      .replaceAll(_punctuation, '');

  return text.trim();
}

/// 归一化艺人：切分、去重、**排序**后拼接。
///
/// 排序是关键：网易云写「周杰伦/方文山」而 QQ 写「方文山/周杰伦」时，
/// 不排序会产生两个不同的 WorkId。
String normalizeWorkArtist(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';

  final parts =
      text
          .split(_artistSeparators)
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .map((p) {
            // 注意：此处不再剥离 feat./ft.——它们已在切分阶段作为分隔符处理，
            // 此处再删会把残留片段粘连（见 _artistSeparators 注释）。
            final s = p
                .toLowerCase()
                .replaceAllMapped(
                  RegExp(r'[\uFF01-\uFF5E]'),
                  (m) =>
                      String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFEE0),
                )
                .replaceAll(_punctuation, '');
            return s.trim();
          })
          .where((p) => p.isNotEmpty)
          .toSet()
          .toList()
        ..sort();

  return parts.join('|');
}

/// 从标题与艺人构造 [WorkId]。
///
/// [isrc] 可选；[fallbackKey] 在归一化结果为空时使用（如 `netease:123`），
/// 保证任何输入都能得到可用的身份，且**永不抛异常**。
WorkId buildWorkId({
  required String title,
  required String artist,
  String? isrc,
  String? fallbackKey,
}) {
  final normalizedTitle = normalizeWorkTitle(title);
  final normalizedArtist = normalizeWorkArtist(artist);

  // 归一化失败（标题与艺人都为空）时降级到原始键，避免所有空标题曲目
  // 被错误地合并成同一个作品。
  if (normalizedTitle.isEmpty && normalizedArtist.isEmpty) {
    final key = (fallbackKey ?? '').trim();
    return WorkId(
      normalizedTitle: key.isEmpty ? '__unknown__' : key,
      normalizedArtist: '',
      isrc: _normalizeIsrc(isrc),
    );
  }

  return WorkId(
    normalizedTitle: normalizedTitle,
    normalizedArtist: normalizedArtist,
    isrc: _normalizeIsrc(isrc),
  );
}

String? _normalizeIsrc(String? raw) {
  final text = raw?.trim().toUpperCase().replaceAll('-', '') ?? '';
  return text.isEmpty ? null : text;
}
