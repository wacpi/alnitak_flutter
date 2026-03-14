# CustomPlayerUI 代码结构与拆分建议

## 一、当前结构概览

**文件**：`lib/pages/video/widgets/custom_player_ui.dart`（约 1508 行）

### 1. 入口与数据

| 类型 | 内容 |
|------|------|
| **StatefulWidget** | `CustomPlayerUI` |
| **入参** | `controller`(VideoController)、`logic`(VideoPlayerController)、`title`、`onBack`、`danmakuController`、`onlineCount`、`forceFullscreen`、`onFullscreenToggle` |
| **State** | `_CustomPlayerUIState`（SingleTickerProviderStateMixin） |

### 2. State 内部「块」划分（按用途）

| 块 | 变量/资源 | 行号区间（约） | 说明 |
|----|-----------|----------------|------|
| **持久化** | `_prefs`、`_volumeKey`、`_brightnessKey` | 46-49 | SharedPreferences 读写 |
| **显隐/锁定** | `_showControls`、`_isLocked`、`_hideTimer` | 56-60 | 控制栏显隐、锁屏、自动隐藏计时 |
| **标题滚动** | `_hasPlayedTitleAnimation`、`_titleScrollController`、`_titleScrollAnimation`、`_wasFullscreen` | 62-66 | 全屏标题滚动动画 |
| **手势反馈** | `_showFeedback`、`_feedbackIcon`、`_feedbackText`、`_feedbackValue` | 68-73 | 音量/亮度/进度条拖拽时的中央提示 |
| **拖拽** | `_dragStartPos`、`_gestureType`、`_playerBrightness`、`_startVolumeSnapshot`、`_startBrightnessSnapshot`、`_seekPos` | 75-81 | 上下/左右滑动的状态与快照 |
| **长按倍速** | `_isLongPressing`、`_normalSpeed` | 83-85 | 长按 2x 的临时状态 |
| **清晰度面板** | `_showQualityPanel`、`_qualityButtonKey`、`_panelRight`、`_panelBottom` | 87-91 | 面板开关 + 定位 |
| **弹幕** | `_showDanmakuSettings`、`_showDanmakuInput` | 93-97 | 弹幕设置/发送面板开关 |
| **倍速面板** | `_showSpeedPanel`、`_currentSpeed`、`_speedOptions`、`_speedButtonKey`、`_speedPanelRight` | 99-104 | 倍速面板开关 + 定位 |
| **派生** | getter `_fullscreen` | 106 | 全屏状态 |
| **订阅** | `_playingSubscription` | 109-110 | 播放状态监听 |

### 3. 方法分组（按职责）

| 分组 | 方法 | 行号约 | 说明 |
|------|------|--------|------|
| **生命周期** | `initState`、`dispose`、`_loadSettings`、`_saveVolume`、`_saveBrightness` | 112-177 | 初始化、销毁、持久化 |
| **显隐/计时** | `_startHideTimer`、`_toggleControls` | 181-206 | 控制栏显隐与 4 秒自动隐藏 |
| **面板开关** | `_toggleQualityPanel`、`_toggleSpeedPanel`（及弹幕相关 setState） | 207-231, 1384-1415 | 清晰度/倍速面板的打开与定位 |
| **手势** | `_onDragStart`、`_onDragUpdate`、`_onDragEnd`、`_onLongPressStart`、`_onLongPressEnd`、`_onDoubleTap`、`_seekRelative` | 235-354 | 滑动音量/亮度/进度、长按、双击 |
| **工具** | `_showFeedbackUI`、`_formatDuration` | 355-371 | 中央反馈 UI、时间格式化 |
| **build 主树** | `build` | 376-651 | LayoutBuilder → Stack（弹幕、手势层、亮度遮罩、锁定、反馈、长按标签、控制 UI、清晰度加载、各面板） |
| **顶部栏** | `_buildTopBar`、`_checkAndStartTitleAnimation`、`_buildScrollableTitle` | 656-852 | 返回 + 标题（含滚动动画） |
| **侧边/中央** | `_buildLockButton`、`_buildCenterPlayButton` | 854-942 | 锁屏按钮、中央播放/重播按钮 |
| **底部栏** | `_buildBottomBar`、`_buildProgressRow`、`_buildControlButtonsRow` | 944-1296 | 进度条 + 播放/画质/弹幕/倍速/全屏等按钮 |
| **面板** | `_buildQualityPanel`、`_buildQualityLabel`、`_buildSpeedPanel` | 1298-1456 | 清晰度列表、倍速列表 |
| **Slider 定制** | `_CustomSliderThumbShape`（类） | 1458-1508 | 进度条拇指形状 |

### 4. build 树结构（简化）

```
LayoutBuilder
  Scaffold
    ClipRect > Container > Stack[
      0. 弹幕层 (DanmakuOverlay)
      1. 手势层 (GestureDetector，全屏手势)
      1.5 亮度遮罩
      2. 锁定按钮 (左侧)
      3. 手势反馈 (中央图标+文字)
      3.5 长按倍速标签 (顶部)
      4. 控制 UI (StreamBuilder completed)
           → 完成时: 重播按钮 + TopBar + BottomBar
           → 播放中: TopBar + LockButton + CenterPlay + BottomBar
      5. 清晰度切换中 loading
      6. 清晰度面板 (_buildQualityPanel)
      6.5 倍速面板 (_buildSpeedPanel)
      7. 弹幕设置面板 (DanmakuSettingsPanel)
      8. 弹幕发送条 (DanmakuSendBar)
    ]
```

---

## 二、依赖关系简要

- **所有 UI 都依赖**：`widget.controller`、`widget.logic`（播放/暂停、进度、画质、倍速、全屏等）。
- **顶部栏** 额外依赖：`title`、`_fullscreen`、`_wasFullscreen`、`_titleScrollController`/Animation、`_checkAndStartTitleAnimation`、`onBack`。
- **底部栏/进度条** 依赖：`logic.sliderPositionSeconds`、`durationSeconds`、`bufferedSeconds`、`onSliderDrag*`、`_formatDuration`、`_startHideTimer`。
- **控制按钮行** 依赖：`logic`（画质、循环、后台播放）、`danmakuController`、`onlineCount`、`forceFullscreen`、`onFullscreenToggle`、各面板的开关与 `_startHideTimer`。
- **清晰度/倍速面板** 依赖：`logic`（画质列表、当前画质、倍速）、`_panelRight`/`_panelBottom`、`_speedPanelRight`、`_currentSpeed`、以及关闭面板/`_startHideTimer` 的回调。
- **手势** 依赖：`controller`（音量、进度、rate）、`_playerBrightness`、以及 `_showFeedbackUI`、`_seekRelative` 等。

---

## 三、拆分建议（供讨论）

### 方案 A：按「区域」拆成多个 Widget 文件（推荐）

保持 **状态与手势仍留在主文件**，只把「纯展示 + 少量回调」拆成无状态或轻状态子 Widget，主文件负责组合和传参。

| 新文件 | 职责 | 传入参数（思路） | 预计行数 |
|--------|------|------------------|----------|
| `custom_player_ui.dart` | 主入口：状态、手势、计时、build 树组装 | 不变 | 约 400～500 |
| `player_top_bar.dart` | 顶部栏：返回、标题（含滚动动画） | `title`、`onBack`、`fullscreen`、`AnimationController` + 启动动画回调 | 约 200 |
| `player_bottom_bar.dart` | 底部整块：进度条 + 控制按钮行 | `logic`、`controller`、`fullscreen`、`danmakuController`、`onlineCount`、`onFullscreenToggle`、`onHideTimer`、画质/倍速/弹幕面板开关回调 | 约 350 |
| `player_quality_panel.dart` | 清晰度面板 + 清晰度标签样式 | `qualities`、`currentQuality`、`getQualityDisplayName`、`onSelect`、`onClose`、`right`、`bottom` | 约 90 |
| `player_speed_panel.dart` | 倍速面板 | `speeds`、`currentSpeed`、`onSelect`、`onClose`、`right`、`bottom` | 约 80 |
| `player_progress_slider.dart` | 进度条一行 + `_CustomSliderThumbShape` | `logic.sliderPositionSeconds` 等、`onDragStart`/`Update`/`End`、`formatDuration` | 约 120 |

**优点**：主文件立刻变短，各区域职责清晰，后续改顶部/底部/面板互不影响。  
**缺点**：底部栏和主文件之间参数会比较多（可考虑传 `logic` + 少量回调，减少参数个数）。

---

### 方案 B：只拆「面板」类（改动最小）

只把**弹层**拆出去，主文件和顶部/底部栏不动。

| 新文件 | 职责 |
|--------|------|
| `player_quality_panel.dart` | 清晰度列表 + 定位逻辑（由主文件算好 right/bottom 传入） |
| `player_speed_panel.dart` | 倍速列表 + 定位 |

主文件仍保留：`_buildTopBar`、`_buildBottomBar`、`_buildProgressRow`、`_buildControlButtonsRow`、手势与状态。  
**优点**：改动小、风险低、易回滚。  
**缺点**：主文件仍然很大（约 1400 行），可维护性提升有限。

---

### 方案 C：主文件只做「壳」+ 一个 PlayerController 传下去

引入一个「播放器 UI 用的数据+回调」对象（例如 `PlayerUICallbacks` 或直接用 `VideoPlayerController` + 扩展），所有子 Widget 只接这一个对象 + 少量显式参数（如 `fullscreen`、`title`）。

- 新建 `player_ui_*.dart` 若干（top_bar、bottom_bar、progress、quality_panel、speed_panel）。
- 主文件只负责：状态、手势、计时、以及把 `controller`/`logic` 和回调打包后传给子 Widget。

**优点**：子组件接口统一，后续加新控制项只改一处。  
**缺点**：要设计并维护「回调/数据」结构，第一次改动量比 A 大。

---

## 四、建议的讨论点

1. **你更倾向哪种方案？**  
   - A：按区域拆（主文件约 400～500 行，其余按上面表格拆）。  
   - B：只拆清晰度/倍速面板（改动最小）。  
   - C：主文件做壳 + 统一「PlayerUI 数据/回调」对象。

2. **底部栏是否再拆？**  
   - 若拆：`player_bottom_bar.dart`（容器）+ `player_progress_slider.dart`（进度条）+ 控制按钮行可仍在 bottom_bar 内或再拆成 `player_control_buttons.dart`。  
   - 若不拆：底部一整块保留在主文件，只拆面板（方案 B）。

3. **`_CustomSliderThumbShape` 放哪？**  
   - 建议：随进度条一起放到 `player_progress_slider.dart`（或 `player_bottom_bar.dart` 若进度条不单独成文件），避免主文件仍保留「细节 UI 类」。

4. **手势与反馈是否保留在主文件？**  
   - 建议：保留在主文件。手势和 `_showControls`、`_hideTimer`、亮度/音量/进度强相关，放主文件更清晰；反馈 UI 可保留为私有方法或极小的 `PlayerGestureFeedback` widget。

你定一个方案（或 A/B/C 的折中），我可以按该方案给出具体「第一步」的拆文件步骤（先拆哪几个方法、怎么改 import 和调用）。