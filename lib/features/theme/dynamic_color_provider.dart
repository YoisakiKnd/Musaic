import 'package:flutter/material.dart';
import 'package:palette_generator_master/palette_generator_master.dart';

/// 从图片生成动态调色板。
class DynamicColorProvider {
  DynamicColorProvider._();

  static Future<Color?> dominantColorFromImage(ImageProvider provider) async {
    try {
      final palette = await PaletteGeneratorMaster.fromImageProvider(
        provider,
        maximumColorCount: 16,
        size: const Size(112, 112),
      );
      return palette.dominantColor?.color;
    } catch (_) {
      return null;
    }
  }

  static Color blend(Color? source, Color fallback) {
    if (source == null) return fallback;
    return Color.alphaBlend(source.withValues(alpha: 0.64), fallback);
  }
}
