import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/model/track.dart';
import '../../../core/theme/app_tokens.dart';

/// 「加入歌单」通用入口（日常可用性计划 D2）。
///
/// 背景：此前只有搜索页能加入歌单（`search_results_page.dart` 内联实现），
/// 播放页 / 小播放条 / 收藏 / 历史 / 歌单详情**都没有入口**——
/// 用户听到一首歌想存起来，必须回搜索页重新找一遍。这是日常使用最大的摩擦。
///
/// 本组件把该流程抽成可复用入口，任何持有 [Track] 列表的地方都能调用。
///
/// 交互：底部弹窗列出现有歌单 + 「新建歌单」；选择后一次批量写入
/// （`addManyToPlaylist` 内部只做一次读-改-写，避免逐条重写全表）。
class AddToPlaylistSheet extends ConsumerStatefulWidget {
  const AddToPlaylistSheet({super.key, required this.tracks});

  /// 待加入的曲目；支持单曲与批量。
  final List<Track> tracks;

  /// 弹出选择面板；返回是否成功加入（用户取消返回 false）。
  ///
  /// 调用方无需自行处理 SnackBar——本方法统一给出反馈。
  static Future<bool> show(BuildContext context, List<Track> tracks) async {
    if (tracks.isEmpty) return false;
    final added = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => AddToPlaylistSheet(tracks: tracks),
    );
    return added ?? false;
  }

  @override
  ConsumerState<AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<AddToPlaylistSheet> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(libraryRepositoryProvider);
    final names = repository.playlistNames;
    final count = widget.tracks.length;

    return SafeArea(
      child: ConstrainedBox(
        // 歌单可能很多，限制高度让列表可滚动
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                count == 1
                    ? '将「${widget.tracks.first.title}」加入歌单'
                    : '将 $count 首加入歌单',
                style: const TextStyle(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.add_circle_outline_rounded,
                color: AppTokens.accent,
              ),
              title: const Text('新建歌单'),
              enabled: !_busy,
              onTap: _createAndAdd,
            ),
            const Divider(height: 1),
            if (names.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('还没有歌单，先新建一个吧', style: TextStyle(fontSize: 13)),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: names.length,
                  itemBuilder:
                      (context, index) => ListTile(
                        leading: const Icon(Icons.queue_music_rounded),
                        title: Text(names[index]),
                        subtitle: Text(
                          '${repository.playlistTracks(names[index]).length} 首',
                          style: const TextStyle(fontSize: 12),
                        ),
                        enabled: !_busy,
                        onTap: () => _addTo(names[index]),
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _createAndAdd() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('新建歌单'),
            content: TextField(
              controller: controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted:
                  (value) => Navigator.of(dialogContext).pop(value.trim()),
              decoration: const InputDecoration(hintText: '歌单名称'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTokens.accent,
                ),
                onPressed:
                    () =>
                        Navigator.of(dialogContext).pop(controller.text.trim()),
                child: const Text('创建'),
              ),
            ],
          ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;

    final repository = ref.read(libraryRepositoryProvider);
    await repository.createPlaylist(name);
    await _addTo(name);
  }

  Future<void> _addTo(String name) async {
    if (_busy) return;
    setState(() => _busy = true);
    final repository = ref.read(libraryRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      await repository.addManyToPlaylist(name, widget.tracks);
      if (!mounted) return;
      navigator.pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            widget.tracks.length == 1
                ? '已加入「$name」'
                : '已将 ${widget.tracks.length} 首加入「$name」',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('加入失败：$e')));
    }
  }
}
