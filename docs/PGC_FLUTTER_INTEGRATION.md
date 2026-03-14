# PGC 在 Flutter 端的展示与播放集成方案

本文档基于**后端 PGC API** 与 **pili_plus 参考项目**的展示方式，说明如何在 alnitak_flutter 中：首页与推荐等场景加载并展示 PGC 内容、封面右下角显示类型标签（番剧/纪录片/电影/电视剧）、点击进入 PGC 详情并播放。

---

## 1. 后端 PGC API 摘要

**基础路径**: `/api/v1/pgc`

| 能力 | 方法 | 路径/参数 | 说明 |
|------|------|-----------|------|
| 列表（分页） | GET | `list?page=1&page_size=20&pgc_type=&status=&keyword=` | 审核通过的内容，用于首页/分区 |
| 详情 | GET | `detail?pgc_id=xxx` | 单条元数据 |
| 详情+剧集 | GET | `detail-with-episodes?pgc_id=xxx` | 进入 PGC 详情页时使用 |
| 推荐 | GET | `recommended?limit=10` | 首页/推荐位混排 |
| 搜索 | GET | `search?keyword=&pgc_type=&page=&page_size=` | 搜索页 |
| 按类型 | GET | `type/:type?page=&page_size=` | 番剧/纪录片等分区 |
| 剧集列表 | GET | `/:pgc_id/episodes?page=&page_size=` | 剧集列表 |

**PGC 类型 (pgc_type)**  
- `1`: 番剧  
- `2`: 纪录片  
- `3`: 电影  
- `4`: 电视剧  

**列表/详情返回字段（需与后端确认 JSON 命名：snake_case 或 PascalCase）**  
- `pgc_id` / `PGCID`  
- `pgc_type` / `PGCType`  
- `title` / `Title`  
- `cover` / `Cover`  
- `desc` / `Desc`  
- `year`, `area`, `rating`, `is_ongoing`  
- `total_episodes`, `current_episodes`  
- `status`  

**详情+剧集** 返回 `pgc` + `episodes`。剧集含：`id`, `pgc_id`, `episode_number`, `title`, `vid`, `duration`, `publish_time` 等。

---

## 2. pili_plus 参考要点

- **封面角标**  
  - `VideoCardH`：类型/合作等用 `PBadge` 放在封面 **右上角**（`top: 6, right: 6`），如 `item.pgcLabel`（番剧/电影/纪录片等）。  
  - 时长在 **右下角**（`bottom: 6, right: 6`），`PBadgeType.gray`。  
- **本产品约定**：需求为「封面**右下角**显示番剧/纪录片等」，可采用：右下角**左侧**为类型标签、**右侧**为时长（或「共 n 集」），或类型与时长同一行靠右排列（类型在左、时长在右）。  
- **点击行为**  
  - pili_plus：PGC 走 `PageUtils.viewPgc` → 番剧详情页，再选集播放。  
  - 本端：点击 PGC 卡片 → 进入 **PGC 详情/选集页** → 选择剧集 → 使用现有 `VideoPlayPage(vid: episodeVid)` 播放该集。

---

## 3. Flutter 端数据与模型

### 3.1 PGC 模型

- **PgcItem**（列表/推荐用）：`pgcId`, `pgcType`, `title`, `cover`, `desc`, `year`, `area`, `rating`, `isOngoing`, `totalEpisodes`, `currentEpisodes`；并可从首集或接口取得 `duration` 用于卡片展示。  
- **PgcDetail**（详情页）：在 PgcItem 基础上增加 `episodes: List<PgcEpisode>`。  
- **PgcEpisode**：`id`, `pgcId`, `episodeNumber`, `title`, `vid`, `duration`, `publishTime`。

### 3.2 类型标签文案

- `pgcType == 1` → 番剧  
- `pgcType == 2` → 纪录片  
- `pgcType == 3` → 电影  
- `pgcType == 4` → 电视剧  

---

## 4. 首页展示与混排

- **数据来源**  
  - 现有：`VideoApiService.getVideoByPartition(partitionId, page, pageSize)` → `List<VideoItem>`。  
  - 新增：`PgcApiService.getRecommendedPgc(limit)` 或 `getPgcList(page, pageSize)`，得到 `List<PgcItem>`。  

- **展示策略（二选一或组合）**  
  - **方案 A**：首页顶部/中部增加「PGC 推荐」区块（横向或网格），仅展示 PGC 卡片；下方为原有分区视频列表。  
  - **方案 B**：与普通稿件混排进同一流：构造统一列表（如 `FeedItem` 枚举：`video(VideoItem)` | `pgc(PgcItem)`），按后端或本地规则穿插；列表项根据类型渲染 `VideoCard` 或 `PgcCard`。  

- **卡片**  
  - 复用或扩展 **VideoCard**：  
    - 增加可选参数 `String? pgcTypeLabel`（或 `int? pgcType` 内部转文案）。  
    - 封面右下角：若有 `pgcTypeLabel`，显示类型标签（小角标）；右侧或同一行显示时长或「共 n 集」。  
  - 或单独 **PgcCard**：与 VideoCard 视觉统一，封面+标题+统计，右下角固定为类型标签 + 集数/时长。  

- **点击**  
  - 普通稿件：保持 `_showVideoDetail(context, video)` → `VideoPlayPage(vid)`。  
  - PGC：`_showPgcDetail(context, pgcItem)` → 打开 **PGC 详情/选集页**，选集后跳转 `VideoPlayPage(vid: episode.vid)`。

---

## 5. 其他场景的推荐列表

- **播放页「相关推荐」**  
  - 当前：`VideoService.getRecommendedVideos(vid)` → 仅普通视频。  
  - 扩展：后端若支持「推荐列表含 PGC」，则推荐列表项可为视频或 PGC；卡片统一带 `pgcTypeLabel`，PGC 项点击进入 PGC 详情页再播放。  
  - 若后端暂不混排：可仅前端在推荐列表下方增加「PGC 推荐」区块，调用 `GET /api/v1/pgc/recommended?limit=5`，同上展示与跳转。  

- **搜索页**  
  - 搜索接口若返回 PGC，结果列表同样用带类型标签的卡片，PGC 点击进详情页。  

- **分区/分类页**  
  - 若有「番剧/纪录片」等分区，直接调用 `GET /api/v1/pgc/type/:type`，列表全部用 PGC 卡片 + 右下角类型标签。

---

## 6. PGC 详情/选集页（新页）

- **路由**：如 `PgcDetailPage(pgcId)` 或由 `pgc_id` 打开。  
- **数据**：`GET /api/v1/pgc/detail-with-episodes?pgc_id=xxx` → 展示简介、封面、标题、评分、集数等 + 剧集列表。  
- **剧集列表**：每行：序号/标题、时长、可选的播放进度；点击某一集 → `Navigator.push(VideoPlayPage(vid: episode.vid))`，与现有播放页一致。  
- **可选**：支持「从第 n 集续播」（结合本地或后端历史进度）。

---

## 7. 接口层（Flutter）

- **PgcApiService**（新建）  
  - `getPgcList({page, pageSize, pgcType, keyword})` → 对应 `list` 或 `search`。  
  - `getRecommendedPgc(limit)` → `recommended`。  
  - `getPgcDetailWithEpisodes(pgcId)` → `detail-with-episodes`。  
  - 使用现有 `HttpClient().dio`，统一 baseUrl；若需鉴权则与现有方式一致。  

- **响应解析**：根据后端实际 JSON（snake_case / PascalCase）在 `fromJson` 中做字段映射或统一别名。

---

## 8. UI 组件小结

| 组件 | 变更/新增 | 说明 |
|------|------------|------|
| VideoCard | 扩展 | 增加可选 `pgcTypeLabel`（或 `pgcType`），封面右下角展示类型标签；PGC 时可选显示「共 n 集」或首集时长。 |
| PgcCard | 可选 | 若与 VideoCard 差异大，可单独组件，视觉与 VideoCard 统一，右下角固定类型+集数。 |
| 首页 | 扩展 | 拉取 PGC 列表/推荐，与视频混排或独立区块；点击 PGC → PgcDetailPage。 |
| RecommendList | 扩展 | 支持项为 PGC 时展示类型标签，点击 → PgcDetailPage。 |
| PgcDetailPage | 新增 | 展示 PGC 信息 + 剧集列表，选集 → VideoPlayPage(vid)。 |

---

## 9. 实现顺序建议

1. **PgcItem / PgcEpisode / PgcDetail** 模型 + **PgcApiService**（list、recommended、detail-with-episodes）。  
2. **VideoCard** 增加 `pgcTypeLabel`（及可选集数/时长），封面右下角类型标签。  
3. **首页**：接入 PGC 推荐或列表，展示 PGC 卡片并实现点击 → PgcDetailPage。  
4. **PgcDetailPage**：剧集列表 + 选集跳转 VideoPlayPage。  
5. **推荐列表/搜索/分区**：按需接入 PGC 数据与同一套卡片、跳转逻辑。

---

*文档版本：初版。实现时以实际后端 JSON 与产品交互为准。*
