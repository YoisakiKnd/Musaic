import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart' show sourceRegistryProvider;
import '../../../core/theme/app_tokens.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/track_cover.dart';
import '../player_notifier.dart';

/// 以底部面板打开播放队列（播放页 / 底部播放条共用）。
Future<void> showQueueSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder:
        (sheetContext) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.65,
            child: QueuePanel(onPlayed: () => Navigator.of(sheetContext).pop()),
          ),
        ),
  );
}

/// 播放队列：可拖动排序、移除、点按播放。
///
/// 只订阅 `queue` 与 `currentIndex`：此前整个面板 watch 完整播放状态，
/// 播放中进度每 100ms 更新一次，几百首的队列跟着整表重建。
class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key, this.onPlayed});

  /// 点按某首开始播放后的回调（面板形态下用于关闭面板）。
  final VoidCallback? onPlayed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(playerNotifierProvider.select((s) => s.queue));
    final currentIndex = ref.watch(
      playerNotifierProvider.select((s) => s.currentIndex),
    );
    final notifier = ref.read(playerNotifierProvider.notifier);
    final registry = ref.watch(sourceRegistryProvider);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
          child: Row(
            children: [
              Text('播放队列', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              Text(
                '${queue.length} 首',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              TextButton.icon(
                onPressed:
                    queue.length > 1
                        ? () async {
                          // 清空会丢弃手工排好的顺序（尤其「下一首播放」），先确认
                          final confirmed = await confirmDestructiveAction(
                            context,
                            title: '清空播放队列？',
                            message: '将移除队列中除当前曲目外的全部曲目，该操作不可恢复。',
                          );
                          if (!confirmed) return;
                          notifier.clearQueue();
                        }
                        : null,
                icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                label: const Text('清空'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            buildDefaultDragHandles: false,
            itemCount: queue.length,
            // onReorderItem：newIndex 已按移除后语义给出，直接转发
            onReorderItem: notifier.moveInQueue,
            itemBuilder: (context, index) {
              final t = queue[index];
              final active = index == currentIndex;
              final source = registry.resolve(t.sourceId)?.displayName;
              return ListTile(
                key: ValueKey('${t.key}@$index'),
                dense: true,
                leading: Stack(
                  alignment: Alignment.center,
                  children: [
                    TrackCover(coverUrl: t.coverUrl, size: 40, radius: 6),
                    if (active)
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.equalizer_rounded,
                          size: 20,
                          color: AppTokens.accent,
                        ),
                      ),
                  ],
                ),
                title: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? AppTokens.accent : null,
                  ),
                ),
                subtitle: Text(
                  source == null ? t.artist : '${t.artist} · $source',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '从队列移除',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: scheme.onSurface.withValues(alpha: 0.5),
                      ),
                      onPressed: () => notifier.removeFromQueue(index),
                    ),
                    ReorderableDragStartListener(
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.drag_handle_rounded,
                          size: 20,
                          color: scheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ],
                ),
                onTap: () {
                  notifier.playAt(index);
                  onPlayed?.call();
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
