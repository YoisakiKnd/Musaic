# Musaic 改进计划（Improvement Plan v1.0）

> 日期：2026-08-26 ｜ 依据：架构评审 + 依赖治理重构 + 本轮代码核查
> 原则：每条改进都必须落到具体文件/行为，可验证、可度量；「先兑现，再修复，后提升，终扩展」。
>
> **进度快照（2026-08-27，commit f16a685 → 0c70490+）**
>
> | 状态 | 条目 |
> |---|---|
> | ✅ 已完成 | F1（含 Android service/receiver 缺失根因修复 + A13 通知权限）· F2（网络超时可调）· F3（定时多模式）· F4（队列管理+系统队列打通）· F5（搜索分页）· F8（本地封面取色兜底）· F9（过期引导）· B1（收藏 O(1)）· B4 · B7 · N1a/N1b/N1c（倍速/歌词偏移/音质档位）；新增：断点续播、资料库 JSON 导出/导入 |
> | ⏸ 待办 | F6 YTM 歌词、F7 QQ 账号歌单 —— 均需协议调研（接口未经真机验证前不盲写）；D/P/U/E 系列按里程碑排期 |
>
---|---|
| **P0-a 落地架构重构** | 上一轮 45 文件改动（能力接口 / core 契约上移 / 401 全渠道接线 / 凭据缓存）需按 P0/P1/P2 拆 3~4 个 commit 入库，否则本计划所有工作与之混染 |
| **P0-b 恢复 CI** | `flutter analyze + flutter test` 最小流水线；git 历史显示 CI 曾被主动移除，需确认原因（网络/成本）后重建，至少跑本地 pre-push |
| **P0-c 真机回归基线** | 重构触碰了四渠道 create/poll 登录链路与 library 歌单页，合入前 Android + macOS 各过一遍：扫码登录 → 播放 → 歌词 → 账号歌单 → 登出 |

---

## 1. 功能修复 —— 让「已承诺的能力」真实生效（F 系列）

按 README/设置页已宣称但缺失/半残的功能排序：

| ID | 问题（证据） | 方案 | 规模 |
|---|---|---|---|
| **F1** 🔴 | **Android 13+ 通知栏/锁屏控制不工作**：manifest 无 `POST_NOTIFICATIONS` 权限（`android/app/src/main/AndroidManifest.xml`），首次启动不申请 → audio_service 前台通知被系统静默拒掉，「通知栏/锁屏/耳机按键」核心卖点在新机型整体落空 | manifest 补权限；首启播放前 `Permission.notification.request()`；被拒时设置页给出引导入口；与本地音乐权限申请合并成一个「系统权限」区块 | S |
| F2 | 「播放与性能（超时/缓存）」设置不存在：超时是硬编码魔法数（source 8/10/15s、`_loadAndPlay` 15/25s 散落两处），缓存不可配 | 设置页实现承诺：①全局网络超时滑条（2 个档位即可），经 settings provider 注入各渠道 `_buildDio` 与播放链路；②封面磁盘缓存上限；③把散落的 timeout 收进 `AppTokens`/settings 单一事实源 | M |
| F3 | 定时关闭只有「倒计时」一种：一次性 `Timer`（`player_notifier.setSleepTimer`）在 app 被系统挂起时不可靠，且无「播完当前曲目停止」「N 首后停止」 | 补两种模式（后者在 `_onPlayerStateChanged/completed → next()` 链路上数歌数，天然可靠）；倒计时模式在 UI 文案注明「播放中生效」 | M |
| F4 | 播放队列宣称「队列管理」实为只读清单（`player_page._openQueueSheet`）；且 `MusaicAudioHandler` 从未 `setQueue`，`queueIndex` 恒 0 → 车机/系统媒体中心看到空队列 | PlayerNotifier 增加 `removeAt/move/reorder`；队列面板支持拖拽排序 + 滑动删除；将 `mediaItem + queue + queueIndex` 接入 audio_service，使锁屏/车机获得真实队列上下文 | M |
| F5 | 搜索宣称分页但从未使用：`MusicSource.search(offset)` 渠道端已实现，UI 固定 `limit: 20` 一锤子（`search_page`/`search_results_page` 无 offset/加载更多）；结果要等最慢渠道全部返回才出现 | 每渠道滚动到底自动续拉（offset += 20）；配合把 `Future.wait` 改为逐渠道流式落地：每个渠道一节，先到先渲染 + 骨架屏；QQ smartbox ≤10 条限制在 UI 明示 | M |
| F6 | 「逐字歌词」实际只有网易云兑现；YTM `fetchLyrics => null` 无字幕来源 | 接入 YTM captions/timedtext 通道（LRC 级起步）；QQ/酷狗的 qrc/krc 为私有加密——与「不破解」免责声明冲突，README 渠道矩阵显式标注各渠道歌词精度等级，不假装支持 | M |
| F7 | 账号歌单仅网易云一家 | QQ 实现 `RemotePlaylistCapable`（musicu.fcg `music.disktop.Sara.GetSysPlayList` 类接口，复用已有 comm 基建）；酷狗接口不稳定，暂缓 | M |
| F8 | 本地文件无沉浸取色：`dynamic_color_provider.dart:39` 明示「本地路径等暂不支持」 | `CoverPalette` 支持 `file://`（palette_generator 接受字节，读 `local` 渠道内嵌封面已落盘的缓存 jpg 即可） | S |
| F9 | 三态状态机「已过期」后无引导：expired 徽章只存在于账号页 | 过期时全局 banner/SnackBar 一次性引导（「QQ 音乐登录已过期，点此重新登录」），点击直达通用登录页（重构后只需 `QrLoginPage(sourceId)`，成本低） | S |

---

## 2. Bug 修复（B 系列）

| ID | 问题 | 修复 | 规模 |
|---|---|---|---|
| B1 | **收藏判定 O(N²)**：`track_tile.dart:42` 每个瓦片 watch 整个 `favoritesProvider`（全量 JSON decode），任意收藏变化 → 所有行重建并线性扫描；收藏过千后切一首歌卡一帧 | `favoritesProvider` 改产出 `Set<String> keys`（一次 decode），或直接用 `LibraryRepository.isFavorite(key)`（Hive containsKey O(1)）+ box 事件失效；`recentHistoryProvider` 同理避免每事件全表 decode+sort | M |
| B2 | 历史裁剪每次播放全表重读：`addHistory → _trimHistory()` 对 200 条全量 `jsonDecode` 排序（播一首歌一次） | key 改 `<毫秒时间戳>#<trackKey>` 前缀，利用 Hive key 有序性 `deleteAt(0)` 即裁剪；旧数据一次性迁移 | S |
| B3 | YTM 登录把 WebView 提取的 **全部 30+ cookie 逐条写 Keystore/Keychain**（`saveCredentials` 一字段一 key），慢且无界 | ①白名单只存认证关键键（SAPISID 族 / __Secure-1PSID 族等 ~6 个）；②`AccountRepository` 支持单渠道单 blob（JSON 一次读写），一并消除 readAll 依赖（与已上的缓存互补） | M |
| B4 | `previous/next({bool manual})` 参数从未使用；系统按键与手动切歌在「上一首要回开头」规则上语义其实应不同（车机「上一首」通常直接切） | 要么实现 manual 语义（系统 skip 不回开头），要么删参数（当前是 3s 规则一刀切） | S |
| B5 | 本地扫描边界：`_readTagBytes` 头 512KB + 尾 128B 拼接，若 ID3v2 头本身 >512KB（高解析度嵌入图）会截断丢标签；封面缓存 jpg 无清理策略（曲库删改后永久残留 temp） | v2 header 尺寸字段驱动二次读取；`清除封面缓存`（设置已有入口）扩为「重建缓存」并按 mtime 淘汰 | S |
| B6 | 账号歌单加载失败被吞成空态（`remotePlaylistsProvider` 错误 → `value ?? []`），用户以为「没有歌单」 | 失败渲染「重试」行（与 F5 的逐节渲染一起做） | S |
| B7 | 死代码/卫生：`library_providers.dart` 尾部残留孤立注释；`_showComingSoon` 仅剩兜底；`url_utils` 等按需清理 | 顺手清 | S |
| B8 | 真机验证清单（非代码 bug，归 QA）：iOS 通知音打断播放行为（audio_session `music()` 配置的 interruption 策略）、Windows 下 YTM WebView 登录（flutter_inappwebview_windows 成熟度）、macOS 最小窗口尺寸 | profile 构建 + checklist 过一轮，结论回写 README 平台支持矩阵 | S |

---

## 3. 性能提升（P 系列）

目标预算继承 master plan §10：冷启动 <1s、点歌到出声 <800ms（Wi-Fi）、列表滚动 ≥60fps、播放常驻内存 <150MB。先测后改：

| ID | 项 | 方案 | 规模 |
|---|---|---|---|
| P1 | **本地扫描卡 UI**：`LocalFileSource.scanLibrary` 目录遍历 + 逐文件 ID3 解析全在主 isolate（`Id3Parser.parse` 为同步 CPU），千首级曲库触发首页扫描会掉帧 | `Isolate.run` 批量解析（分块 yield 进度回调）；增量扫描（path+mtime 缓存，只解析新文件）；扫描改懒触发（首页可见或设置手动），去掉与 `autoScanOnStartup` 承诺不符的静默 | L |
| P2 | **点歌到出声延迟**：resolveStream 串行等 DNS/TLS + 播放器 setUrl | ①当前曲剩余 ≥30s 时预取下一曲 resolveStream（含重定向预热）；②dio `connectTimeout` 内 keep-alive 复用；③指标：埋点 logcat 记录 tap→playing 间隔，中位数入验收 | M |
| P3 | 启动剩余成本：Hive boxes 已并行；`AudioService.init` 仍阻塞 runApp 前 | 首页先渲染，音频服务延后到首次播放/后台切换再 init（handler 需要占位对象）；`AccountNotifier` 启动校验错峰（当前 4 渠道并发打网络） | M |
| P4 | 歌词渲染重绘面：`LyricsView` 每 position tick 重建可见行，逐字填充用 widget 树模拟 | 当前行改 `CustomPainter`（TextPainter 布局缓存，只重绘填充进度），非当前行 `RepaintBoundary` 隔离；与 U5 动效合并实施 | L |
| P5 | 列表与内存：封面 memCacheWidth 已到位 ✓；`ImageCache` 全局无上限；QQ `_enrichCovers` 每结果一请求无限并发 | `PaintingBinding.instance.imageCache.maximumSizeBytes` 显式设限（如 100MB）；enrich 加并发闸（max 6）或换批量详情端点 | S |
| P6 | 度量体系：以上全部 | profile 模式 + `flutter timeline` 基线报告入库（docs/benchmarks），防回退 | S |

---

## 4. UI 改进（U 系列）

### 4.0 设计语言决策（D 系列 · 新增，本计划的样式总纲）

> **决策（2026-08-26）**：双设计语言分区。
> **主 UI（首页/搜索/资料库/设置/账号/登录）采用 Flutter 原生 Material 3 / Material You 语言**；
> **全屏播放器 + 歌词 + 播放队列面板保留 Apple Music 沉浸式风格**。
> 理由：主 UI 与系统组件（对话框/菜单/导航/输入）同语言，降低认知成本、跟随 Flutter 演进；
> 播放器是「异质沉浸空间」，Apple 风格恰是其体验价值所在。

**分区边界表**：

| 区域 | 设计语言 | 代表元素 |
|---|---|---|
| AppShell 导航 / Home / Search / Library / Settings / 登录页 | **Material 3** | NavigationBar、SegmentedButton、FilterChip、SearchBar、M3 tonal surface |
| MiniPlayer（桥梁层） | M3 elevated surface，可选玻璃 | 打开后无缝衔接 Apple 风格播放页 |
| PlayerPage / LyricsView / 队列面板 | **Apple Music** | 沉浸渐变、逐字填充、黑胶动效、受控模糊 |

**D 系列工项**（U 系列的前置）：

| ID | 内容 | 现状证据 | 规模 |
|---|---|---|---|
| **D1** | **令牌双轨制**：`AppTokens` 拆为 `MatTokens`（M3 规范值：卡片圆角 12/16、sheet 28、M3 motion curves `Curves.emphasized*`、textTheme 直接用 `Typography.material2021`）与 `ImmersiveTokens`（现值原样保留：radiusCard 24、accent 红渐变、easeOutCubic、positionThrottle）；按分区表规定页面可引用哪套 | `lib/core/theme/app_tokens.dart` 单一 Apple 系令牌被全 app 引用 | M |
| **D2** | **主 UI 色彩回归 M3 色调体系**：`ColorScheme.fromSeed(seed: 品牌红)` 不再强制覆写 `primary/secondary`，让 M3 生成完整 tonal palette（secondaryContainer/surfaceContainer* 供 chip、导航指示器、FAB 使用）；自定义 Apple 中性色（`0xFF151013` 带粉底、`F6F6F9`）替换为 scheme.surface 系；OLED 纯黑变体保留（它本就是 M3 社区常见需求） | `_buildTheme` 覆写 primary/secondary/surface 为硬编码值 | S |
| D3 | **可选 Material You**：Android 12+ 壁纸取色开关（`dynamic_color` 包，默认关闭保品牌红），仅作用于主 UI；播放器永远由封面取色驱动，两者不冲突 | `themeModeProvider` 设置体系已有 | S |
| **D4** | **组件替换清单（主 UI）**：①底部导航：去掉 32 圆角描边浮岛容器 → 标准 `NavigationBar`（M3 规范高度 80、上滑隐藏可后置）；②首页搜索胶囊 → M3 `SearchBar`；③搜索「合并/分组」「单选/聚合」枚举切换 → `SegmentedButton`；④渠道多选 → `FilterChip` 行；⑤设置主题模式三选 → `SegmentedButton`；⑥批量操作栏 → M3 `Surface` secondaryContainer 色带；⑦AppBar 标题 22/w700 Apple 体 → M3 headlineSmall 500 | `app_shell.dart:52-84`、`home_page.dart:74-97`、`search_page` | M |
| D5 | **动效分区**：主 UI 路由转场改 M3 shared-axis（go_router custom page + `Curves.emphasizedDecelerate`）；播放器进入/退出保持现有 slide+fade Hero 大卡片语言，不迁移 | `router.dart:69-87` | S |
| D6 | **亮色主题走查**：主 UI 切 M3 scheme 后亮色自然达标（tonal palette 自带对比度）；播放器亮色单独校准（渐变底 + 白封面文字的 alpha 规则） | 现亮色为深色优先的欠账 | S（并入 U1） |
| D7 | README / master plan 的「体验灵感」表述同步更新为双语言分区，防「宣称-实现」漂移 | 现 README 写「体验灵感：Mei（Apple Music 风格）」笼统 | S |

### 4.1 U 系列改进项（已按分区重标）

| ID | 分区 | 页面 | 改进 | 规模 |
|---|---|---|---|---|
| U1 | 全局 | — | Edge-to-edge：`AnnotatedRegion` 状态栏图标跟随主题与播放器页；Android targetSdk 35 前置适配；亮色走查（与 D6 合并） | M |
| U2 | 🍎Apple | 全屏播放器 | 黑胶唱盘封面（旋转跟 playing，暂停缓停）；背景渐变随 `CoverPalette` 主色 `AnimatedSwitcher` 交叉淡化；下滑关闭与歌词滚动的竞技场手势冲突处理；长按封面「大图模式」 | M |
| U3 | 🍎Apple | 歌词 | Apple Music 式当前行放大 + 非当前行 blur/降透明动画；翻译行排版；手动回看 ≥2s 悬浮「回到当前」按钮（部分逻辑已有，补齐视觉） | M |
| U4 | 🎨Material | 搜索 | 渠道 FilterChip 行（含失败态色点）、每渠道独立骨架屏与「重查此渠道」、分组头可折叠、批量操作栏吸附动效（M3 secondaryContainer） | M |
| U5 | 🎨Material | 首页 | 「继续收听」大卡（上次中断位置直接续播）、最近播放横滑卡（M3 Card + 8/12 圆角）、空态用 M3 图标 + 文案规范（不引插画依赖） | M |
| U6 | 桥梁 | MiniPlayer | M3 elevated surface 胶囊（玻璃开=现 BackdropFilter，关=surfaceContainer+elevation 降级，逻辑已有开关）；左右滑切歌、顶部 2px 进度线、点击展开 Hero 衔接播放器 | S |
| U7 | 🎨Material | 桌面端 | ≥1200dp 三栏（NavigationRail/NavigationDrawer + 列表 + 右栏常驻队列/歌词面板——右栏面板容器用 M3，队列**内容排版**沿用播放器区规则）；Windows 标题栏菜单、快捷键表（空格播放、←→切歌、/ 聚焦搜索）；最小尺寸已有 | L |
| U8 | 体系 | — | typography/spacing scale 按 M3 text theme（主 UI）与沉浸式自定义 scale（播放器）双轨落地（D1 的一部分）；统一空态/错误态组件；`AccessibilityFeatures.disableAnimations` 尊重减弱动效 | M |

---

## 5. 新功能（N 系列，对齐 master plan §18 路线）

| 阶段 | 功能 | 备注 |
|---|---|---|
| **短期 N1**（播放体验补全） | 播放速率 0.75–1.5×（just_audio `setSpeed`，桌面端验证）；歌词时间偏移（全局 ± 每曲，存 settings）；音质选择（网易云 `br` 参数、QQ 按权益档位）+ 失败自动降档重试 | 都是小切口高频需求 |
| **短期 N2**（数据自主） | 收藏/歌单 JSON+m3u 导入导出；**WebDAV 同步**（favorites/history/playlists/settings，凭据永不同步——master plan V1.3 既定项，借鉴 PicaComic） | 同步要做冲突策略（时间戳合并） |
| **中期 N3**（内容维度） | 艺人/专辑浏览视图（本地 + 云端元数据聚合，Track 模型需扩展 albumArtists/MBID 类字段）；「红心写回渠道」（网易云 likeapi 首个案例，建立 MusicSource `like()` 写能力抽象）；相似歌曲/电台（渠道能力不一） | 写能力抽象是关键一步 |
| **中期 N4** | 均衡器（Android 平台 Equalizer，桌面平台能力不一→按平台开关）；gapless/交叉淡入（just_audio 平台差异大，作为高级实验开关） | 风险高，先 spike |
| **中期 N5**（可用性） | 代理设置（dio `findProxy`，YTM 场景刚需，master plan 风险登记册项）；诊断日志环形缓冲 + 设置页导出（脱敏后 zip） | 为「渠道 API 随时失效」的长期运营兜底 |
| **长期 N6（V2）** | 自定义渠道插件（JS 沙箱，PicaComic 式——需单独立项做安全设计）；DLNA 投屏；Android Auto（audio_service queue 打通后顺路）；生物识别应用锁（local_auth）；i18n（gen_l10n，现为硬编码中文） | 按需排期 |

---

## 6. 工程与质量（E 系列）

| ID | 项 |
|---|---|
| E1 | **架构守护测试**：一个单测扫描 `lib/features/**` 禁止出现 `sources/` import、`lib/core/**`（di 除外）禁止出现 `features/` import——用 CI 固化本轮重构成果，防回潮（低成本高价值，优先做） |
| E2 | 测试补强：渠道协议测试（dio `HttpClientAdapter` 桩：登录状态机、checkSession 契约「断网必须 throw」）、PlayerNotifier 状态迁移（fake handler）、渠道解析 fixture（各渠道真实响应 JSON 脱敏存档） |
| E3 | pre-push：`dart format --set-exit-if-changed` + analyze + test；版本号单一来源（pubspec → 关于页注入，勿双处手写 0.1.0） |
| E4 | pub cache 补丁根治：`flutter_inappwebview_android` 用 `dependency_overrides` git fork 替代 `tool/patch_inappwebview_gradle.sh`（README 已标 TODO） |

---

## 7. 里程碑与优先级

> 规模：S ≤1 人日 ｜ M 2–5 人日 ｜ L 1–2 周。🔴 = 影响核心承诺的必修。

```
M1「兑现与止损」  ~2 周
  前置: P0-a/b/c
  F1🔴 F8 F9 | B1 B2 B4 B7 | E1 | P6(基线测量) | D1 D2 D7(设计双轨制落地) U1 U6
  出口标准: Android 13 真机通知/锁屏可用；千首收藏不掉帧；架构守护测试进 CI；
           主 UI 完全走 M3 scheme（播放器分区不变）

M2「体验完整度」  ~4 周
  F2 F3 F4 F5 | B3 B5 B6 | P1 P2 P3 | D4 D5(组件替换+动效分区) U2 U3 U4
  出口标准: 搜索可分页流式；队列可管理且系统媒体中心可见；点歌首帧中位数 <800ms；
           主 UI 无自架浮岛组件残留（导航/搜索/设置均 M3 原生）

M3「内容与数据」  ~4-6 周
  F6 F7 | N1 N2 | P4 P5 | D3(Material You 开关) U5 U7(启动)
  出口标准: WebDAV 同步可用；YTM 有歌词；桌面三栏成型

M4「V2 演进」    按需
  N3–N6 | U8 收尾 | E2 全量 | 插件渠道立项
```

依赖关系提示：D1/D2 是 U 系列的硬前置（先换轨道再装修）；F4（队列重写）应在 audio_service queue 打通一起做，避免两遍；F5 与 U4 是同一改造的两面（流式渲染 + 骨架）；P4 与 U3 合并实施（都在歌词绘制层）；B1/B2 与 E2 的 provider 测试一起落。

## 8. 验收度量

- **功能**：真机 checklist（渠道 × 平台矩阵：登录/播放/歌词/账号歌单/过期引导）每里程碑跑一轮
- **性能**：startup trace <1s、tap→出声 p50 <800ms、500 收藏 + 1000 本地曲库滚动无 >32ms 掉帧、播放常驻 <150MB（DevTools memory，profile 构建）
- **质量**：`flutter analyze` 零问题持续；测试数只增不减（当前 77）；架构守护测试通过；CI 全绿才可合入
- **文档**：README 渠道能力矩阵与代码声明一致（每里程碑 diff 一遍，杜绝「宣称-实现」漂移——本次评审的最大教训）

---

## 9. 补充 Bug 与风险整改清单（H 系列）

> 本节根据当前源码、平台配置、测试目录和 Git 工作树复核补充。H 系列优先级高于普通功能迭代；除注明「验证」外，均应落到代码、测试或发布配置。

| ID | 优先级 | 问题与证据 | 具体修复方案 | 验收方式 |
|---|---|---|---|---|
| H1 | 🔴 | Android Release 使用 debug 签名，无法进行正式发布 | `android/app/build.gradle.kts` 增加独立 release signingConfig；通过 `key.properties` 或 CI Secret 注入，提交 `key.properties.example` | `flutter build apk --release` 成功；签名指纹与发布配置一致 |
| H2 | 🔴 | 当前存在大量未提交/未跟踪核心文件，CI 已被移除 | 先建立干净提交，再恢复 `.github/workflows/ci.yml`；PR 执行 format/analyze/test，tag 执行平台构建 | 干净 clone 可完成依赖安装、测试和构建 |
| H3 | 🔴 | 播放队列变更后系统媒体 `queueIndex` 可能过期 | `publishQueue` 显式接收当前索引；移动、删除、清空、随机重排全部同步队列指针 | Android 通知栏、车机/Android Auto 点选与队列索引一致 |
| H4 | 🔴 | `player_notifier.dart` 打印完整播放 URL，可能包含签名和 Token | 生产环境关闭完整 URL 日志，只输出渠道、域名、是否本地和请求耗时；统一经脱敏 Logger | 日志扫描不得出现 `Cookie`、`Authorization`、`token`、完整播放 URL |
| H5 | 🔴 | WebView 使用 `getAllCookies()`，可能把其他站点 Cookie 转发给 YouTube | 按 `webLoginCookieOrigins` 做 host 白名单；仅保留 YTM 认证所需 Cookie 字段 | 测试其他域名 Cookie 不会进入 YTM 登录请求 |
| H6 | 🔴 | 酷狗播放地址未统一升级 HTTPS，Token/UserID 通过 GET 参数传递 | 播放 URL 只接受 HTTPS；凭据改为请求体、Cookie 或服务端允许的安全头；补 Apple 平台 ATS 验证 | iOS/macOS/Android 播放矩阵通过，抓包不出现明文凭据 |
| H7 | 🔴 | YTM `checkSession` 忽略账号摘要结果，失效 Cookie 可能仍被判定有效 | 根据账号摘要和认证 Cookie 实际结果返回 false；网络异常继续抛出而不是标记过期 | 有效 Cookie、失效 Cookie、断网三种测试分别通过 |
| H8 | 🔴 | Hive Box 打开失败会阻断整个应用启动 | 启动阶段按 Box 分组容错；损坏 Box 备份后重建；关键资料保留恢复提示 | 模拟损坏/只读/磁盘异常时首页仍可进入 |
| H9 | 高 | MQTT 畸形包会结束扫码，QoS>0 未回 PUBACK，缓冲区可能无界增长 | 校验剩余长度上限；坏包丢弃并继续；实现 QoS ACK；限制缓冲区大小和连接超时 | 畸形包、超大长度、QoS>0、断线重连测试通过 |
| H10 | 高 | PlayerPage 监听整个 `PlayerState`，进度变化会导致整页 10Hz 重建 | 拆成 currentTrack、position、playing、queue、sleep 等精确 `select`；背景/封面加 `RepaintBoundary` | Profile 模式下播放页非进度组件不随 100ms 进度重建 |
| H11 | 高 | 本地扫描、ID3 解析和封面写盘运行在 UI isolate | isolate 扫描、4 路有界解析、进度回调、取消、增量索引 | 1000 首曲库扫描时主线程无明显卡顿 |
| H12 | 高 | 搜索首屏仍等待所有渠道；分页失败被当作到底 | 每渠道独立状态，先到先显示，支持取消、重试、分页和失败重查 | 慢渠道不阻塞已完成渠道，失败渠道有重试入口 |
| H13 | 高 | 保存全部搜索结果逐首读改写歌单，形成 O(n²) | 使用 `addManyToPlaylist` 一次读改写；批量入队一次性同步系统队列 | 500 首批量保存只发生一次歌单写入 |
| H14 | 高 | 大型分组搜索结果使用非 builder 列表，一次性构建所有子项 | 使用 `CustomScrollView + SliverList`；分组头和列表项懒加载 | 1000 条结果打开时首帧和滚动稳定 |
| H15 | 高 | 备份导入逐区写入，中途失败会留下半套数据 | 先完整解码、校验和构造临时数据，再批量提交；失败时恢复原状态 | 导入中途模拟异常，原资料库保持不变 |
| H16 | 中 | 账号歌单、凭据存在读改写并发竞态 | 对同一渠道/歌单增加异步互斥锁或操作队列；写入后再刷新缓存 | 并发添加、删除、导入不会互相覆盖 |
| H17 | 中 | 100ms 位置 Timer 在暂停和空闲时仍持续唤醒 | 播放时创建，暂停/停止/销毁时取消；定时器只服务必要组件 | 暂停播放后无持续位置轮询 |
| H18 | 中 | `resume_repository` 空队列和非法 index 存在 `clamp(0, -1)` 隐患 | 恢复前校验队列和索引，非法快照直接丢弃并记录可诊断错误 | 空快照、损坏快照、越界索引不崩溃 |
| H19 | 中 | UTF-16 代理对、超长 LRC、MQTT 缓冲存在边界性能问题 | 使用完整 Unicode 解码；LRC 用时间索引去重；MQTT 使用可消费缓冲区并限制包大小 | emoji 歌词、超长歌词和大包测试通过 |
| H20 | 中 | `coverPaletteProvider` family 没有生命周期回收 | 评估 `autoDispose`、限制缓存数量；页面退出后释放封面取色结果 | 长时间切歌后内存不持续增长 |
| H21 | 中 | 错误只输出 debug 日志，没有聚合诊断 | 增加脱敏环形日志；设置页支持导出；后续接入 Crashlytics/Sentry | 用户可导出不含凭据的诊断包 |
| H22 | 中 | `patch_inappwebview_gradle.sh` 依赖 BSD sed 并修改本机 pub cache | 使用可复现 dependency override 或已修复 fork，删除本机补丁流程 | Linux/macOS 干净环境构建结果一致 |

---

## 10. 存储专项方案

### 10.1 存储分层

| 数据类型 | 存储位置 | 生命周期 | 优化策略 |
|---|---|---|---|
| Cookie/Token/认证信息 | Keychain/Keystore/DPAPI | 长期 | 单渠道 Blob、白名单、原子写入、禁止同步 |
| 账号资料 | Hive `account_box` | 长期 | 版本化 JSON、损坏恢复、状态和凭据分离 |
| 收藏 | Hive `favorites_box` | 长期 | `sourceId:trackId` 作为 Key，O(1) 查询，批量写入 |
| 播放历史 | Hive `history_box` | 200 条 | 时间戳 Key、有序裁剪、删除旧重复记录 |
| 歌单 | Hive 或后续 SQLite | 长期 | 短期批量写入，长期元数据和曲目拆表 |
| 网络封面 | 缓存目录 | 30 天/容量上限 | LRU 淘汰，最大 100 MB |
| 本地封面 | 临时/缓存目录 | 与文件关联 | 最大 256 MB，音乐文件删除时清理 |
| 诊断日志 | 环形文件 | 7 天 | 最大 5 MB，自动脱敏和轮转 |
| 用户备份 | 用户选择目录 | 用户控制 | 临时文件写入后原子 rename，不覆盖已有文件 |

### 10.2 凭据存储改造

将 `AccountRepository.saveCredentials` 改为以下流程：

```text
校验 sourceId 和字段白名单
→ 清理空白及非法控制字符
→ 生成完整版本化 Blob
→ 一次写入 secure storage
→ 更新内存缓存
→ 延迟删除旧格式字段
```

推荐键名：

```text
musaic.credentials.netease
musaic.credentials.qqmusic
musaic.credentials.kugou
musaic.credentials.ytm
```

不允许保存：

- WebView 中与 YTM 无关的 Cookie。
- 手机号密码明文。
- 完整 HTTP 请求头。
- 临时播放 URL。
- 不必要的设备标识。

### 10.3 Hive 和备份优化

1. 历史记录不再每次全表 JSON 解码、排序和删除。
2. 收藏、歌单导入统一使用 `putAll` 或批量方法。
3. 歌单操作按歌单名称加锁，避免读改写覆盖。
4. 大于 5 MB 的导出/导入任务放入 isolate。
5. 导入前校验 schema、字段类型、数量和字符串长度。
6. 导入使用临时快照，全部通过后才提交正式数据。
7. 所有数据增加 schema 版本，未来支持迁移而不是直接清空。
8. 启动遇到损坏 Box 时先备份原文件，再重建 Box 并显示恢复提示。

### 10.4 缓存预算

硬性预算建议如下：

```text
网络封面缓存：100 MB
本地封面缓存：256 MB
诊断日志：5 MB
临时备份文件：50 MB
单次 JSON 导入保护阈值：5 MB
```

新增 `StorageMaintenanceService`，在以下时机执行：

- 应用启动后的空闲阶段。
- 设备存储空间不足时。
- 用户进入设置页时。
- 用户点击「清理缓存」时。

清理必须支持：

```text
只清理缓存，不清理用户资料
清理本地封面
清理网络封面
清理诊断日志
显示清理前后空间变化
```

---

## 11. 内存专项方案

### 11.1 图片内存控制

统一限制 Flutter 图片缓存：

```dart
PaintingBinding.instance.imageCache.maximumSize = 300;
PaintingBinding.instance.imageCache.maximumSizeBytes = 100 * 1024 * 1024;
```

建议解码尺寸：

| 使用场景 | `memCacheWidth` |
|---|---:|
| 搜索列表 | 128 |
| 最近播放卡片 | 264 |
| MiniPlayer | 192 |
| 播放器封面 | 512 |
| 系统媒体封面 | 512 以下 |

`Track` 只保存封面 URI，不保存原始图片字节；ID3 解析完成后立即释放临时 `Uint8List`。

### 11.2 Provider 生命周期

以下临时 Provider 应优先评估 `autoDispose`：

- `coverPaletteProvider`。
- `lyricsProvider`。
- 单次搜索状态。
- 远程歌单加载状态。
- 二维码登录会话。

歌词和取色缓存应设置数量或时间上限，不能因为 family 参数不同而无限累积。

### 11.3 本地扫描内存模型

本地扫描采用分批流水线：

```text
目录遍历
→ 路径队列
→ 4 路解析
→ 每 50～100 首回传一次
→ 释放标签和封面字节
→ 更新索引
```

禁止：

- 一次性把整个目录所有原始文件读入内存。
- 在 `Track` 中保留封面原始字节。
- 对同一个文件重复读取标签。
- 无上限递归扫描用户误选的根目录。

### 11.4 播放器内存模型

将 `PlayerPage` 拆分为：

```text
PlayerBackground
PlayerCover
PlayerProgress
PlayerControls
LyricsPanel
QueueButton
SleepTimerButton
```

每个组件只监听自己需要的状态字段。背景、封面、歌词列表和控制区之间使用 `RepaintBoundary` 隔离，避免 position 更新引起整页重绘。

目标：连续播放 30 分钟后内存不持续线性增长，普通播放场景保持在 150 MB 以内。

---

## 12. 软件流畅度专项方案

### 12.1 启动阶段

启动流程改为：

```text
绑定 Flutter
→ 初始化最小依赖
→ runApp 显示首页
→ 首帧后打开普通 Hive Box
→ 后台恢复账号状态
→ 首次播放时初始化 AudioService
→ 播放前或首次需要时请求通知权限
```

启动阶段禁止执行：

- 通知权限弹窗。
- 本地音乐扫描。
- 所有渠道网络校验。
- 大型备份解码。
- 播放器背景取色。

### 12.2 帧刷新策略

| 模块 | 目标刷新频率 | 监听方式 |
|---|---:|---|
| 进度条 | 100 ms | 只监听 position/buffered/duration |
| 当前词高亮 | 50～100 ms | 只刷新当前歌词行 |
| MiniPlayer | 250 ms | 独立节流 |
| 背景和封面 | 切歌时 | 只监听 current |
| 播放按钮 | 状态改变时 | 只监听 playing |
| 队列按钮 | 队列改变时 | 只监听 queue.length |
| 历史/收藏列表 | 数据变化时 | Hive 事件流 |

### 12.3 列表和搜索

- 所有长列表使用 `ListView.builder` 或 `SliverList`。
- 分组搜索结果改用 Sliver 懒加载。
- 渠道搜索先到先显示，不等待最慢渠道。
- 新搜索取消旧搜索请求。
- QQ 封面详情请求最多 3～4 路并发。
- 列表项不重复解码 JSON，不在 `build` 内发网络请求。

### 12.4 动画和模糊

- 每个页面最多一个实时 `BackdropFilter`。
- 播放器背景使用低分辨率图或静态模糊图。
- 低端设备关闭玻璃和复杂背景动画。
- 尊重 `AccessibilityFeatures.disableAnimations`。
- 背景、封面和歌词分别放在独立重绘边界内。
- 页面销毁时取消所有动画、定时器和网络订阅。

### 12.5 性能工具

每次专项优化至少记录：

```text
flutter run --profile
Flutter DevTools Timeline
Flutter DevTools Memory
FrameTiming
冷启动 trace
1000 首本地曲库扫描 trace
播放 30 分钟内存曲线
```

---

## 13. 重新调整后的里程碑

### M0：保护和基线，1～2 天

- 提交所有核心源码和测试。
- 恢复最小 CI。
- 修复 Release 签名配置。
- 建立 analyze/test/build 基线。
- 记录当前启动、播放、内存和缓存数据。

### M1：安全与核心正确性，3～5 天

- H3 队列索引。
- H4 日志脱敏。
- H5 Cookie 白名单。
- H6 酷狗 HTTPS 和凭据传递。
- H7 YTM 会话校验。
- H8 Hive 启动容错。
- 完成 PlayerNotifier、AudioHandler、Interceptor 测试。

### M2：存储、内存和扫描，1 周

- 凭据 Blob 和迁移。
- 历史索引和歌单批量写入。
- 备份临时提交和大文件 isolate。
- 封面缓存上限和清理。
- 本地扫描 isolate、进度、取消和增量索引。
- 图片缓存和 Provider 生命周期治理。

### M3：搜索和界面流畅度，1 周

- 搜索流式返回、分页和重试。
- PlayerPage 精确监听。
- 歌词局部重绘。
- Sliver 长列表。
- 取消空闲位置 Timer。
- 优化动画和模糊区域。

### M4：产品功能扩展

只有 M0～M3 的出口标准全部通过后，再继续：

- YTM 字幕歌词。
- QQ 账号歌单。
- WebDAV 同步。
- 诊断日志导出。
- 自定义渠道插件。

### 13.1 最终出口标准

- `flutter analyze` 零问题。
- `flutter test` 稳定通过。
- CI 可在干净环境通过。
- Android Release 使用正式签名。
- 冷启动首帧小于 1 秒。
- 点歌到出声 p50 小于 800ms。
- 1000 首本地音乐扫描不阻塞 UI。
- 500 首收藏和 1000 条搜索结果滚动无明显卡顿。
- 播放 30 分钟内存不持续增长，目标小于 150 MB。
- 网络封面缓存不超过 100 MB，本地封面缓存不超过 256 MB。
- 日志不包含 Cookie、Token、Authorization 或完整播放 URL。
- Android、iOS、macOS、Windows 至少完成核心播放回归。

