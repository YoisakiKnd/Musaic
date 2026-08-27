import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb, PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:audio_session/audio_session.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:window_manager/window_manager.dart';

import 'app/router.dart';
import 'core/network/network_config.dart';
import 'core/theme/app_tokens.dart';
import 'features/auth/data/account_repository.dart';
import 'features/library/data/library_repository.dart';
import 'features/player/audio_handler.dart';
import 'features/player/data/resume_repository.dart';
import 'features/search/data/search_history_repository.dart';
import 'features/settings/data/local_music_settings_repository.dart';
import 'features/settings/settings_providers.dart'
    show
        AppSettingsRepository,
        appSettingsRepositoryProvider,
        oledBlackProvider,
        themeModeProvider;
import 'core/di/app_providers.dart';

/// 组合根所需的已初始化依赖集合。
class _Bootstrap {
  static Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {
      // 会话配置失败不阻塞启动
    }
  }

  static Future<void> _configureDesktopWindow() async {
    if (kIsWeb) return;
    final isDesktop =
        !kIsWeb &&
            (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    if (!isDesktop) return;
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      title: 'Musaic',
      size: Size(1120, 760),
      minimumSize: Size(960, 640), // Master Plan §10.3
      center: true,
      backgroundColor: Colors.transparent,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  static Future<void> _requestNotificationPermission() async {
    // Android 13+：无 POST_NOTIFICATIONS 授权时 audio_service 前台通知静默失败，
    // 通知栏/锁屏/耳机按键等核心播放能力整体不可用。启动期申请一次。
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await Permission.notification.request();
    } catch (_) {
      // 授权流程异常不阻塞启动
    }
  }

  static Future<MusaicAudioHandler> _initAudioHandler() async {
    try {
      return await AudioService.init(
        builder: () => MusaicAudioHandler(player: AudioPlayer()),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'dev.musaic.audio.playback',
          androidNotificationChannelName: 'Musaic 播放',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
    } catch (_) {
      // 兜底：系统媒体集成不可用时仍可正常播放（仅缺少通知栏/锁屏控制）
      return MusaicAudioHandler(player: AudioPlayer());
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // release 模式下构建/异步异常默认静默，统一转存 logcat 便于远程诊断
  FlutterError.onError = (details) {
    debugPrint(
      'MusaicFlutterError: ${details.exception}\n'
      '${details.stack?.toString().split('\n').take(6).join('\n')}',
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint(
      'MusaicAsyncError: $error\n'
      '${stack.toString().split('\n').take(6).join('\n')}',
    );
    return true;
  };

  await Hive.initFlutter();
  // 并行打开全部 Box（串行 await 会拖慢冷启动首帧）
  final boxes = await Future.wait<Box<String>>([
    Hive.openBox<String>(AccountRepository.accountBoxName),
    Hive.openBox<String>(LibraryRepository.favoritesBoxName),
    Hive.openBox<String>(LibraryRepository.historyBoxName),
    Hive.openBox<String>(LibraryRepository.playlistsBoxName),
    Hive.openBox<String>(SearchHistoryRepository.boxName),
    Hive.openBox<String>(LocalMusicSettingsRepository.boxName),
    Hive.openBox<String>(AppSettingsRepository.boxName),
  ]);
  final accountsBox = boxes[0];
  final favoritesBox = boxes[1];
  final historyBox = boxes[2];
  final playlistsBox = boxes[3];
  final searchHistoryBox = boxes[4];
  final localMusicSettingsBox = boxes[5];
  final appSettingsBox = boxes[6];
  final resumeBox = await Hive.openBox<String>(ResumeRepository.boxName);

  await _Bootstrap._configureAudioSession();
  await _Bootstrap._requestNotificationPermission();
  await _Bootstrap._configureDesktopWindow();
  final audioHandler = await _Bootstrap._initAudioHandler();

  // 组合根：先建仓库，恢复网络超时配置（渠道 Dio 构建时读取），再注入 override
  final appSettingsRepository = AppSettingsRepository(box: appSettingsBox);
  NetworkConfig.instance.restore(appSettingsRepository.networkTimeoutSeconds);

  runApp(
    ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(
          AccountRepository(
            credentialStore: FlutterSecureCredentialStore(
              const FlutterSecureStorage(
                aOptions: AndroidOptions(encryptedSharedPreferences: true),
              ),
            ),
            accountBox: accountsBox,
          ),
        ),
        libraryRepositoryProvider.overrideWithValue(
          LibraryRepository(
            favoritesBox: favoritesBox,
            historyBox: historyBox,
            playlistsBox: playlistsBox,
          ),
        ),
        audioHandlerProvider.overrideWithValue(audioHandler),
        searchHistoryRepositoryProvider.overrideWithValue(
          SearchHistoryRepository(box: searchHistoryBox),
        ),
        localMusicSettingsRepositoryProvider.overrideWithValue(
          LocalMusicSettingsRepository(box: localMusicSettingsBox),
        ),
        appSettingsRepositoryProvider.overrideWithValue(appSettingsRepository),
        resumeRepositoryProvider.overrideWithValue(
          ResumeRepository(box: resumeBox),
        ),
      ],
      child: const MusaicApp(),
    ),
  );
}

class MusaicApp extends ConsumerWidget {
  const MusaicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final oled = ref.watch(oledBlackProvider);
    return MaterialApp.router(
      title: 'Musaic — 音乐拼图',
      debugShowCheckedModeBanner: false,
      theme: AppTokens.lightTheme,
      darkTheme: oled ? AppTokens.oledTheme : AppTokens.darkTheme,
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
