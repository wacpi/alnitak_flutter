# 稿件 ID & 资源 ID 学 YouTube：统一不透明 ID 方案（方案 B）

本文设计 **视频稿件（video）/ 专栏稿件（article）/ 资源（resource）** 的 ID 方案，全部参考 YouTube 的做法：

- **内部**使用 Snowflake（uint64）作为唯一数字 ID；
- **对外**只暴露 **11 位短字符串 ID**，字符集为 `A–Z a–z 0–9 - _`。

当前阶段仅为**设计与约定**，不直接改后端代码和数据库。

---

## 1. 现状简要回顾

- **Video**：`model.Video` 继承 `gorm.Model`，主键 `ID uint` 自增；对外接口及大量关联（评论、收藏、点赞、历史、弹幕、resource.vid 等）都用该自增 ID 作为 `vid`。
- **Article**：同样使用 `gorm.Model` 自增主键 `ID`，对外作为 `aid`。
- **Resource**：`model.Resource` 也用 `gorm.Model` 自增主键 `ID`，对外在播放 URL 中以 `resourceId` 形式暴露（如 `/api/v1/video/getVideoFile?resourceId=xxx`）。
- **PGC**：已经用 `global.SnowflakeNode.Generate()` 生成 `pgc_id`，不再暴露简单自增序列。

问题：自增 ID 容易被枚举、推测总量和插入顺序，也不够“平台感”。

---

## 2. 目标：统一的 YouTube 风格 ID

### 2.1 内部 ID

- **VideoID / ArticleID / ResourceID**：统一采用 **Snowflake uint64**（或兼容 PG C 已使用的 `global.SnowflakeNode`），作为数据库主键或核心业务 ID。
- Snowflake 只在服务端内部使用，不直接向客户端暴露。

### 2.2 外部 ID（对客户端）

- 对外只暴露 **11 位短字符串 ID**，记为：
  - 视频：`vid`（字符串）；  
  - 专栏：`aid`（字符串）；  
  - 资源：`rid` 或继续叫 `resourceId` 但类型为字符串。
- 字符集：与 YouTube 一致的 64 个字符：
  - `A–Z` / `a–z` / `0–9` / `-` / `_`。
- 11 位的 64 进制可支持约 7.5×10^19 个 ID，足够全局使用。

### 2.3 编码/解码规则（可逆）

1. 生成 Snowflake 数字 ID（uint64）：`id := global.SnowflakeNode.Generate().Int64()`。
2. 将该 64 位整数使用固定 64 字符表编码为 **11 位字符串**：
   - 视为 64 进制（Base64-like），循环 `id % 64` 取余构造字符；
   - 使用自定义字符表：`ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_`；
   - 高位不足时左侧补 `A`（或其他固定字符），保证长度固定 11。
3. 解码时反向操作：遍历 11 位字符串，将每一位映射回数字 0–63，累积为 uint64。

> 设计上应保证：编码、解码在不查库的情况下也能互相还原（与 YouTube 思路类似）。

---

## 3. 模型/库表改造方案（逻辑设计）

> 本节描述的是目标结构，真实迁移时可视情况分步执行。

### 3.1 视频与专栏

- **Video 表**
  - 将主键从自增 ID 改为 Snowflake：`ID uint64`；
  - 新增或重命名对外 ID 字段：`VidStr varchar(16)`（唯一索引），用于保存 11 位字符串；
  - 现有与 Video 关联的表（resource、history、danmaku、like_video、collect_video、pgc_episode 等）的 `Vid` 字段类型全部改为 `uint64`，并与新主键保持一致。

- **Article 表**
  - 同理，主键 `ID` 改为 Snowflake `uint64`；
  - 新增 `AidStr varchar(16)`（唯一索引），对外展示与传参都用这个字符串。

### 3.2 Resource 表

- **Resource 表**
  - 主键 `ID` 改为 Snowflake `uint64`；
  - 新增 `RidStr varchar(16)`（或统一叫 `ResourceIdStr`，唯一索引），对应外部 `resourceId` 字符串；
  - 字段 `Vid` 改为 `uint64`，与 Video 的 Snowflake 主键对应。

### 3.3 其他关联表

- **History / Danmaku / LikeVideo / CollectVideo / PgcEpisode / Comment(type=视频部分的 Cid) / PlaylistVideo / AtMessage / MsgLike / MsgReply 等**：
  - 所有把“稿件视频 ID”当作 `uint` 自增 ID 存储的字段，都统一迁移至 Snowflake `uint64`。
  - 逻辑上只要保持「所有引用 video 的地方都用同一个 Snowflake ID」即可。

---

## 4. API 与 URL 层的约定

### 4.1 对外参数

- 播放 / 详情 / 点赞 / 收藏 / 历史 / 弹幕 / 资源文件等接口：
  - 原先：`vid=123`、`aid=45`、`resourceId=678`（数字）；
  - 目标：`vid=AbC123xYz-_`、`aid=...`、`resourceId=...`（11 位字符串）。
- 前后端约定：
  - 所有新版本客户端只使用字符串 ID；
  - 后端在 Gateway/Handler 的**入口第一步**负责把字符串解析为 Snowflake 数字 ID。

### 4.2 对外响应

- 列表、详情、推荐等返回中：
  - 对外仅返回 `vid` / `aid` / `resourceId` 字段（字符串）；
  - 不再返回内部的数字主键，或若保留则标为内部字段不建议前端使用。

---

## 5. 迁移思路（当前约 30 条稿件的小规模场景）

> 由于当前数据量很小（稿件在 30 条以内），完全可以在维护时间内完成一次性迁移。

大致步骤（在合适的维护窗口执行）：

1. **准备期**
   - 在代码中实现：  
     - Snowflake 生成工具（已存在 `global.SnowflakeNode`）；  
     - `uint64 ↔ 11 位字符串` 的编码/解码函数，并写好单元测试。
   - 在数据库中为 video/article/resource 增加字符串 ID 列（`vid_str` / `aid_str` / `rid_str`），先不动主键。

2. **生成新 ID 与字符串**
   - 对每一条 video / article / resource：
     - 生成一个新的 Snowflake ID（若后续要把它作为主键）；  
     - 使用编码函数生成 11 位字符串；  
     - 临时将 Snowflake ID 写入一个新列（如 `new_id`），字符串写入 `vid_str` / `aid_str` / `rid_str`。

3. **更新关联表**
   - 对所有引用视频 ID 的表（resource、history、danmaku、like_video、collect_video、pgc_episode 等）：
     - 按旧自增 ID 映射成新的 Snowflake ID；  
     - 将 `Vid`/`Cid`/`videoId` 等字段批量更新为新 ID。

4. **切换主键（可选分步）**
   - 将 video/article/resource 表的主键从自增 ID 切到 Snowflake ID（需要调整 auto_increment、索引和外键约束）。
   - 也可以先保留旧 ID 列，仅把所有逻辑统一切到 Snowflake ID，待稳定后再移除旧主键。

5. **API 层切换**
   - 所有对外接口入口统一改为接收字符串 ID：  
     - 解析字符串 → Snowflake 数字；  
     - 使用数字 ID 走原有业务逻辑。
   - 前端与 Flutter 客户端更新：所有使用 vid/aid/resourceId 的地方，统一视为字符串处理。

6. **回滚策略**
   - 在完成迁移前保留旧 ID 列与索引；若发现问题，可临时切回旧 ID 逻辑。  
   - 数据层面保留「旧自增 ID → 新 Snowflake ID」的映射表，便于排查及必要时迁回。

---

## 6. 与 Flutter / 前端的简单约定

- **类型**：`vid` / `aid` / `resourceId` 一律按 **字符串** 处理，不再假定为数字。
- **展示**：UI 中若需要 ID（例如 Debug/分享链接），都展示短字符串（11 位）；不展示 Snowflake 数字。
- **兼容期**：如果后端暂时既支持数字又支持字符串，Flutter 端**优先使用字符串 ID**，只在调试或兼容模式下使用数字。

---

## 7. 状态说明

- 当前这份文档仅为**设计方案**，尚未在 `E:\\server\\alnitak\\server` 中实际落地。  
- 真正执行迁移和改造时，应在服务端仓库的 `docs` 中同步一份（或移动本文件），并按上述步骤细化为具体 SQL 和代码改动计划。

