# Musaic 架构演进设计（v1.0）

> 日期：2026-09-12 ｜ 前置：`945866e`（P0/P1 修复 + CI + 架构守护已落地）
> 定位：本文档回答一个问题——**Musaic 下一个结构性瓶颈是什么，以及为什么它必须现在解决**。
> 不重复 `musaic-iteration-plan.md` 的排期，只做设计决策与落地边界。

---

## 0. 结论先行

上一轮把「承诺兑现」补齐了：P0/P1 缺陷清零、266 测试、CI 与架构守护到位。
功能清单上剩下的（WebDAV、自定义渠道、桌面三栏、均衡器）都是**可选的增量**。

但我在勘验时发现一个**已经存在、且会随功能增加而指数恶化**的结构问题：

> **Musaic 没有「同一首歌」的概念。** 它只有「某渠道的某条记录」。
> 跨渠道的一切能力——聚合、回退、同步、去重——都因此只能停在演示级别。

这不是缺一个功能，是缺一层模型。补它越晚，代价越高（`track.key` 现已被 104 处引用）。

**本设计的核心是一个新层：`Work`（作品）+ `WorkId`（作品身份）。**
另附三套被同一根因牵连的基建：统一缓存层、存储 schema 版本化、本地曲目稳定 id。

---

## 1. 问题诊断（全部基于代码证据，非推测）

### 1.1 同一性缺失：`Track.key = "$sourceId:$id"` 把「记录」当成了「作品」

`lib/core/model/track.dart:53`：

```dart
String get key => '$sourceId:$id';
```

这个 key 承担了**两种互相冲突的职责**：

| 职责 | 需要什么 | 现状 |
|---|---|---|
| 定位播放地址 | 渠道 + 该渠道的记录 id | ✅ 合适 |
| 标识「同一首歌」 | 跨渠道稳定的作品身份 | ❌ 做不到 |

**后果一：收藏/历史按渠道分裂。** 同一首歌从网易云收藏、从 QQ 播放，是两条互不相干的记录。
换渠道听同一首歌，红心不亮、历史各记一笔。

**后果二：跨渠道播放回退无法实现。** 网易云没版权时，我们**已经在搜索结果里持有 QQ 的同曲记录**，
却没有语言表达「这两条是同一首歌」，于是只能报错。

`lib/features/player/player_notifier.dart:581` 只解析单一渠道：

```dart
final source = registry.resolve(track.sourceId);
```

**后果三：「合并视图」名不副实。** `search_results_page.dart:161` 的 `_applySort` 只是把各渠道
结果 `addAll` 后按用户选的字段排序——是**列表拼接**，不是合并。同一首歌会在结果里出现 4 次。

**后果四：同步与去重都没有基准。** WebDAV 同步（V1.3）一旦落地，用户两台设备分别用不同渠道收藏，
同步后会得到一堆重复条目——因为去重键是渠道相关的。

### 1.2 本地曲目的身份不稳定：`id = 绝对路径`

`lib/sources/local/local_file_source.dart:391`：

```dart
id: path,
```

**后果：** macOS/iOS 容器路径变化、用户移动音乐目录、重命名文件夹——收藏与歌单**静默失效**。
而移动文件、整理目录恰恰是本地曲库用户的常态操作。

### 1.3 无缓存层，渠道调用完全重复

全库**没有任何缓存抽象**：

- 歌词：`lyrics_provider.dart` 是 `autoDispose.family`，**每次进播放页都重新请求**。离线/弱网无歌词。
- 封面：仅依赖 `cached_network_image` 的磁盘缓存，无容量上限、无淘汰策略、无统计。
  `iteration-plan` 承诺的「网络封面 100MB / 本地封面 256MB」**无实现**。
- 详情：`getTrackDetail` 每次调用都打网络。

**后果：** 重复流量、弱网体验差、承诺的缓存预算无着落。四渠道各自实现缓存必然漂移，
所以这必须是**一层基建**，不是四个渠道的私事。

### 1.4 存储无 schema 版本，只有备份有

`backup_service.dart` 有 `schema: 1` 与版本拒绝逻辑——做得对。
但**Hive 本地存储没有**：`app_settings`、`musaic_favorites`、`musaic_history`、
`musaic_playlists`、`musaic_search_history`、`local_music_settings`、`musaic_resume`
七个 Box，全部裸存、无版本号、无迁移钩子。

设置项用 `box.get(key) == 'true'` 这类**弱类型字符串约定**（`settings_providers.dart:32` 起）。
**后果：** 一旦要改字段语义（本设计就要改收藏的存储格式），只能靠「读不出来就回默认」——
用户数据静默丢失，且无法写迁移。

### 1.5 存储模式不一致

| 数据 | 模式 | 位置 |
|---|---|---|
| 收藏 / 历史 / 歌单 | 每曲一键，`jsonEncode(Track)` | `library_repository.dart` |
| 搜索历史 | **单键 JSON 数组**，上限 15 | `search_history_repository.dart:9` |
| 断点续播 | 单键 JSON | `resume_repository.dart:63` |

搜索历史用单键数组，意味着每次 `add` 都是**全量读改写**；上限 15 时无感，
但它示范了一种会随规模失控的模式。**后果：** 新功能各自选模式，长期无法统一维护与迁移。

### 1.6 次要但相关的观测

- 历史裁剪是**全表 `jsonDecode` + 排序**（`library_repository.dart:130-140`），200 条尚可，长期是 O(n) 每次写。
- 模型层只有 `Track` / `RemotePlaylist`，**无 Artist / Album 实体**——所以「艺人/专辑视图」不是加页面，是加模型。
- 无 i18n、无离线/下载概念、无代理设置。这些是**真增量**，本设计不处理（见 §7）。

---

## 2. 设计：`Work` 同一性层

### 2.1 领域模型

新增 `lib/core/model/work.dart`：

```dart
/// 作品身份：跨渠道稳定，不随渠道/记录变化。
@immutable
class WorkId implements Comparable<WorkId> {
  const WorkId({required this.normalizedTitle, required this.normalizedArtist});

  final String normalizedTitle;
  final String normalizedArtist;

  /// 强标识（首选）：渠道提供的 ISRC / 官方 id 映射，存在时直接用。
  const WorkId.fromIsrc(this.normalizedTitle, this.normalizedArtist, String isrc);
  ...
}

/// 一个作品在某渠道下的一条可播放记录。
@immutable
class WorkSource {
  const WorkSource({required this.track, this.isPreferred = false, this.quality});
  final Track track;   // 渠道记录（定位播放地址的唯一依据）
  ...
}

/// 作品：同一首歌在多个渠道的记录集合 + 归一化元数据。
@immutable
class Work {
  const Work({required this.id, required this.title, required this.artist,
              required this.sources, this.album, this.duration, this.coverUrl});
  final WorkId id;
  final List<WorkSource> sources;
  ...
  /// 按偏好顺序挑选可播放记录（回退链的候选序列）。
  List<Track> get playCandidates;
}
```

**关键设计决策：不替换 `Track`，而是叠加一层。**

`track.key` 保持原语义（渠道记录身份），继续用于定位播放地址与渠道内去重；
`WorkId` 只用于**跨渠道聚合**。这样 104 处 `track.key` 引用**零改动**。

这是本设计最重要的取舍：**新建一层，而不是改一层**。

### 2.2 `WorkId` 归一化规则

> **已原型验证**（`lib/core/model/work_id.dart` + `test/core/model/work_id_test.dart`，26 用例全绿）。
> 设计假设不是纸面推演：归一化器已实现并针对四渠道真实命名习惯通过测试，
> 含对抗性「不得合并」用例。验证过程还抓出一个真实顺序 bug——
> `feat.` 若在切分**之前**当噪声删除，`A feat. B` 会粘成 `ab` 而与 `A/B` 不等价；
> 正确顺序是**先按分隔符切分、再逐段清洗**。

归一化必须可单测、可解释、可回滚。规则（`core/model/work_id.dart`）：

1. **优先强标识**：渠道返回 ISRC 时直接用（网易云/QQ 详情接口可得）。
2. **回退归一化键**：
   - 标题：转小写、去首尾空白、去括号内修饰（`(Live)` `【伴奏】` `feat.` 之后内容）、
     全角转半角、去除空白与常见标点。
   - 艺人：同上；多艺人按 `/` `,` `&` `、` 切分后**排序**再拼接（解决渠道间艺人顺序不一致）。
3. **不可归一化时降级**：标题或艺人为空 → 退回 `fallbackKey`（如 `netease:123`），
   保证 `WorkId` 恒存在、永不抛异常。**关键**：不能因为都归一化成空就归为同一作品，
   否则所有无标签曲目会被合并成一首。
4. **ISRC 不对称时回退比较**：一边有 ISRC、一边无，**不能**判定为不同作品，
   而是回退到标题/艺人比较。这是实测中容易写错的一处（`isrc != null && other.isrc != null`
   才用 ISRC 比较）。

> **明确不做的**：不引入拼音/模糊匹配/编辑距离。那会带来误合并（把不同歌曲合成一首是
> 比不合并更糟的错误）。归一化必须是**确定性**的，宁可少合并，不可错合并。
>
> **修饰词白名单是刻意保守的**：只剥离明确的版本/规格标注（Live / Remastered / 伴奏 /
> Remix / feat. …）。「钢琴版」「(Part 1)」这类**不在白名单内**，因此不会被剥离，
> 也就不会被合并——用户不会因为归一化而听到非预期的版本。

### 2.3 回退链（本设计最大的用户可感知收益）

`PlayerNotifier` 增加候选序列，**只在「确定不可用」时前进**：

```dart
// player_notifier.dart 的 _loadAndPlay 内
for (final candidate in track.playCandidates) {
  try {
    resolved = await source.resolveStream(candidate);
    break;
  } on UnavailableStreamException {
    continue;   // 无版权 / 需会员 → 换下一渠道
  } on NetworkSourceException {
    rethrow;    // 网络问题换渠道没意义，直接报错
  }
}
```

**错误语义必须区分**（现已有正确的异常族，直接复用）：

| 异常 | 含义 | 是否回退 |
|---|---|---|
| `UnavailableStreamException` | 无版权 / 地区限制 / 需会员 | ✅ 前进 |
| `AuthRequiredException` | 未登录 | ✅ 前进（换匿名可用渠道） |
| `NetworkSourceException` | 断网 / 超时 | ❌ 不回退（换渠道同样失败，且会掩盖真实原因） |

**这个区分是设计的一部分，不是实现细节**：不区分就会「用户断网，播放器在 4 个渠道间空转 30 秒后报一个无关错误」。

**回退候选的来源**：搜索结果里同一 `WorkId` 的所有记录（已经拿在手里，零额外请求）。

### 2.4 收藏 / 历史的存储改造

存储键从 `track.key` 改为 `workId`，**记录体保留完整 Track 快照**（用于离线展示与快速恢复）：

```
musaic_favorites/<workId> → {
  "schema": 2,
  "work": { "title": ..., "artist": ..., "album": ... },
  "sources": [ { "track": {...Track...}, "addedAt": ... } ]
}
```

**收益：** 从网易云收藏的歌，在 QQ 播放时红心是亮的（§1.1 后果一消失）；
WebDAV 同步天然去重（§1.1 后果四消失）。

**这是破坏性存储变更**，必须配套 §3.2 的 schema 迁移，否则用户收藏全丢。

### 2.5 落点与影响面

| 文件 | 改动 |
|---|---|
| `core/model/work.dart` | 新增（Work / WorkId / WorkSource） |
| `core/model/work_id_normalizer.dart` | 新增（纯函数，重点单测对象） |
| `core/source/music_source.dart` | 新增可选 `Future<Work?> resolveWork(Track)` 能力（默认按 Track 构造单源 Work） |
| `features/search/**` | 合并视图改为按 WorkId 分组；新增「显示全部渠道版本」入口 |
| `features/library/data/library_repository.dart` | 键改 workId + schema v2 + 迁移 |
| `features/player/player_notifier.dart` | `_loadAndPlay` 接回退链 |

**迁移策略（灰度）：** 保留旧 Box 只读，首次启动迁移到新 Box，迁移完成写标记；
迁移失败则回退旧 Box 并上报日志（复用 `AppLog`），**绝不删除原始数据**。

---

## 3. 配套基建（与 §2 强耦合，需同批交付）

### 3.1 统一缓存层 `core/cache/`

**为什么是基建而非渠道私事**：歌词、详情、封面、搜索四个维度四渠道各写一遍必然漂移。

```dart
/// 两级缓存：内存 LRU + 磁盘（带容量上限与 LRU 淘汰）。
abstract class CacheStore<T> {
  Future<T?> get(String key);
  Future<void> put(String key, T value);
  Future<CacheStats> stats();
  Future<void> evictTo(double targetBytes);
  Future<void> clear();
}
```

落地顺序（按收益/成本）：
1. **歌词缓存**（收益最高：现在每次进播放页都重拉，且离线无歌词）→ 磁盘 + `workId` 为键。
2. **封面缓存预算**（兑现 iteration-plan 的 100MB/256MB 承诺）→ 接管 `cached_network_image` 的
   `CacheManager`，加 LRU 与统计。
3. **详情缓存**（短 TTL，避免重复 `getTrackDetail`）。
4. 搜索**不做缓存**（结果时效性强，且分页状态复杂，缓存收益低风险高）。

设置页「存储管理」展示分类占用 + 一键清理（`StorageMaintenanceService`）。

### 3.2 存储 schema 版本化 `core/storage/schema_migrator.dart`

```dart
/// 每个 Box 独立版本号，存于 Box 内的保留键 `__schema__`。
class SchemaMigrator {
  Future<void> migrate(Box<String> box, List<Migration> steps);
}
```

规则：
- 每个 Box 一个 `int` 版本，缺失视为 1（兼容现有数据）。
- 迁移步骤是**有序纯函数**，`v1→v2`、`v2→v3`，逐级执行。
- 迁移前**先备份原始内容**到 `musaic_migration_backup`，成功后保留一轮再清理。
- 迁移失败：**回滚并保持旧版本号**，应用以降级模式启动（只读），不静默丢数据。

**先做 §3.2 再做 §2.4** —— 否则收藏改造没有安全网。

### 3.3 本地曲目稳定 id

```dart
/// 优先内容指纹（文件大小 + 前 64KB 哈希 + 标签），路径仅作展示。
String localTrackId(String path, int size, String headHash) => 'local:$size:$headHash';
```

- 移动/重命名文件 → **收藏保持有效**（路径变化不影响 id）。
- 内容相同但路径不同 → 视为同一首（符合用户直觉）。
- 迁移：旧数据 id 是路径，需在 schema 迁移中按「路径仍存在 → 重算 id 并改键；
  路径不存在 → 保留原键并标记 `orphan`」（**不删**，用户可能只是外接盘没插）。

---

## 4. 为什么是现在（代价曲线）

| 时点 | `track.key` 引用数 | 迁移成本 |
|---|---|---|
| 现在 | 104 | 一次 schema 迁移 + 一层新模型 |
| 加完 WebDAV 后 | ~130 | 同步协议、冲突解决都要重做（去重键变了） |
| 加完自定义渠道后 | ~160 | 外部用户数据已在流通，**破坏性迁移不可接受** |

**关键判断：`WorkId` 是同步、去重、跨源回退三件事的共同前置。**
现在不做，这三件事每件都要各自造一套临时方案，且互相不兼容。

---

## 5. 交付顺序与验收

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **S1** | §3.2 schema 迁移框架 | 每个 Box 有版本号；迁移失败可回滚；单测覆盖 v1→v2 与失败回滚 |
| **S2** | §2.1–2.2 Work/WorkId + 归一化 | ✅ **归一化器已原型验证**（26 用例：跨渠道同曲合并 + 对抗性不合并）；待补 `Work` 聚合与渠道接入 |
| **S3** | §3.3 本地 id 稳定化 | 移动文件后收藏仍有效（单测模拟路径变化） |
| **S4** | §2.4 收藏/历史迁移到 workId | 迁移后旧收藏完整保留；跨渠道收藏点亮（集成验证） |
| **S5** | §2.3 回退链 | 无版权曲自动切下一渠道；断网**不**触发回退；单测覆盖两种异常 |
| **S6** | §3.1 缓存层（歌词 → 封面 → 详情） | 二次进播放页零网络请求；缓存占用可在设置页查看与清理 |

**每阶段独立可发布**，S1–S3 是 S4–S6 的前置。S5 依赖 S2，与 S4 可并行。

---

## 6. 设计自检（已知风险与对策）

| 风险 | 对策 |
|---|---|
| 归一化误合并不同歌曲 | 已用对抗性用例固化（序号 / 编曲 / 数字差异均不合并）；只做确定性规则；不做模糊匹配；`WorkId` 保留归一化字段便于排查；后续提供「拆开合并」入口 |
| 回退链让用户听到非预期版本 | 回退时**明确提示**「已切换到 XX 渠道」；设置项可关闭自动回退 |
| 迁移丢数据 | 迁移前备份；失败回滚；旧 Box 保留只读一轮；`AppLog` 记录全过程 |
| 一次改太多 | 六阶段各自可独立发布，S1 先行且不碰业务数据 |
| 本地 id 重算导致歌单错乱 | 迁移中同步改所有引用（收藏/歌单/历史/续播），单测覆盖引用一致性 |

---

## 7. 明确不做（本轮范围外）

这些是**真增量**，与本设计无耦合，避免范围蔓延：

- WebDAV 同步（**依赖 §2**，应在 S4 之后做）
- 自定义渠道 / 声明式源
- 艺人 / 专辑实体与浏览页（需新增模型，独立立项）
- 桌面三栏、均衡器、gapless、i18n、代理设置、离线下载
- 大列表 Sliver 懒加载、历史索引化（性能优化，独立且不阻塞）

---

## 8. 与现有文档的关系

- `musaic-master-plan.md`：产品总纲，本文档是其 §9（存储与同步）的技术前置。
- `musaic-iteration-plan.md`：排期与 Bug 表；本文档的 S1–S6 应回填为其新里程碑。
- `musaic-improvement-plan.md`：本文档承接其「文档漂移」教训——**所有结论均附代码位置证据**。
- `docs/benchmarks.md`：缓存层落地后需补「二次访问零请求」与「缓存占用」两项实测。
