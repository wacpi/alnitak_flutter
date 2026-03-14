# 代码质量修复与后续建议

本文档记录按行业标准完成的修复项与建议的后续改进。

## 已完成的修复

1. **main() 未捕获异步异常**
   - 使用 `runZonedGuarded` 包裹初始化与 `runApp`，未捕获的异步异常统一由 `LoggerService.logError` 记录。

2. **静默 catch 改为记录**
   - `video_play_page.dart`：`_refreshUserActionStatus` 的 catch 增加 `LoggerService.logWarning`。
   - `history_service.dart`：`_getLocalProgress` / `_saveLocalProgress` 的 catch 增加 `LoggerService.logWarning`。
   - 建议：其余 `catch (_) {}` 可逐步改为带 tag 的 log，便于排查问题。

3. **API 配置环境化**
   - `ApiConfig` 支持默认 host/port + SharedPreferences 覆盖。
   - 新增 `setHostPortOverride(host:, port:)`，传空字符串或 0 表示恢复默认。
   - 便于调试/多环境切换，无需改代码。

4. **测试**
   - 默认 `widget_test.dart` 改为「App 启动并显示主框架」的简单冒烟测试（仅 `pump()`，避免 `pumpAndSettle` 触发网络超时）。
   - 新增 `test/error_handler_test.dart`：覆盖 `ErrorHandler.getErrorMessage` 与 `ErrorHandler.isNetworkRelatedError` 的单元测试。

5. **清理与 .gitignore**
   - 删除 `lib/utils/http_client.dart.bak`、`lib/pages/video/widgets/media_player_widget.dart.before_gesture`。
   - `.gitignore` 增加 `*.bak`、`*.before_*`、`*.orig`。

6. **ValueNotifier 释放**
   - 核查后确认：`video_play_page` 的 `_danmakuCountNotifier`、`VideoPlayerController` 内各 ValueNotifier、`OnlineWebSocketService.onlineCount` 均在对应 `dispose` 中正确释放。

7. **ErrorBoundary 与 MyApp 错误 UI 统一**
   - `ErrorBoundary` 的默认错误页按钮由「重试」改为「返回首页」，与 MyApp 的 `errorBuilder` 行为一致。

8. **analysis_options 更严 lint**
   - 启用：`avoid_empty_else`、`avoid_returning_null_for_future`、`cancel_subscriptions`、`no_duplicate_case_values`、`use_full_hex_values_for_flutter_colors`。
   - 并修复了分析出现的 `dead_null_aware_expression`、`unused_element` 等问题。

## 建议的后续改进

- **custom_player_ui 拆分**  
  `lib/pages/video/widgets/custom_player_ui.dart` 体量较大（约 1500+ 行），建议按职责拆成多个文件，例如：
  - 顶部栏（返回、标题滚动）：单独 widget 文件；
  - 底部控制栏（播放/暂停、进度、全屏等）：单独 widget 文件；
  - 清晰度/倍速/弹幕设置等面板：可再拆为若干小 widget。  
  拆分时注意保持 state 与回调的清晰传递，避免过度 prop drilling，可考虑在现有 State 内组合子 widget 并传入回调。

- **更多静默 catch 的日志**  
  在 `video_service`、`video_player_controller`、`cache_service` 等处的空 catch 中，逐步增加 `LoggerService` 的 log（带 tag），便于线上与调试排查。

- **正式包名与 release 行为**  
  当前 Android `applicationId` 仍为 `com.example.alnitak_flutter`，正式发布前建议改为实际包名；通知栏 channel 已与当前 applicationId 一致。  
  Release 下已通过 `kDebugMode` 控制不打印 API 基础地址，其余日志上报可按需做脱敏或采样。

- **重试策略**  
  `HttpClient` 的 `RetryInterceptor` 为 10 次、间隔较长，可按接口类型（如登录/支付 vs 列表）区分重试次数与间隔，避免用户长时间等待。

- **依赖 override**  
  media_kit 系列目前全部 override 为同一 git ref，建议在 README 或 CONTRIBUTING 中说明原因与升级策略，并定期评估是否可回到上游。
