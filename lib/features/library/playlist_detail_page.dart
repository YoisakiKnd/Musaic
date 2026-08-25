import 'package:flutter/material.dart';

class PlaylistDetailPage extends StatelessWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('歌单 $playlistId')),
      body: const Center(child: Text('歌单详情（P6 实现）')),
    );
  }
}
