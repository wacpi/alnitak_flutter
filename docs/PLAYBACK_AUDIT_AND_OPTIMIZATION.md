# 播放流程审核与优化建议

> 基于 media-kit 官方文档、E:\pili_plus 参考实现，对本项目播放流程的审核与优化方案

---

## 一、架构与流程对比

| 维度 | pili_plus | alnitak_flutter |
|------|------------|-----------------|
| **Player 架构** | 单例 `PlPlayerController`，全局唯一 Player | 每页一个 `VideoPlayerController`，支持多实例 |
| **适用场景** | 单视频页、快速切换视频 | 多 Tab、推荐连播、分 P 切换 |
| **AudioHandler** | 全局 Handler，无 attach/detach | `attachPlayer`/`detachPlayer` 显式绑定 |

**结论**：alnitak_flutter 的多实例 + attach/detach 更适合当前业务（推荐连播、分 P），无需改为单例。

---

## 二、mpv 参数配置对比

| 参数 | pili_plus | alnitak_flutter |
|------|------------|-----------------|
| **video-sync** | `Pref.videoSync`（默认 display-resample） | 固定 `display-resample` |
| **ao** | `Pref.audioOutput`（可设置里改） | 固定 `audiotrack` |
| **autosync** | `Pref.autosync`（非 0 时） | 固定 `30` |
| **bufferSize** | `Pref.expandBuffer`：4MB/16MB 或 32MB/64MB | 固定 32MB |
| **hr-seek** | 未显式配置（mpv 默认） | `yes`（双独立流音画同步必需） |
| **demuxer-max-back-bytes** | 未配置 | `0`（fMP4 PTS 回溯修复必需） |
| **demuxer-lavf-o** | 未配置 | `fflags=+discardcorrupt` |

**结论**：alnitak_flutter 的 fMP4 专属配置（hr-seek、demuxer-max-back-bytes）必须保留。可借鉴 pili_plus 增加**可配置项**。

---

## 三、优化建议（按优先级）

### P0：高优先级

#### 1. Seek 前等待 buffer（参考 pili_plus）

**现状**：alnitak_flutter 直接 `await _player!.seek(position)`，在 buffer 为空或刚起播时可能加剧卡顿。

**pili_plus 做法**（`controller.dart:1085-1087`）：
```dart
if (isSeek) {
  await _videoPlayerController?.stream.buffer.first;
}
// 再 seek
```

**建议**：在 `_seekInternal` 中，用户拖拽 seek 时先 `await _player!.stream.buffer.first`（带超时，如 500ms），再执行 seek。避免在 buffer 完全为空时 seek 导致长时间等待。

**注意**：`stream.buffer.first` 在已有缓冲时通常立即完成；仅在刚起播、网络极差时可能等待。可加 `timeout` 防止死等。

---

#### 2. 请求防串台（已实现，可加强）

**现状**：`_pageRequestToken` + `_isActivePageRequest` 已覆盖 `_loadVideoData`、`_fetchProgressAndRestore`、`_loadSecondaryData`。

**pili_plus 做法**：`isQuerying` 防并发 + `isClosed` 防旧请求回写。

**建议**：确认所有异步回调（如 `getVideoDetail`、`getProgress`、`getDashManifest`）在回写前都经过 `_isActivePageRequest` 校验。当前实现已较完善，可做一次全局 grep 查漏。

---

### P1：中优先级

#### 3. 缓冲大小可配置（expandBuffer）

**pili_plus**：`Pref.expandBuffer` 为 true 时 32MB/64MB，否则 4MB/16MB，节省内存并适应弱网。

**建议**：在设置页增加「扩展缓冲」开关，对应：
- 关闭：16MB（直播 4MB）
- 开启：32MB（直播 16MB）

存储 key 可复用 `video_decode_mode` 同类的 `SharedPreferences`。

---

#### 4. 音频输出可配置（ao）

**pili_plus**：`Pref.audioOutput`，可选 `audiotrack`、`opensles`、`aaudio` 等。

**建议**：在设置页增加「音频输出」选项（仅 Android）：
- `audiotrack`（默认，兼容性好）
- `aaudio`（低延迟，新机型推荐）
- `opensles`（部分设备更稳定）

参考 `docs/BLUETOOTH_LATENCY_COMPARISON.md`，优先 aaudio 可改善蓝牙延迟。

---

#### 5. 监听器幂等与会话隔离（已实现）

**现状**：`_listenersStarted`、`playbackSessionId`、`_isSessionActive` 已防止异常路径重复注册和旧会话回写。

**结论**：保持现状即可。

---

### P2：低优先级

#### 6. 音频响度归一化（lavfi-complex）

**pili_plus**：通过 `extras['lavfi-complex']` 传入 `loudnorm` 等参数，统一不同视频音量。

**建议**：若用户反馈音量差异大，可引入类似逻辑；否则可暂缓。

---

#### 7. 起播门控（_waitForVideoReadyBeforePlay）

**现状**：alnitak_flutter 有 `_waitForVideoReadyBeforePlay`，等待 `video-out-params` 或 demuxer 缓冲 ≥800ms 再 play，减少「音频先起、视频晚到」。

**pili_plus**：无此逻辑，直接 play。

**结论**：保留。对双独立流 fMP4 能减少音画不同步。

---

#### 8. 缓冲显示防抖（_bufferingSustainMs）

**现状**：缓冲持续 1500ms 才置 `isBuffering=true`，避免短暂抖动闪加载。

**pili_plus**：直接使用 `stream.buffering`，无防抖。

**结论**：保留，符合常见播放器体验。

---

## 四、Seek 卡顿专项分析

### 当前配置约束

- `hr-seek=yes`：双独立流必须精确 seek，否则音画不同步
- `demuxer-max-back-bytes=0`：禁止回退读取，避免 fMP4 PTS 回溯

两者都会增加 seek 时的处理成本，尤其是 `demuxer-max-back-bytes=0` 会削弱向后缓存，seek 后需重新拉取数据。

### 可尝试的优化

1. **Seek 前等待 buffer**（见 P0-1）：减少「空 buffer seek」导致的长时间等待。
2. **预加载 hint**：若 media-kit 支持，可尝试在用户拖拽时提前发起 range 请求，实际效果需实测。
3. **服务端**：确保 fMP4 的 sidx 与 fragment 对齐，便于 range seek；参考 `docs/fmp4_pts_analysis.md`。

### 不建议的改动

- 将 `hr-seek` 改为 `no`：会导致 seek 后音画不同步（已验证）。
- 将 `demuxer-max-back-bytes` 改为非 0：会重新引入 PTS 回溯问题。

---

## 五、实施清单

| 序号 | 优化项 | 优先级 | 工作量 | 依赖 | 状态 |
|------|--------|--------|--------|------|------|
| 1 | Seek 前 await stream.buffer.first（带超时） | P0 | 小 | 无 | ✅ 已实施 |
| 2 | 全局校验 _isActivePageRequest 覆盖 | P0 | 小 | 无 | ✅ 已实施 |
| 3 | 设置页增加「扩展缓冲」开关 | P1 | 中 | SharedPreferences | ✅ 已实施 |
| 4 | 设置页增加「音频输出」选项（Android） | P1 | 中 | Pref 存储 | ✅ 已实施 |
| 5 | 音频响度归一化（可选） | P2 | 中 | 用户反馈 | 待定 |

---

## 六、参考文件

- **pili_plus**：`lib/plugin/pl_player/controller.dart`（704-728 行配置，896-1056 行监听，1070-1107 行 seek）
- **alnitak_flutter**：`lib/controllers/video_player_controller.dart`
- **fMP4 说明**：`docs/fmp4_pts_analysis.md`
- **蓝牙延迟对比**：`docs/BLUETOOTH_LATENCY_COMPARISON.md`

---

*文档更新: 2026-03-16*

### 实施记录（2026-03-16）

- **P0-1**：`_seekInternal` 中 seek 前增加 `await _player!.stream.buffer.first.timeout(500ms)`，duration=0 的轮询分支同样处理
- **P0-2**：`_fetchProgressAndRestoreSeamless` 增加 `requestToken` 参数并全程使用 `_isActivePageRequest`；`_changePart` 增加 `_changePartToken` 防串台
- **P1-3**：设置页「偏好设置」增加「扩展缓冲」开关，key=`video_expand_buffer`，关闭 16MB / 开启 32MB
- **P1-4**：设置页「偏好设置」增加「音频输出」选项（仅 Android），可选 audiotrack / aaudio / opensles
