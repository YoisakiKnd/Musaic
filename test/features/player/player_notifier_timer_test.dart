import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musaic/app/lifecycle/app_lifecycle.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/player/player_notifier.dart';

/// 位置轮询定时器生命周期与后台降级验证
/// （功耗计划 PW-01 / PW-03 / PW-04，B21）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<String> resumeBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_pw_timer_test');
    Hive.init(tempDir.path);
    resumeBox = await Hive.openBox<String>('pw_resume');
  });

  tearDownAll(() async {
    await resumeBox.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('空闲零唤醒；播放创建定时器；暂停取消（PW-01/PW-04）', () {
    fakeAsync((async) {
      final container = _createContainer(resumeBox);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      // 空闲：无定时器
      expect(notifier.debugIsPositionTimerActive, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(notifier.debugPositionTicks, 0);

      // 播放：定时器按 100ms 预算创建
      notifier.debugSetPlaying(true);
      expect(notifier.debugIsPositionTimerActive, isTrue);
      final before = notifier.debugPositionTicks;
      async.elapse(const Duration(milliseconds: 350));
      final ticks = notifier.debugPositionTicks - before;
      expect(ticks, inInclusiveRange(3, 4), reason: '100ms 周期应产生 3~4 次采样');

      // 暂停：定时器立即取消，零唤醒
      notifier.debugSetPlaying(false);
      expect(notifier.debugIsPositionTimerActive, isFalse);
      final pausedTicks = notifier.debugPositionTicks;
      async.elapse(const Duration(seconds: 2));
      expect(notifier.debugPositionTicks, pausedTicks);

      container.dispose();
    });
  });

  test('后台降级为 1Hz；回前台恢复 100ms（PW-03）', () {
    fakeAsync((async) {
      final container = _createContainer(resumeBox);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      final lifecycle = container.read(appLifecycleStateProvider.notifier);

      notifier.debugSetPlaying(true);
      final visibleBaseline = notifier.debugPositionTicks;

      // 进入后台（paused）：定时器重建为 1s 周期
      lifecycle.update(AppLifecycleState.paused);
      expect(AppUiVisibility.degraded, isTrue, reason: '全局降级标志已置位');
      expect(notifier.debugIsPositionTimerActive, isTrue);
      final backgroundTicks = notifier.debugPositionTicks;
      async.elapse(const Duration(seconds: 2));
      final inBackground = notifier.debugPositionTicks - backgroundTicks;
      expect(inBackground, inInclusiveRange(1, 3), reason: '后台应为 1Hz 采样');

      // 回前台：恢复可见预算
      lifecycle.update(AppLifecycleState.resumed);
      async.elapse(const Duration(milliseconds: 250));
      final afterResume =
          notifier.debugPositionTicks - (backgroundTicks + inBackground);
      expect(afterResume, greaterThanOrEqualTo(2), reason: '前台 100ms 周期恢复');
      expect(visibleBaseline, isNot(lessThan(0)));

      container.dispose();
    });
  });

  test('停止可见化标记：dispose 后无定时器残留', () {
    fakeAsync((async) {
      final container = _createContainer(resumeBox);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      notifier.debugSetPlaying(true);
      expect(notifier.debugIsPositionTimerActive, isTrue);
      container.dispose();
      expect(notifier.debugIsPositionTimerActive, isFalse);
      async.flushTimers();
    });
  });
}

ProviderContainer _createContainer(Box<String> resumeBox) {
  return ProviderContainer(
    overrides: [
      playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
      audioHandlerProvider.overrideWithValue(
        MusaicAudioHandler(player: AudioPlayer()),
      ),
      resumeRepositoryProvider.overrideWithValue(
        ResumeRepository(box: resumeBox),
      ),
    ],
  );
}

/// 直接驱动状态的测试替身：绕过真实播放链路，
/// 走 [PlayerNotifier] 的公开 state 同步路径。
class _TestPlayerNotifier extends PlayerNotifier {
  void debugSetPlaying(bool playing) {
    state = state.copyWith(playing: playing);
  }
}
