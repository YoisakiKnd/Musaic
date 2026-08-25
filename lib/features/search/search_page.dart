import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/model/track.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/music_source.dart';
import '../../core/theme/app_tokens.dart';
import '../player/player_notifier.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  final _results = <MusicSource, List<Track>>{};
  bool _isLoading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    if (query.isEmpty) return;
    setState(() {
      _isLoading = true;
      _results.clear();
    });

    final registry = SourceRegistry();
    for (final source in registry.all) {
      try {
        final tracks = await source.search(query);
        if (tracks.isNotEmpty) {
          _results[source] = tracks;
        }
      } catch (_) {
        // ignore per-source failure
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: _performSearch,
              decoration: InputDecoration(
                hintText: '搜索本地或网易云音乐',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _controller.clear();
                          setState(() => _results.clear());
                        },
                        icon: const Icon(Icons.clear),
                      ),
                filled: true,
                fillColor: AppTokens.surfaceSecondary,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          Expanded(
            child: _results.isEmpty
                ? const Center(child: Text('输入关键词开始搜索'))
                : ListView.builder(
                    itemCount: _results.entries.fold<int>(
                      0,
                      (sum, e) => sum + e.value.length + 1,
                    ),
                    itemBuilder: (context, index) {
                      int cursor = 0;
                      for (final entry in _results.entries) {
                        if (index == cursor) {
                          return _SourceHeader(source: entry.key);
                        }
                        cursor += 1;
                        if (index - cursor < entry.value.length) {
                          final track = entry.value[index - cursor];
                          return _TrackTile(
                            track: track,
                            onTap: () async {
                              final notifier = ref.read(playerNotifierProvider.notifier);
                              await notifier.playQueue([track], 0);
                            },
                          );
                        }
                        cursor += entry.value.length;
                      }
                      return const SizedBox.shrink();
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SourceHeader extends StatelessWidget {
  const _SourceHeader({required this.source});

  final MusicSource source;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        source.sourceName,
        style: Theme.of(context).textTheme.labelLarge,
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.track, required this.onTap});

  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(track.displayTitle),
      subtitle: Text(track.displaySubtitle),
      onTap: onTap,
    );
  }
}
