import 'dart:io' show File;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/cover_network.dart';

/// 曲目封面缩略图（列表行 / 首页大卡共用）。
///
/// 从 `TrackTile._TileCover` 提取而来（日常可用性计划 D6）：首页「继续收听」
/// 大卡同样需要「file:// 本地文件 + 渠道 CDN 请求头 + 归一化 URL + 失败回退」
/// 这一整套逻辑，复制一份必然会随渠道变化而漂移，故收成一处。
///
/// [size] 同时决定解码上限（`cacheWidth`）：按物理像素 2 倍解码，
/// 避免列表里每行都解码整张专辑图（迭代计划 §9.1）。
class TrackCover extends StatelessWidget {
  const TrackCover({
    super.key,
    required this.coverUrl,
    this.size = 48,
    this.radius = 12,
  });

  final String? coverUrl;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fallback = SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppTokens.brandGradient,
          borderRadius: BorderRadius.all(Radius.circular(radius)),
        ),
        child: Icon(
          Icons.music_note_rounded,
          size: size * 0.42,
          color: Colors.white70,
        ),
      ),
    );

    final url = coverUrl;
    if (url == null || url.isEmpty) return fallback;
    // 解码尺寸上限取 2 倍，兼顾高分屏清晰度与内存
    final cacheSize = (size * 2).round();
    if (url.startsWith('file://')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.file(
          File(Uri.parse(url).toFilePath()),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: cacheSize,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: normalizeCoverUrl(url),
        httpHeaders: coverHttpHeaders(url),
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: cacheSize,
        fadeInDuration: AppTokens.durationFast,
        placeholder:
            (_, _) => ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: SizedBox(width: size, height: size),
            ),
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}
