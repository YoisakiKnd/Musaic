import 'package:flutter/material.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('资料库'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '我喜欢'),
              Tab(text: '歌单'),
              Tab(text: '历史'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            LikedSongsPage(),
            PlaylistsPage(),
            HistoryPage(),
          ],
        ),
      ),
    );
  }
}

class LikedSongsPage extends StatelessWidget {
  const LikedSongsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('我喜欢的音乐（P6 实现）'));
  }
}

class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('歌单列表（P6 实现）'));
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('最近播放（P6 实现）'));
  }
}
