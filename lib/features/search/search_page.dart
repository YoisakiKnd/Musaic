import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/source/music_source.dart';
import '../../core/theme/app_tokens.dart';
import '../shared/widgets/track_tile.dart';

/// 多渠道聚合搜索（Master Plan P6）：按渠道分组展示，互不阻塞。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SectionResult {
  List<Track>? tracks;
  String? errorMessage;
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final Map<String, _SectionResult> _results = {};
  bool _searching = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(String query) async {
    final registry = ref.read(sourceRegistryProvider);
    final sources = registry.all;
    setState(() {
      _searching = true;
      _results.clear();
      for (final source in sources) {
        _results[source.sourceId] = _SectionResult();
      }
    });

    await Future.wait(
      sources.map((source) async {
        try {
          final tracks = await source.search(query, limit: 20);
          if (!mounted) return;
          setState(() => _results[source.sourceId]!.tracks = tracks);
        } on SourceException catch (e) {
          if (!mounted) return;
          setState(
            () => _results[source.sourceId]!.errorMessage = e.message,
          );
        } catch (_) {
          if (!mounted) return;
          setState(() => _results[source.sourceId]!.errorMessage = '搜索失败');
        }
      }),
    );
    if (mounted) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(sourceRegistryProvider).all;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: '搜索歌曲 / 歌手（多渠道聚合）',
            prefixIcon: const Icon(Icons.search_rounded),
            filled: true,
            fillColor:
                scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
      body: _buildBody(sources),
    );
  }

  Widget _buildBody(List<MusicSource> sources) {
    if (!_searching && _results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.travel_explore_rounded,
                size: 64,
                color: AppTokens.accent.withValues(alpha: 0.45)),
            const SizedBox(height: 12),
            Text('同时搜索所有已启用渠道',
                style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.55),
                )),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: AppTokens.pagePadding,
      itemCount: sources.length,
      itemBuilder: (context, index) {
        final source = sources[index];
        final result = _results[source.sourceId];
        final tracks = result?.tracks;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Text(
                    source.displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Builder(builder: (context) {
                    if (_searching && tracks == null &&
                        result?.errorMessage == null) {
                      return const SizedBox(
                        width: 14,
                        height: 14,
                        child:
                            CircularProgressIndicator(strokeWidth: 2),
                      );
                    }
                    final errorText = result?.errorMessage;
                    if (errorText != null) {
                      return Text(errorText,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.error));
                    }
                    return Text('${tracks?.length ?? 0} 首',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.5),
                        ));
                  }),
                ],
              ),
            ),
            if (tracks case final sectionTracks?)
              ...sectionTracks.map(
                (t) => TrackTile(track: t, queue: sectionTracks, dense: true),
              ),
            if ((tracks?.isEmpty ?? false))
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 4),
                child: Text('无结果',
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.45))),
              ),
          ],
        );
      },
    );
  }
}
