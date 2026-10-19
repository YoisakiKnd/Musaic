import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/player/widgets/player_shortcuts.dart';

/// 全局播放快捷键：空格 / 媒体键 / Ctrl+方向键，输入框内不拦截。
void main() {
  late _CountingNotifier notifier;
  late int backs;

  Future<void> pump(WidgetTester tester, {bool hasQueue = true}) async {
    backs = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerNotifierProvider.overrideWith(() {
            return notifier = _CountingNotifier(hasQueue: hasQueue);
          }),
        ],
        child: MaterialApp(
          home: PlayerShortcuts(
            onBack: () async {
              backs++;
              return true;
            },
            child: const Scaffold(
              body: Column(
                children: [
                  TextField(key: Key('search')),
                  Focus(autofocus: true, child: Text('body')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('空格切换播放暂停', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(notifier.toggles, 1);
  });

  testWidgets('媒体键与 Ctrl+方向键切歌', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(notifier.toggles, 1);
    expect(notifier.nexts, 2);
    expect(notifier.previouses, 1);
  });

  testWidgets('在输入框里打空格不会暂停播放', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('search')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(notifier.toggles, 0);
  });

  testWidgets('Esc 触发返回（即使没有播放队列）', (tester) async {
    await pump(tester, hasQueue: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(backs, 1);
  });

  testWidgets('在输入框里按 Esc 不触发返回', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('search')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(backs, 0);
  });

  testWidgets('没有播放队列时不响应', (tester) async {
    await pump(tester, hasQueue: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(notifier.toggles, 0);
  });
}

class _CountingNotifier extends PlayerNotifier {
  _CountingNotifier({required this.hasQueue});

  final bool hasQueue;
  int toggles = 0;
  int nexts = 0;
  int previouses = 0;

  @override
  PlayerState build() => PlayerState(
    queue:
        hasQueue
            ? const [Track(id: '1', sourceId: 'x', title: 't', artist: 'a')]
            : const [],
    currentIndex: hasQueue ? 0 : -1,
  );

  @override
  Future<void> toggle() async => toggles++;

  @override
  Future<void> next() async => nexts++;

  @override
  Future<void> previous() async => previouses++;
}
