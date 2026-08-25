import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/model/track.dart';
import '../../core/theme/app_tokens.dart';
import '../theme/dynamic_color_provider.dart';
import 'widgets/player_progress_bar.dart';
import 'widgets/player_controls.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.track});

  final Track track;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  Color? _dominantColor;

  @override
  void initState() {
    super.initState();
    _extractColor();
  }

  Future<void> _extractColor() async {
    if (widget.track.coverUrl != null && widget.track.coverUrl!.isNotEmpty) {
      final color = await DynamicColorProvider.dominantColorFromImage(
        NetworkImage(widget.track.coverUrl!),
      );
      if (mounted) {
        setState(() => _dominantColor = color);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              DynamicColorProvider.blend(_dominantColor, AppTokens.surfaceBase),
              AppTokens.surfaceBase,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(context, theme),
              Expanded(child: _buildCover()),
              const SizedBox(height: 32),
              _buildInfo(theme),
              const SizedBox(height: 24),
              const PlayerProgressBar(),
              const SizedBox(height: 32),
              const PlayerControls(),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildCover() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: AppTokens.borderRadiusLarge,
          child: widget.track.coverUrl != null
              ? Image.network(
                  widget.track.coverUrl!,
                  fit: BoxFit.cover,
                )
              : Container(
                  color: AppTokens.surfaceSecondary,
                  child: const Icon(Icons.music_note, size: 64),
                ),
        ),
      ),
    );
  }

  Widget _buildInfo(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            widget.track.displayTitle,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            widget.track.displaySubtitle,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
