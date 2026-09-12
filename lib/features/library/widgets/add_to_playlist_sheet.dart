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
    // 用自管理生命周期的对话框，而不是在外部创建 controller 后
    // `showDialog` 返回即 dispose：对话框退场动画期间其 TextField 仍持有
    // controller，提前 dispose 会抛「A TextEditingController was used after
    // being disposed」（主链路 e2e 测试实测捕获）。
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewPlaylistDialog(),
    );
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

/// 新建歌单对话框。
///
/// 独立成 [StatefulWidget] 是为了让 controller 的生命周期与对话框一致：
/// 在 `showDialog` 调用方创建 controller 并 `await` 后立刻 dispose，
/// 会在退场动画期间被仍存活的 TextField 使用而崩溃。
class _NewPlaylistDialog extends StatefulWidget {
  const _NewPlaylistDialog();

  @override
  State<_NewPlaylistDialog> createState() => _NewPlaylistDialogState();
}

class _NewPlaylistDialogState extends State<_NewPlaylistDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建歌单'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(hintText: '歌单名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTokens.accent),
          onPressed: _submit,
          child: const Text('创建'),
        ),
      ],
    );
  }
}
