import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musaic/features/lyrics/domain/lyric_bundle.dart';
import 'package:musaic/features/lyrics/application/lyrics_provider.dart';

class LyricsView extends ConsumerWidget {
  const LyricsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsState = ref.watch(lyricsNotifierProvider);
    final lines = lyricsState.bundle.lines;

    if (lines.isEmpty) {
      return const Center(child: Text('暂无歌词'));
    }

    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        return _LyricLineTile(line: line);
      },
    );
  }
}

class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({required this.line});

  final LyricLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final translation = line.translation;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line.words.map((w) => w.text).join(),
            style: theme.textTheme.bodyLarge,
          ),
          if (translation != null && translation.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                translation,
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
