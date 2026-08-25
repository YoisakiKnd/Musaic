import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/lyrics/domain/lyric_bundle.dart';
import 'package:musaic/features/lyrics/domain/ttml_parser.dart';

/// 歌词状态。
class LyricsState {
  const LyricsState({
    required this.bundle,
    this.isLoading = false,
    this.error,
  });

  factory LyricsState.initial() => LyricsState(
        bundle: const LyricBundle(lines: []),
      );

  final LyricBundle bundle;
  final bool isLoading;
  final String? error;

  LyricsState copyWith({
    LyricBundle? bundle,
    bool? isLoading,
    String? error,
  }) {
    return LyricsState(
      bundle: bundle ?? this.bundle,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// 歌词状态管理器。
class LyricsNotifier extends Notifier<LyricsState> {
  LyricsNotifier() : _registry = SourceRegistry();

  final SourceRegistry _registry;

  @override
  LyricsState build() {
    return LyricsState.initial();
  }

  Future<void> loadLyrics(Track track) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final source = _registry.resolve(track.sourceId);
      if (source == null) {
        state = state.copyWith(isLoading: false);
        return;
      }

      final raw = await source.getLyrics(track);
      if (raw == null || raw.isEmpty) {
        state = state.copyWith(isLoading: false);
        return;
      }

      LyricBundle bundle;
      if (raw.trim().startsWith('<')) {
        bundle = TtmlParser.parse(raw, source: track.sourceId);
      } else {
        bundle = _parseLrc(raw, source: track.sourceId);
      }

      state = state.copyWith(bundle: bundle, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  LyricBundle _parseLrc(String lrc, {String? source}) {
    final lines = <LyricLine>[];
    final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

    for (final line in lrc.split('\n')) {
      final match = regex.firstMatch(line);
      if (match == null) continue;

      final m = int.parse(match.group(1)!);
      final s = int.parse(match.group(2)!);
      final ms = int.parse(match.group(3)!);
      final text = match.group(4)!.trim();

      if (text.isEmpty) continue;

      final startTime = Duration(minutes: m, seconds: s, milliseconds: ms);
      final endTime = startTime + const Duration(seconds: 5);

      lines.add(LyricLine(
        startTime: startTime,
        endTime: endTime,
        words: [
          LyricWord(
            text: text,
            startTime: startTime,
            endTime: endTime,
          ),
        ],
      ));
    }

    return LyricBundle(lines: lines, rawLrc: lrc, source: source);
  }
}

/// lyricsNotifierProvider
final lyricsNotifierProvider =
    NotifierProvider<LyricsNotifier, LyricsState>((ref) {
  return LyricsNotifier();
});
