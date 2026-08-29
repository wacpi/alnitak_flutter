import '../models/history_models.dart';
import 'history_service.dart';
import 'logger_service.dart';

/// 播放进度恢复服务
///
/// 从 VideoPlayerController 中提取，独立负责：
/// - 从 HistoryService 拉取播放进度
/// - 按剩余时长/回看阈值判定是否恢复
/// - 调用注入的 seek 回调恢复播放位置
///
/// 与原实现行为完全一致：500ms 节流、视频未就绪则延迟 500ms 重试、
/// 会话/资源变化时放弃恢复、正常回退 2 秒、接近结尾不恢复。
class PlaybackProgressService {
  final LoggerService _logger = LoggerService.instance;

  /// 距上次恢复的最小间隔（ms），防止并发请求重复恢复
  int? _lastProgressFetchTime;

  /// 目标位置落后当前播放不超过该秒数时忽略恢复（已接近目标）
  static const int _restoreBackwardIgnoreMaxSeconds = 15;

  /// 注入：控制器是否已释放
  final bool Function() isDisposed;
  /// 注入：会话是否有效（对应控制器的 _isSessionActive）
  final bool Function(int sessionId) isSessionActive;
  /// 注入：播放器是否已初始化
  final bool Function() isPlayerInitialized;
  /// 注入：当前资源 vid（对应控制器的 _currentVid）
  final String? Function() currentVid;
  /// 注入：当前分 P（对应控制器的 _currentPart）
  final int Function() currentPart;
  /// 注入：播放器当前位置
  final Duration Function() currentPosition;
  /// 注入：执行 seek
  final Future<void> Function(Duration) onSeek;
  /// 注入：播放器调试日志
  final void Function(String message) log;

  PlaybackProgressService({
    required this.isDisposed,
    required this.isSessionActive,
    required this.isPlayerInitialized,
    required this.currentVid,
    required this.currentPart,
    required this.currentPosition,
    required this.onSeek,
    required this.log,
  });

  /// 获取并恢复播放进度（对外入口，保持原 [VideoPlayerController.fetchAndRestoreProgress] 语义）
  Future<void> fetchAndRestore(int sessionId) async {
    if (isDisposed()) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastProgressFetchTime != null && now - _lastProgressFetchTime! < 500) return;
    _lastProgressFetchTime = now;

    if (currentVid() == null) return;

    if (!isPlayerInitialized()) {
      Future.delayed(const Duration(milliseconds: 500), () async {
        if (isSessionActive(sessionId) && currentVid() != null) {
          await _doFetchAndRestore();
        }
      });
      return;
    }
    await _doFetchAndRestore();
  }

  Future<void> _doFetchAndRestore() async {
    final vid = currentVid();
    if (vid == null) return;
    final requestVid = vid;
    final requestPart = currentPart();

    try {
      final historyService = HistoryService();
      final progressData =
          await historyService.getProgress(vid: requestVid, part: requestPart);

      if (isDisposed() ||
          currentVid() != requestVid ||
          currentPart() != requestPart) {
        return;
      }
      if (progressData == null) return;

      final targetPos = restoreTargetSecondsFromHistory(progressData);
      if (targetPos == null) return;

      final currentPos = currentPosition().inSeconds;
      if ((targetPos - currentPos).abs() <= 3) return;

      if (targetPos < currentPos &&
          currentPos - targetPos <= _restoreBackwardIgnoreMaxSeconds) {
        return;
      }

      log('history restore seek current=${currentPos}s -> target=${targetPos}s vid=$requestVid part=$requestPart');
      await onSeek(Duration(seconds: targetPos));
    } catch (e) {
      _logger.logWarning('恢复播放进度失败: $e');
    }
  }

  /// 由历史进度计算恢复目标秒数（正常回退 2 秒，接近结尾返回 null）
  int? restoreTargetSecondsFromHistory(PlayProgressData data) {
    final p = data.progress;
    if (p < 0) return null;
    if (data.duration > 0) {
      final adjusted = p > 2 ? p - 2 : p;
      final remaining = data.duration - adjusted;
      if (remaining <= 3) return null;
    }
    final adjustedProgress = p > 2 ? p - 2 : p;
    return adjustedProgress.floor();
  }
}