# 蓝牙延迟对比：alnitak_flutter vs pili_plus

## 一、技术栈对比

| 项目 | 播放器 | 来源 | Android 音频输出 (ao) | video-sync | autosync |
|------|--------|------|------------------------|------------|----------|
| **alnitak_flutter** | media_kit (libmpv) | pub.dev 1.1.11 + 第三方 fork | `opensles,aaudio,audiotrack`（写死） | display-resample | 30 |
| **pili_plus** | media_kit (libmpv) | **Git  fork** (My-Responsitories/media-kit, version_1.2.5) | `Pref.audioOutput`，默认同左，**可设置里改** | display-resample | 30（可改） |

- 两者都使用 **MPV** 的 `video-sync=display-resample` 和 `autosync`，用于把**画面同步到音频**，蓝牙时画面会跟着延迟，保持口型一致。
- 差异主要在：**音频输出顺序是否可调**、**是否用同一套 media_kit 原生库**、**音频会话配置**。

## 二、为什么 pili_plus 蓝牙“几乎感觉不到延迟”

### 1. Android：OpenSL ES 在蓝牙下表现更差

- **OpenSL ES** 在接蓝牙时有不少反馈：卡顿、需要更大缓冲，延迟更明显。
- **AAudio**（Android 8+）是官方推荐的低延迟 API，延迟和稳定性通常更好。
- 我们当前写死的是 **`opensles,aaudio,audiotrack`**，即**优先用 OpenSL ES**；若设备选到了 OpenSL，蓝牙下就容易更“拖”。
- pili_plus 在**设置里可改“音频输出”**，用户可只选 **AAudio**，相当于强制走低延迟路径，蓝牙下更容易“感觉不到延迟”。

### 2. 音频输出顺序建议

- 把 **AAudio 放在前面**，让 MPV 优先用 AAudio，再回退到 OpenSL / AudioTrack：
  - 建议：`ao = 'aaudio,opensles,audiotrack'`（仅 Android）。
- 若希望和 pili_plus 一致且给用户选择，可增加“音频输出”设置项，保存到 Pref，再在创建 Player 时用 `Pref.audioOutput`。

### 3. media_kit 来源不同

- pili_plus 使用 **Git 上的 fork**（含 `libs/android/media_kit_libs_android_video` 等），**原生层可能带自有补丁**（如对 ao 行为、缓冲、蓝牙路由的优化）。
- 我们使用 pub.dev 的 media_kit + 第三方 fork，**不包含 pili_plus 那套原生改动**，若他们有对蓝牙/延迟的补丁，我们这边不会自动具备。

### 4. 音频会话（iOS / 系统行为）

- **alnitak_flutter**：已改为与 pili_plus 一致，使用 `AudioSessionConfiguration.music()`（原为自定义 playback + allowBluetooth + movie）。
- **pili_plus**：`AudioSessionConfiguration.music()`（预设）。
- 使用同一预设后，iOS 下蓝牙路由与缓冲策略与 pili_plus 一致，有利于蓝牙延迟/口型同步观感。

## 三、建议改动（alnitak_flutter）

1. **Android 优先使用 AAudio**  
   在创建 Player 时，将 Android 的 `ao` 改为：
   ```dart
   opt['ao'] = 'aaudio,opensles,audiotrack';  // 原为 opensles,aaudio,audiotrack
   ```
2. **（可选）增加“音频输出”设置**  
   仿照 pili_plus，增加设置项，可选：仅 aaudio、仅 opensles、仅 audiotrack 或组合，并写入 Pref，创建 Player 时读取。
3. **（已完成）对齐音频会话**  
   iOS/Android 已统一为 `AudioSessionConfiguration.music()`，与 pili_plus 一致。

## 四、小结

- 两者在**同步策略**（video-sync / autosync）上已对齐，差异主要在：
  - **Android 默认用了 OpenSL ES 优先**，蓝牙下更容易暴露延迟；
  - pili_plus 可**强制 AAudio** 且可能使用**带自有补丁的 media_kit 原生库**。
- 在 alnitak_flutter 中把 **`ao` 改为优先 aaudio** 是成本低、收益明确的改动，建议先做；再视需要加“音频输出”设置和音频会话对比测试。
