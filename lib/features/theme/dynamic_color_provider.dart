import 'dart:io' show File;
import 'dart:ui' show Color;

import 'package:flutter/painting.dart'
    show FileImage, HSLColor, ImageProvider, NetworkImage, ResizeImage;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../core/utils/cover_network.dart';

/// 封面取色结果（Master Plan §8：封面取色动态渐变背景）。
///
/// 颜色已调整到适合深色背景的可读区间；取色失败时字段为 null，
/// UI 回退到品牌渐变。
class CoverPalette {
  const CoverPalette({this.primary, this.secondary});

  final Color? primary;
  final Color? secondary;

  bool get isEmpty => primary == null && secondary == null;
}

/// 按封面 URL 取色。family 天然缓存同封面的结果；
/// 切歌时 PlayerPage 对背景做 450ms 渐变过渡。
final coverPaletteProvider = FutureProvider.family<CoverPalette, String>((
  ref,
  coverUrl,
) async {
  if (coverUrl.isEmpty) return const CoverPalette();

  final ImageProvider provider;
  if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://')) {
    provider = NetworkImage(
      normalizeCoverUrl(coverUrl),
      headers: coverHttpHeaders(coverUrl),
    );
  } else if (coverUrl.startsWith('file://')) {
    provider = FileImage(File(Uri.parse(coverUrl).toFilePath()));
  } else if (!coverUrl.contains('://')) {
    // 裸绝对路径（部分渠道实现直接返回文件路径）
    provider = FileImage(File(coverUrl));
  } else {
    return const CoverPalette(); // 其他 scheme 暂不支持
  }

  try {
    final palette = await PaletteGenerator.fromImageProvider(
      ResizeImage(provider, width: 64, height: 64),
      maximumColorCount: 12,
    );
    Color? pick(PaletteColor? c) => c == null ? null : _readableOnDark(c.color);
    final primary = pick(palette.dominantColor) ?? pick(palette.vibrantColor);
    final secondary =
        pick(palette.mutedColor) ??
        (palette.colors.length > 1
            ? _readableOnDark(palette.colors.elementAt(1))
            : null);
    if (primary == null && secondary == null) {
      return const CoverPalette();
    }
    return CoverPalette(primary: primary, secondary: secondary);
  } catch (_) {
    return const CoverPalette();
  }
});

/// 将颜色调整到深色背景上可读的亮度/饱和度区间。
Color _readableOnDark(Color color) {
  final hsl = HSLColor.fromColor(color);
  final lightness = hsl.lightness.clamp(0.42, 0.72);
  final saturation =
      hsl.saturation < 0.25 ? 0.35 : hsl.saturation.clamp(0.0, 0.85);
  return hsl.withLightness(lightness).withSaturation(saturation).toColor();
}

/// 渐变端点兜底色（无封面时使用品牌红）。
const Color kFallbackGradientStart = Color(0xFF5A1622);
const Color kFallbackGradientEnd = Color(0xFFB32036);
