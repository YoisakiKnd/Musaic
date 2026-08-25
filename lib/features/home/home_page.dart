import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/model/track.dart';
import '../../core/source/source_registry.dart';
import '../../sources/local/local_file_source.dart';
import '../player/player_notifier.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _localTracks = <Track>[];

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    final source = SourceRegistry().resolve('local');
    if (source is LocalFileSource) {
      final tracks = await source.scanAll();
      if (mounted) {
        setState(() {
          _localTracks.clear();
          _localTracks.addAll(tracks);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('首页')),
      body: _localTracks.isEmpty
          ? const Center(child: Text('本地音乐为空'))
          : ListView.builder(
              itemCount: _localTracks.length,
              itemBuilder: (context, index) {
                final track = _localTracks[index];
                return ListTile(
                  title: Text(track.displayTitle),
                  subtitle: Text(track.displaySubtitle),
                  onTap: () async {
                    final notifier = ref.read(playerNotifierProvider.notifier);
                    await notifier.playQueue(_localTracks, index);
                  },
                );
              },
            ),
    );
  }
}
