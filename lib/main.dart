import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb, PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:audio_session/audio_session.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:window_manager/window_manager.dart';

import 'core/logging/app_logger.dart';
import 'core/storage/app_schema.dart';
import 'core/storage/hive_recovery.dart';
import 'core/storage/schema_migrator.dart';
import 'app/lifecycle/app_lifecycle.dart';
import 'app/router.dart';
import 'core/network/network_config.dart';
import 'core/theme/app_tokens.dart';
import 'features/auth/data/account_repository.dart';
import 'features/library/data/library_repository.dart';
import 'features/player/audio_handler.dart';
import 'features/player/data/resume_repository.dart';
import 'features/search/data/search_history_repository.dart';
import 'features/settings/data/local_music_settings_repository.dart';
import 'features/player/player_notifier.dart';
import 'features/settings/settings_providers.dart'
    show
        AppSettingsRepository,
        appSettingsRepositoryProvider,
        autoResumeOnLaunchProvider,
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

  static Future<MusaicAudioHandler> _initAudioHandler() async {
    try {
      return await AudioService.init(
        // 交叉淡入（N4）需要第二路音频同时出声，故预建次播放器。
        // 默认不启用（crossfadeSeconds = 0），此时它不参与播放。
        builder:
            () => MusaicAudioHandler(
              player: AudioPlayer(),
              secondary: AudioPlayer(),
            ),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'dev.musaic.audio.playback',
          androidNotificationChannelName: 'Musaic 播放',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
    } catch (e) {
      // 兜底：系统媒体集成不可用时仍可正常播放（仅缺少通知栏/锁屏控制）。
      // 不允许静默：Activity 继承错误曾让这里失败 0 日志（EMU 实测教训）。
      AppLog.debug('MusaicAudioService init 失败: $e');
      return MusaicAudioHandler(player: AudioPlayer());
    }
  }

  /// 执行存储 schema 迁移（架构演进设计 §3.2 / S1）。
  ///
  /// 设计要点：
  /// - **在仓库读取任何数据之前**运行，否则会读到旧结构；
  /// - 备份 Box 单独打开并常驻，用于抵御「迁移中途进程被杀」；
  /// - 迁移失败或数据版本高于应用时**不阻断启动**：应用以降级模式
  ///   进入首页（只读），并通过日志留下可诊断线索——白屏比降级更糟。
  static Future<void> _migrateStorage(
    Map<String, Box<String>> boxes,
    String hiveDir,
  ) async {
    Box<String>? backupBox;
    try {
      backupBox = await openBoxSafely<String>(
        SchemaMigrator.backupBoxName,
        hiveDir,
      );
      final reports = await AppSchema.migrateAll(boxes, backupBox: backupBox);
      if (AppSchema.hasUnusable(reports)) {
        AppLog.error(
          '部分本地数据不可用，已进入降级模式：'
          '${reports.where((r) => !r.isUsable).map((r) => r.boxName).join(', ')}',
        );
      }
    } catch (e, st) {
      // 迁移基础设施本身出错（如备份 Box 打不开）：不能因此让应用起不来。
      // 未迁移的数据仍可被旧代码读取，属于可接受的降级。
      AppLog.error('存储迁移流程异常，已跳过：$e', stackTrace: st);
    }
  }

  static Future<void> _configureDesktopWindow() async {
    if (kIsWeb) return;
    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
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
    // 通知栏/锁屏/耳机按键等核心播放能力整体不可用。首帧之后申请一次。
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await Permission.notification.request();
    } catch (_) {
      // 授权流程异常不阻塞启动
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // release 模式下构建/异步异常默认静默，统一转存 logcat 便于远程诊断
  FlutterError.onError = (details) {
    AppLog.error(
      'MusaicFlutterError: ${details.exception}',
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.error('MusaicAsyncError: $error', stackTrace: stack);
    return true;
  };

  // 图片缓存上限（迭代计划 §9.1）：数量 300、字节 100MB，防止长会话内存爬升
  PaintingBinding.instance.imageCache.maximumSize = 300;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20;

  await Hive.initFlutter();
  // Box 文件位于系统文档目录（hive_flutter 1.1.0 initFlutter 的默认位置）
  final hiveDir = (await getApplicationDocumentsDirectory()).path;
  // 并行打开全部 Box（串行 await 会拖慢冷启动首帧）；
  // 单个 Box 损坏先备份再重建，不阻塞首页（迭代计划 §7.5 / B08）
  final boxes = await Future.wait<Box<String>>([
    openBoxSafely(AccountRepository.accountBoxName, hiveDir),
    openBoxSafely(LibraryRepository.favoritesBoxName, hiveDir),
    openBoxSafely(LibraryRepository.historyBoxName, hiveDir),
    openBoxSafely(LibraryRepository.playlistsBoxName, hiveDir),
    openBoxSafely(SearchHistoryRepository.boxName, hiveDir),
    openBoxSafely(LocalMusicSettingsRepository.boxName, hiveDir),
    openBoxSafely(AppSettingsRepository.boxName, hiveDir),
  ]);
  final accountsBox = boxes[0];
  final favoritesBox = boxes[1];
  final historyBox = boxes[2];
  final playlistsBox = boxes[3];
  final searchHistoryBox = boxes[4];
  final localMusicSettingsBox = boxes[5];
  final appSettingsBox = boxes[6];
  final resumeBox = await openBoxSafely<String>(
    ResumeRepository.boxName,
    hiveDir,
  );

  // 存储 schema 迁移（架构演进设计 §3.2 / S1）：
  // 必须在**任何仓库读取数据之前**执行，否则仓库会读到旧结构。
  // 备份 Box 单独持有，用于「进程被杀后恢复」（见 SchemaMigrator 文档）。
  await _Bootstrap._migrateStorage(<String, Box<String>>{
    AccountRepository.accountBoxName: accountsBox,
    LibraryRepository.favoritesBoxName: favoritesBox,
    LibraryRepository.historyBoxName: historyBox,
    LibraryRepository.playlistsBoxName: playlistsBox,
    SearchHistoryRepository.boxName: searchHistoryBox,
    LocalMusicSettingsRepository.boxName: localMusicSettingsBox,
    AppSettingsRepository.boxName: appSettingsBox,
    ResumeRepository.boxName: resumeBox,
  }, hiveDir);

  await _Bootstrap._configureDesktopWindow();

  // AudioService 必须在 runApp 前绑定（模拟器实测：延迟到首播的绑定
  // 不生效——通知栏/锁屏会话全部缺失），audio_service 0.18 的官方要求
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
      child: const AppLifecycleObserver(child: MusaicApp()),
    ),
  );

  // 首帧之后：音频会话配置与通知权限申请（不阻塞首帧，迭代计划 §10.1）
  unawaited(
    WidgetsBinding.instance.endOfFrame.then((_) async {
      await _Bootstrap._configureAudioSession();
      await _Bootstrap._requestNotificationPermission();
    }),
  );
}

class MusaicApp extends ConsumerStatefulWidget {
  const MusaicApp({super.key});

  @override
  ConsumerState<MusaicApp> createState() => _MusaicAppState();
}

class _MusaicAppState extends ConsumerState<MusaicApp> {
  @override
  void initState() {
    super.initState();
    // 「启动时自动恢复上次播放」：首帧后台续播断点曲目（设置默认关闭）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(autoResumeOnLaunchProvider)) return;
      unawaited(ref.read(playerNotifierProvider.notifier).restoreResume());
    });
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
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
