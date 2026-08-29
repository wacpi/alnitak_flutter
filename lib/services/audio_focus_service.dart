import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:media_kit/media_kit.dart';

import '../main.dart' show audioHandler;
import 'logger_service.dart';

/// 音频焦点管理服务
///
/// 从 VideoPlayerController 中提取，独立负责 AudioSession 的
/// 初始化、中断/becomingNoisy 事件订阅与 audioHandler 挂载。
/// 播放动作通过回调反向注入主控制器，保持行为与原实现一致：
/// - duck：压低/恢复音量（由主控制器实现）
/// - pause 中断：仅当实际播放中才记录并从暂停（保持音频焦点，不释放）
/// - 恢复：仅当中断前在播且当前未播才恢复
class AudioFocusService {
  final LoggerService _logger = LoggerService.instance;

  AudioSession? _audioSession;
  bool _wasPlayingBeforeInterruption = false;
  /// 唯一标识本服务对 audioHandler 的占用所有权
  final int ownerId = identityHashCode(Object());

  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<dynamic>? _becomingNoisySubscription;

  /// 注入：当前是否正在播放
  final bool Function() isPlaying;
  /// 注入：是否为用户中断暂停（保持音频焦点）
  final Future<void> Function({bool isInterrupt}) onPause;
  /// 注入：恢复播放（内部自行校验可播放条件）
  final Future<void> Function() onResumePlay;
  /// 注入：duck 事件（true=压低音量，false=恢复音量）
  final void Function(bool duck) onDuck;

  AudioFocusService({
    required this.isPlaying,
    required this.onPause,
    required this.onResumePlay,
    required this.onDuck,
  });

  /// 挂载播放器到全局 audioHandler（后台播放透传控制）
  void attachPlayer(Player player, {required Future<void> Function(Duration) onSeek}) {
    audioHandler.attachPlayer(
      player,
      ownerId: ownerId,
      onPlay: () => onResumePlay(),
      onPause: () => onPause(),
      onSeek: onSeek,
    );
  }

  /// 初始化音频会话并订阅中断/拔耳机事件
  Future<void> init() async {
    try {
      _audioSession = await AudioSession.instance;
      await _audioSession!.configure(const AudioSessionConfiguration.music());

      _interruptionSubscription = _audioSession!.interruptionEventStream.listen((event) {
        _handleAudioInterruption(event);
      });

      _becomingNoisySubscription = _audioSession!.becomingNoisyEventStream.listen((_) {
        _handleBecomingNoisy();
      });

      _logger.logDebug('[AudioSession] 初始化成功', tag: 'AudioSession');
    } catch (e) {
      _logger.logError(message: '[AudioSession] 初始化失败: $e');
    }
  }

  /// 播放时激活音频焦点
  Future<void> activate() async {
    await _audioSession?.setActive(true);
  }

  /// 非中断暂停时释放音频焦点
  Future<void> deactivate() async {
    await _audioSession?.setActive(false);
  }

  void _handleAudioInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          onDuck(true);
          break;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          _wasPlayingBeforeInterruption = isPlaying();
          if (_wasPlayingBeforeInterruption) onPause(isInterrupt: true);
          break;
      }
    } else {
      switch (event.type) {
        case AudioInterruptionType.duck:
          onDuck(false);
          break;
        case AudioInterruptionType.pause:
          if (_wasPlayingBeforeInterruption) {
            _wasPlayingBeforeInterruption = false;
            onResumePlay();
          }
          break;
        case AudioInterruptionType.unknown:
          _wasPlayingBeforeInterruption = false;
          break;
      }
    }
  }

  void _handleBecomingNoisy() {
    if (isPlaying()) onPause();
  }

  /// 释放音频会话（应用退出/页面销毁）
  Future<void> dispose() async {
    try {
      await _audioSession?.setActive(false);
    } catch (_) {
      // 释放音频焦点失败不阻塞 dispose
    }
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    _interruptionSubscription = null;
    _becomingNoisySubscription = null;
    _audioSession = null;
  }

  /// 从 audioHandler 卸载播放器
  Future<void> detachPlayer() async {
    await audioHandler.stopIfOwner(ownerId);
    audioHandler.detachPlayerIfOwner(ownerId);
  }
}