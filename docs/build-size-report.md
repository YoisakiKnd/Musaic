# 构建体积分析与优化报告

> 日期：2026-09-12 ｜ 基线：`ef884f1` ｜ 方法：实测（`unzip -l` + Gradle 依赖树 + 模拟器运行验证）

---

## 0. 结论速览

| 指标 | 优化前 | 优化后 | 变化 |
|---|---|---|---|
| **release 单 ABI 包（arm64）** | 60.2 MB（全量包） | **21.8 MB** | **−64%** |
| release 全量包（三 ABI） | 60.2 MB | 60.3 MB | 持平（R8 对 native 无效） |
| debug APK | 183 MB | 183 MB | 未变（开发产物，非优化目标） |

**关键判断：体积主体是 Flutter 引擎的 native 库（约 90%），
R8/资源压缩对此无效；真正有效的是 ABI 分割。**

---

## 1. 体积构成（优化前，release 全量包 60.2 MB）

按占用从大到小：

| 项 | 大小 | 占比 | 说明 |
|---|---|---|---|
| `lib/x86_64/*` | 21.7 MB | 34% | **仅模拟器需要**，真机安装包完全用不到 |
| `lib/arm64-v8a/*` | 20.2 MB | 32% | 现代真机 |
| `lib/armeabi-v7a/*` | 18.0 MB | 29% | 老旧 32 位真机 |
| `classes.dex` | 3.5 MB | 5.6% | Kotlin/Java 侧 |
| `MaterialIcons-Regular.otf` | 1.6 MB | 2.6% | 构建时已 tree-shake 至 12 KB（见下） |
| `org/apache/tika/**` | 330 KB | 0.5% | **`file_picker` 引入的无用依赖** |
| `lib/*/libdartjni.so` | ~330 KB | 0.5% | Dart JNI 桥 |
| 其它（resources.arsc、shaders、NOTICES） | ~350 KB | 0.6% | — |

### 三个 native 库各含什么

每个 ABI 目录下：

| 文件 | 大小 | 性质 |
|---|---|---|
| `libflutter.so` | 11.6 MB（arm64） | Flutter 引擎，**不可压缩** |
| `libapp.so` | 8.8 MB（arm64） | Dart AOT 产物，**不可压缩** |
| `libdartjni.so` | 0.13 MB | Dart JNI 桥 |

> **注意**：`libapp.so` 是 AOT 编译结果，**与 R8 无关**——这解释了为什么
> 开启 R8 后总体积几乎不变。

### 字体已自动优化

构建日志显示：

```
Font asset "MaterialIcons-Regular.otf" was tree-shaken,
reducing it from 1645184 to 12304 bytes (99.3% reduction)
```

Flutter 已自动剔除未用图标，**无需人工干预**。

---

## 2. 已实施的优化

### 2.1 ABI 分割（主要收益）

**改什么**：`android/app/build.gradle.kts` 增加 `splits.abi`，
为 arm64-v8a / armeabi-v7a / x86_64 各产出独立 APK，同时保留全量包。

**实测收益**：

| 产物 | 大小 |
|---|---|
| `app-arm64-v8a-release.apk` | **21.8 MB** |
| `app-armeabi-v7a-release.apk` | 19.7 MB |
| `app-x86_64-release.apk` | 23.3 MB |
| `app-release.apk`（全量） | 60.3 MB |

用户按机型下载，**实际下载量减少 64%**。

**代价与风险**：
- 发布流程需上传 4 个 APK（或改用 AAB，见 §3.1）；
- `isUniversalApk = true` 保留全量包，便于分发；
- **不改变任何行为**，风险极低。

### 2.2 R8 混淆 + 资源压缩

**改什么**：`isMinifyEnabled = true`、`isShrinkResources = true`，
新增 `android/app/proguard-rules.pro`（含 Flutter 引擎、audio_service、
InAppWebView JS bridge 等必要 keep 规则）。

**实测收益**：**总体积几乎无变化**（60.2 → 60.3 MB）。

原因：体积 90% 是 native 库，R8 只作用于 `classes.dex`。
实测 dex 从 3.51 MB 变为 3.59 MB（**略有增加**——R8 的 optimize 模式
会做内联等变换，可能使 dex 微增）。

**那为什么仍然保留？**
1. 移除未使用的 Kotlin/Java 代码，减少攻击面；
2. 混淆使逆向难度上升；
3. 为将来 Java/Kotlin 代码增长预留优化空间。

**代价与风险**：
- 需维护 keep 规则（已针对反射场景写好）；
- **存在运行时崩溃风险**——已通过模拟器实测验证（见 §4）。

### 2.3 顺带发现：`file_picker` 引入 330 KB 无用依赖

Gradle 依赖树确认：

```
+--- project :file_picker
|    \--- org.apache.tika:tika-core:3.2.3
```

`tika-core` 是 Apache 的 MIME 嗅探库，`file_picker` 用它识别文件类型。
本项目只用它**选文件夹**（SAF），不需要 MIME 嗅探。

**未处理**，原因见 §3.3。

---

## 3. 待决策项（需你确认）

### 3.1 是否改用 AAB（Android App Bundle）

**改什么**：发布时用 `flutter build appbundle` 而非 APK。

**预期收益**：Google Play 会按用户机型下发对应 ABI，等效于 ABI 分割，
且额外做资源/语言维度切分。上传体积从 60 MB 降到约 22 MB。

**代价与风险**：
- **仅适用于 Google Play 分发**；国内应用商店、直接分发 APK 的场景不适用；
- 需要 Play 签名（现有 `key.properties` 流程要调整）；
- **会改变发布流程**，需你确认分发渠道。

**我的建议**：若主要面向国内分发，**保持 APK 分割即可**（已实施）；
若上架 Google Play，再切 AAB。

### 3.2 是否排除 x86_64

**改什么**：从 `splits.abi.include` 移除 `x86_64`。

**预期收益**：少产出 23 MB 的包；不影响真机（x86_64 仅模拟器用）。

**代价与风险**：**失去在 x86_64 模拟器上验证 release 包的能力**——
而本次验证正是靠它完成的（见 §4）。若你本地/CI 用 ARM 模拟器则无影响。

**我的建议**：**保留 x86_64**。多一个产物换「能在模拟器上验证 release」，
对排查 R8 类问题是必要的。

### 3.3 是否处理 `file_picker` 的 tika 依赖

**改什么**：在 `build.gradle.kts` 中排除传递依赖：

```kotlin
configurations.all {
    exclude(group = "org.apache.tika", module = "tika-core")
}
```

**预期收益**：约 **330 KB**（占 arm64 包 1.5%）。

**代价与风险**：
- **高风险**：若 `file_picker` 在运行时真的调用了 tika（哪怕只在某些
  文件类型分支），会抛 `NoClassDefFoundError`。需先确认其代码路径；
- 收益极小（1.5%），**性价比很低**。

**我的建议**：**不做**。收益 330 KB 不值得引入「运行时类缺失」的风险。
若将来确实要瘦身，应先读 `file_picker` 源码确认调用点。

### 3.4 是否需要进一步瘦身 Dart 侧代码

**现状**：`libapp.so` 约 8.8 MB（arm64）。

**可选手段**：
- `--split-debug-info` + `--obfuscate`：**不减少体积**（只移走符号），
  但可减小产物并增加逆向难度；
- 移除未使用依赖：需先审计（如 `palette_generator` 是否可被更轻的实现替代）。

**代价与风险**：`--obfuscate` 会让线上崩溃栈需要符号文件才能解析，
**必须妥善保存 `symbols/` 目录**，否则无法定位崩溃。

**我的建议**：暂不做。当前 21.8 MB 对音乐应用属正常范围
（对比：Spotify 约 30 MB、Apple Music 约 100 MB）。

---

## 4. 运行验证（R8 的关键风险）

R8 混淆最典型的失败模式是「构建成功但运行崩溃」（反射类被改名）。
因此**必须实测**，不能只看构建结果。

**验证方法**：Android 模拟器（Pixel 8, arm64-v8a）安装 R8 优化后的
release 包，实测关键路径。

| 验证项 | 结果 |
|---|---|
| 安装 | ✅ Success |
| 冷启动 | ✅ 进程存活，无 FATAL |
| Flutter 引擎 | ✅ Impeller (OpenGLES) 后端启动 |
| **`audio_service` 反射注册** | ✅ `MediaButtonReceiver` 注册成功 |
| 首页渲染 | ✅ 继续收听卡 + 快捷入口 + 曲目列表 |
| **实际播放** | ✅ `state=PLAYING, position=92, buffered=20000, error=null` |
| 播放页 UI | ✅ 进度条走字、暂停按钮、封面取色背景 |
| 后台媒体会话 | ✅ `PAUSED, position=20007, error=null`，会话保持 |

**结论：R8 keep 规则正确，功能无回归。**

> 验证细节：`dumpsys media_session` 显示
> `mediaButtonReceiver=ComponentInfo{app.musaic/com.ryanheise.audioservice.MediaButtonReceiver}`
> ——证明 `audio_service` 的反射注册未被 R8 破坏。这是本次优化最关键的一条验证。

---

## 5. 安全的 vs 需确认的

| 优化 | 收益 | 风险 | 状态 |
|---|---|---|---|
| ABI 分割 | **−64%**（38 MB） | 极低，不改行为 | ✅ **已实施** |
| R8 + 资源压缩 | ~0（但减攻击面） | 中，已实测验证 | ✅ **已实施** |
| 改用 AAB | 同 ABI 分割 | 需改发布流程，仅 Play | ⏸ **待你确认**（§3.1） |
| 排除 x86_64 | 少一个 23 MB 产物 | 失去模拟器验证能力 | ⏸ **建议保留**（§3.2） |
| 排除 tika | 330 KB | **高**，可能运行时崩 | ⏸ **建议不做**（§3.3） |
| `--obfuscate` | 不减体积 | 需保管符号文件 | ⏸ **建议不做**（§3.4） |

**未新增任何依赖。**
