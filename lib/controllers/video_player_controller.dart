/// 播放器核心控制器
/// 
/// 负责：
/// - Player / VideoController 实例创建与配置
/// - 数据源加载、播放控制、进度管理
/// - 事件监听与状态管理
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:audio_session/audio_session.dart';

import '../services/video_stream_service.dart';
import '../services/cache_service.dart';
import '../services/history_service.dart';
import '../services/logger_service.dart';
import '../services/player_settings_service.dart';
import '../models/data_source.dart';
import '../models/dash_models.dart';
import '../models/subtitle_track_item.dart';
import '../services/subtitle_api_service.dart';
import '../models/history_models.dart';
import '../models/loop_mode.dart';
import '../utils/wakelock_manager.dart';
import '../utils/error_handler.dart';
import '../utils/quality_utils.dart';
import '../utils/network_line_selector.dart';
import '../main.dart' show audioHandler;
import 'player_event_listener.dart';

class VideoPlayerController extends ChangeNotifier {
  // ===========================================================================
  // 1. 服务与基础依赖
  // ===========================================================================
  final VideoStreamService _streamService = VideoStreamService();
  final CacheService _cacheService = CacheService();
  final LoggerService _logger = LoggerService.instance;
  SharedPreferences? _prefs;

  // ===========================================================================
  // 2. 播放器核心实例
  // ===========================================================================
  Player? _player;
  VideoController? _videoController;

  Player get player => _player!;
  VideoController get videoController => _videoController!;

  // ===========================================================================
  // 3. 对外暴露状态 (ValueNotifiers 供 UI 层监听)
  // ===========================================================================
  final ValueNotifier<List<String>> availableQualities = ValueNotifier([]);
  final ValueNotifier<String?> currentQuality = ValueNotifier(null);
  
  // 播放状态
  final ValueNotifier<bool> isLoading = ValueNotifier(true);
  final ValueNotifier<bool> isPlayerInitialized = ValueNotifier(false);
  final ValueNotifier<bool> isBuffering = ValueNotifier(false);
  final ValueNotifier<bool> isSwitchingQuality = ValueNotifier(false);
  final ValueNotifier<bool> hasEverPlayed = ValueNotifier(false); // 区分首次加载与播放中缓冲
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  // 进度相关 (秒级粒度，防跳变)
  final ValueNotifier<int> sliderPositionSeconds = ValueNotifier(0);
  final ValueNotifier<int> durationSeconds = ValueNotifier(0);
  final ValueNotifier<int> bufferedSeconds = ValueNotifier(0);
  final ValueNotifier<bool> isSliderMoving = ValueNotifier(false);

  // 用户设置状态
  final ValueNotifier<LoopMode> loopMode = ValueNotifier(LoopMode.off);
  final ValueNotifier<bool> backgroundPlayEnabled = ValueNotifier(false);

  /// 当前分 P 可用字幕轨（先于 [Player.open] 拉列表会在部分机型上不可靠；由 [setDataSource] 成功后同步）
  final ValueNotifier<List<SubtitleTrackItem>> subtitleTracks =
      ValueNotifier<List<SubtitleTrackItem>>([]);
  /// `null`：用户关闭或未选轨；`>=0`：对应 [subtitleTracks] 下标
  final ValueNotifier<int?> selectedSubtitleIndex = ValueNotifier<int?>(null);

  /// 与字幕 API [SubtitleApiService.fetchTracks] 对齐的资源键（通常为 shortId 或数字 id 字符串）
  String? _subtitleResourceKey;

  // ===========================================================================
  // 4. 内部状态变量
  // ===========================================================================
  // 生命周期与基础控制
  bool _isDisposed = false;
  bool _isDisposing = false;
  bool _isInitializing = false;
  bool _listenersStarted = false;
  bool _settingsLoaded = false;
  Object? _currentResourceId;
  Future<void>? _playerCreationFuture;
  Future<void> _operationQueue = Future.value();
  int _playbackSessionId = 0;

  // 播放进度与 Seek
  Duration _position = Duration.zero;
  Duration _sliderPosition = Duration.zero;
  Duration _userIntendedPosition = Duration.zero;
  Duration _lastReportedPosition = Duration.zero;
  Duration? _pendingSeekAfterSwitch;
  Duration? _latestSeekRequest;
  bool _isSeeking = false;
  bool _seekInFlight = false;
  DateTime? _lastSeekAt;
  DateTime? _playbackPositionGuardUntil;
  Duration _playbackPositionGuardAnchor = Duration.zero;

  // 状态机标志位
  bool _hasPlaybackStarted = false;
  bool _hasTriggeredCompletion = false;
  bool _hasJustCompleted = false;
  bool _isHandlingStall = false;

  // 资源与元数据
  bool _supportsDash = true; 
  DashManifest? _manifest; 
  String? _currentVid;
  
  // ignore: unused_field
  String? _currentRid; // 保留以备将来使用（如进度上报）
  int _currentPart = 1;
  String? _videoTitle;
  String? _videoAuthor;
  Uri? _videoCoverUri;

  // 音频中断处理
  AudioSession? _audioSession;
  bool _wasPlayingBeforeInterruption = false;
  final int _audioOwnerId = identityHashCode(Object());

  // 常量与防抖控制
  int _lastPtsLoggedSecond = -1;
  int? _lastProgressFetchTime;
  DateTime? _lastVideoEndAt;
  DateTime? _lastPlaybackBackwardLogAt;
  static const int _bufferingSustainMs = 1500;
  static const int _videoEndDebounceMs = 800;
  static const int _startupReadyTimeoutMs = 1500;
  static const int _playbackPositionGuardMs = 2000;
  static const int _spuriousBackwardJumpMs = 1600;
  static const int _restoreBackwardIgnoreMaxSeconds = 15;
  /// 进度条上缓冲右端至少比当前播放位置多出这么多秒（对齐 YouTube 观感）
  static const int _minBufferedBarAheadSeconds = 3;
  static const String _preferredQualityKey = 'preferred_video_quality_display_name';
  static const String _loopModeKey = 'video_loop_mode';
  static const String _backgroundPlayKey = 'background_play_enabled';

  // ===========================================================================
  // 5. 各种订阅与定时器
  // ===========================================================================
  PlayerEventListener? eventListener;
  VoidCallback? onReplayAfterCompletion;
  
  final StreamController<Duration> _positionStreamController = StreamController.broadcast();
  Stream<Duration> get positionStream => _positionStreamController.stream;

  List<StreamSubscription> _subscriptions =[];
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription? _interruptionSubscription;
  StreamSubscription? _becomingNoisySubscription;

  Timer? _stalledTimer;
  Timer? _seekTimer;
  Timer? _bufferingShowTimer;


  VideoPlayerController();

  Future<SharedPreferences> get _preferences async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ===========================================================================
  // 6. 播放器初始化与装配
  // ===========================================================================

  /// 初始化播放器并加载视频 (统一入口)
  Future<void> initialize({
    required Object resourceId,
    double? initialPosition,
    double? duration,
  }) async {
    if (_isInitializing && _currentResourceId == resourceId) return;
    _isInitializing = true;

    try {
      _currentResourceId = resourceId;
      _subtitleResourceKey = resourceId.toString().trim();
      subtitleTracks.value = [];
      selectedSubtitleIndex.value = null;

      isLoading.value = true;
      errorMessage.value = null;
      isPlayerInitialized.value = false;
      hasEverPlayed.value = false;
      _userIntendedPosition = Duration(seconds: initialPosition?.toInt() ?? 0);
      _hasPlaybackStarted = false;
      _hasTriggeredCompletion = false;

      // 预设总时长，避免 duration 就绪前进度条闪跳
      if (duration != null && duration > 0) {
        durationSeconds.value = duration.toInt();
      }

      // 并行 I/O：Settings + Manifest + Player 创建
      late final DashManifest manifest;
      await Future.wait<void>([
        if (!_settingsLoaded) _loadSettings(),
        _streamService.getDashManifest(resourceId).then((m) => manifest = m),
        _ensurePlayerReady(),
      ]);

      if (_isDisposed || _currentResourceId != resourceId) return;

      _manifest = manifest;
      _supportsDash = manifest.supportsDash;
      availableQualities.value = manifest.qualities;
      if (manifest.qualities.isEmpty) throw Exception('没有可用的清晰度');

      currentQuality.value = await _getPreferredQuality(availableQualities.value);

      if (_isDisposed || _currentResourceId != resourceId) return;

      // 获取 DataSource：DASH 直连 或回退 m3u8
      final DataSource dataSource;
      if (_supportsDash) {
        final ds = manifest.getDataSource(currentQuality.value!);
        if (ds == null) throw Exception('清晰度数据不可用');
        dataSource = ds;
      } else {
        dataSource = await _streamService.getM3u8DataSource(resourceId, currentQuality.value!);
      }

      if (_isDisposed || _currentResourceId != resourceId) return;

      await setDataSource(
        dataSource,
        seekTo: initialPosition != null && initialPosition > 0
            ? Duration(seconds: initialPosition.toInt())
            : Duration.zero,
        autoPlay: true,
      );
    } catch (e) {
      _logger.logError(message: '初始化失败', error: e, stackTrace: StackTrace.current);
      isLoading.value = false;
      errorMessage.value = ErrorHandler.getErrorMessage(e);
    } finally {
      _isInitializing = false;
    }
  }

  /// 幂等预创建 Player
  Future<void> _ensurePlayerReady() async {
    if (_player != null || _isDisposed) return;
    if (_playerCreationFuture != null) {
      await _playerCreationFuture;
      return;
    }
    _playerCreationFuture = _createPlayerInternal();
    try {
      await _playerCreationFuture;
    } finally {
      _playerCreationFuture = null;
    }
  }

  /// 实例化底层的 mpv player、AudioSession 和 VideoController
  Future<void> _createPlayerInternal() async {
    if (_player != null || _isDisposed) return;

    final results = await Future.wait([
      PlayerSettingsService.getDecodeMode(),
      PlayerSettingsService.getExpandBuffer(),
      PlayerSettingsService.getAudioOutput(),
    ]);
    final decodeMode = results[0] as String;
    final expandBuffer = results[1] as bool;
    final audioOutput = results[2] as String;

    if (_player != null || _isDisposed) return;

    final opt = <String, String>{};
    if (Platform.isAndroid) {
      opt['volume-max'] = '100';
      opt['ao'] = audioOutput;
      opt['autosync'] = '30';
    }
    final bufferSizeBytes = expandBuffer ? 32 * 1024 * 1024 : 16 * 1024 * 1024;
    
    _player = await Player.create(
      configuration: PlayerConfiguration(
        bufferSize: bufferSizeBytes,
        logLevel: kDebugMode ? MPVLogLevel.warn : MPVLogLevel.error,
        options: opt,
      ),
    );
    
    audioHandler.attachPlayer(
      _player!,
      ownerId: _audioOwnerId,
      onPlay: () => play(),
      onPause: () => pause(),
      onSeek: (pos) => seek(pos),
    );
    
    await _initAudioSession();
    await _configurePlayerOnce(decodeMode);

    _videoController = VideoController(
      _player!,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: decodeMode != 'no',
        hwdec: decodeMode != 'no' ? decodeMode : null,
      ),
    );
  }

  /// 首次创建 Player 时配置运行时可变的 mpv 属性
  Future<void> _configurePlayerOnce(String decodeMode) async {
    if (_player == null) return;

    // 音视频分离流防不同步，以音频为主，精确 seek
    _player!.setProperty('video-sync', 'audio');
    _player!.setProperty('hr-seek', 'yes');
    // mpv：非直播流起播前 demuxer 多读几秒，减轻首帧 unpause 时空窗
    _player!.setProperty('demuxer-readahead-secs', '12');
    _player!.setProperty('interpolation', 'no');
    _player!.setProperty('demuxer-max-back-bytes', '0');
    // fMP4 容错：discardcorrupt 丢弃损坏帧
    //_player!.setProperty('demuxer-lavf-o', 'fflags=+discardcorrupt');
    _player!.setProperty('network-timeout', '10');
    // 解码模式配置
    _player!.setProperty('hwdec', decodeMode);

    // 外挂字幕：禁用 mpv 原生渲染，使用 Flutter SubtitleView 渲染
    try {
      _player!.setProperty('sub-visibility', 'no');
      _player!.setProperty('sub-ass', 'no');
      _player!.setProperty('sub-border-style', 'outline-and-shadow');
      _player!.setProperty('sub-back-color', '#00000000');
      _player!.setProperty('sub-outline-size', '2.0');
      _player!.setProperty('sub-outline-color', '#FF000000');
      _player!.setProperty('sub-shadow-offset', '0');
      _player!.setProperty('sub-color', '#FFFFFFFF');
    } catch (_) {
      /* 个别编译选项可能裁剪属性 */
    }

    await _syncLoopProperty();
    await _player!.setAudioTrack(AudioTrack.auto());
  }

  // ===========================================================================
  // 7. 数据源加载与核心播放逻辑
  // ===========================================================================

  /// 设置播放数据源
  Future<void> setDataSource(
    DataSource dataSource, {
    Duration seekTo = Duration.zero,
    bool autoPlay = true,
  }) async {
    if (_isDisposed) return;
    final sessionId = _nextPlaybackSessionId();

    try {
      isLoading.value = true;

      if (_player != null && _player!.state.playing) {
        await pause();
      }

      removeListeners();
      _resetPlaybackStates();

      // 防止 UI 闪跳位置 0
      _position = _sliderPosition = seekTo;
      _updateSliderPositionSecond();
      _updateBufferedSecond();

      await _ensurePlayerReady();
      startListeners();

      final shouldPlayAfterStable = autoPlay;
      _playbackLog(
        'setDataSource begin session=$sessionId seekTo=${seekTo.inSeconds}s play=$shouldPlayAfterStable '
        'vid=$_currentVid part=$_currentPart',
      );

      // 组装外挂音频参数 (DASH 音视频分离支持)
      Map<String, String>? extras;
      if (dataSource.audioSource != null && dataSource.audioSource!.isNotEmpty) {
        final escapedAudio = Platform.isWindows
            ? dataSource.audioSource!.replaceAll(';', r'\;')
            : dataSource.audioSource!.replaceAll(':', r'\:');
        extras = {'audio-files': '"$escapedAudio"'};
      }

      await _player!.open(
        Media(
          dataSource.videoSource,
          start: seekTo,
          extras: extras,
          httpHeaders: dataSource.httpHeaders,
        ),
        play: false,
      );

      if (!_isSessionActive(sessionId)) return;

      isLoading.value = false;
      isPlayerInitialized.value = true;
      _armPlaybackPositionGuard(seekTo);

      if (shouldPlayAfterStable && !_isDisposed) {
        await _waitForVideoReadyBeforePlay(sessionId);
        if (!_isSessionActive(sessionId)) return;
        await play();
        if (_isSessionActive(sessionId)) {
          _armPlaybackPositionGuard(seekTo);
        }
      }

      unawaited(_syncExternalSubtitleTracks(sessionId));
    } catch (e) {
      if (!_isSessionActive(sessionId)) return;
      _isSeeking = false;
      isLoading.value = false;
      errorMessage.value = ErrorHandler.getErrorMessage(e);
      _logger.logError(message: 'setDataSource 失败', error: e, stackTrace: StackTrace.current);
    }
  }

  Future<void> play() async {
    if (_isDisposed || _player == null) return;
    if (_audioSession != null) {
      await _audioSession!.setActive(true);
    }
    await _player!.play();
  }

  Future<void> pause({bool isInterrupt = false}) async {
    if (_isDisposed || _player == null) return;
    await _player!.pause();
    if (!isInterrupt && _audioSession != null) {
      await _audioSession!.setActive(false);
    }
  }

  Future<void> seek(Duration position) async {
    if (_isDisposed || _player == null) return;
    if (position < Duration.zero) position = Duration.zero;

    _userIntendedPosition = position;
    _lastSeekAt = DateTime.now();
    
    if (isSwitchingQuality.value) {
      _pendingSeekAfterSwitch = position;
      return;
    }

    _latestSeekRequest = position;
    if (_seekInFlight) return;

    _seekInFlight = true;
    try {
      while (!_isDisposed && _player != null && _latestSeekRequest != null) {
        final target = _latestSeekRequest!;
        _latestSeekRequest = null;
        _isSeeking = true;
        
        try {
          await _seekInternal(target);
        } catch (e) {
          _logger.logWarning('seek 错误: $e');
        } finally {
          _isSeeking = false;
        }
      }
    } finally {
      _seekInFlight = false;
    }
  }

  Future<void> changeQuality(String quality) async {
    if (_isDisposed || _player == null) return;
    if (currentQuality.value == quality || _currentResourceId == null || isSwitchingQuality.value) {
      return;
    }

    await _enqueueOperation(() async {
      if (_isDisposed || _player == null) return;
      if (currentQuality.value == quality || _currentResourceId == null) return;

      final playerPos = _player!.state.position;
      final position = playerPos.inMilliseconds > 0 ? playerPos : _userIntendedPosition;
      _logger.logDebug('changeQuality: $quality, 保存位置 ${position.inSeconds}s');

      isSwitchingQuality.value = true;

      try {
        await _reloadWithDataSource(quality, position);
        currentQuality.value = quality;
        await _savePreferredQuality(quality);
        _userIntendedPosition = position;
        eventListener?.onQualityChanged(quality);
      } catch (e) {
        _logger.logError(message: '切换清晰度失败', error: e);
        errorMessage.value = ErrorHandler.getErrorMessage(e);
      } finally {
        isSwitchingQuality.value = false;
      }

      // 切换完毕后恢复暂存的 Seek 操作
      final pendingSeek = _pendingSeekAfterSwitch;
      _pendingSeekAfterSwitch = null;
      if (pendingSeek != null && !_isDisposed && _player != null) {
        _isSeeking = true;
        try {
          await _seekInternal(pendingSeek);
        } finally {
          _isSeeking = false;
        }
      }
    });
  }

  // ===========================================================================
  // 8. 进度追踪与 UI 更新 (Slider 与 Pili_Plus 风格封装)
  // ===========================================================================

  void onSliderDragStart() {
    isSliderMoving.value = true;
  }

  void onSliderDragUpdate(Duration position) {
    _sliderPosition = position;
    _updateSliderPositionSecond();
  }

  void onSliderDragEnd(Duration position) {
    isSliderMoving.value = false;
    _sliderPosition = position;
    _updateSliderPositionSecond();
    seek(position);
  }

  void _updatePositionState(Duration position) {
    _position = position;
    _updatePositionSecond();
    _positionStreamController.add(position);
    _userIntendedPosition = position;

    if (eventListener != null && position.inSeconds > 0) {
      final diff = (position.inMilliseconds - _lastReportedPosition.inMilliseconds).abs();
      if (diff >= 500) {
        _lastReportedPosition = position;
        eventListener!.onProgressUpdate(position, _player!.state.duration);
      }
    }
  }

  void _updateSliderPositionSecond() {
    _updateNotifierValue(sliderPositionSeconds, _sliderPosition.inSeconds);
  }

  void _updatePositionSecond() {
    if (!isSliderMoving.value) {
      _sliderPosition = _position;
      _updateSliderPositionSecond();
    }
  }

  void _updateDurationSecond() {
    _updateNotifierValue(durationSeconds, _player?.state.duration.inSeconds ?? 0);
  }

  void _updateBufferedSecond() {
    final player = _player;
    if (player == null) {
      _updateNotifierValue(bufferedSeconds, 0);
      return;
    }

    _applyBufferedBarEnd(player, cacheRangeEnd: 0);

    if (_supportsDash) {
      _tryGetVideoCacheRangeEndSeconds().then((rangeEnd) {
        if (_isDisposed || _player != player) return;
        _applyBufferedBarEnd(_player!, cacheRangeEnd: rangeEnd);
      });
    }
  }

  void _applyBufferedBarEnd(Player player, {required int cacheRangeEnd}) {
    final pos = player.state.position.inSeconds;
    final dur = player.state.duration.inSeconds;
    final demuxerEnd = player.state.buffer.inSeconds;
    var endAbs = math.max(demuxerEnd, cacheRangeEnd);
    endAbs = math.max(endAbs, pos + _minBufferedBarAheadSeconds);
    if (dur > 0) {
      endAbs = math.min(endAbs, dur);
    }
    _updateNotifierValue(bufferedSeconds, endAbs);
  }

  Future<void> fetchAndRestoreProgress() async {
    if (_isDisposed) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastProgressFetchTime != null && now - _lastProgressFetchTime! < 500) return;
    _lastProgressFetchTime = now;

    if (_currentVid == null) return;
    final sessionId = _playbackSessionId;

    if (!isPlayerInitialized.value) {
      Future.delayed(const Duration(milliseconds: 500), () async {
        if (_isSessionActive(sessionId) && _currentVid != null) {
          await _doFetchAndRestoreProgress();
        }
      });
      return;
    }
    await _doFetchAndRestoreProgress();
  }

  Future<void> _doFetchAndRestoreProgress() async {
    if (_currentVid == null) return;
    final requestVid = _currentVid!;
    final requestPart = _currentPart;

    try {
      final historyService = HistoryService();
      final progressData = await historyService.getProgress(vid: requestVid, part: requestPart);

      if (_isDisposed || _currentVid != requestVid || _currentPart != requestPart) return;
      if (progressData == null) return;

      final targetPos = _restoreTargetSecondsFromHistory(progressData);
      if (targetPos == null) return;

      final currentPos = player.state.position.inSeconds;
      if ((targetPos - currentPos).abs() <= 3) return;

      if (targetPos < currentPos &&
          currentPos - targetPos <= _restoreBackwardIgnoreMaxSeconds) {
        return;
      }

      _playbackLog('history restore seek current=${currentPos}s -> target=${targetPos}s vid=$requestVid part=$requestPart');
      await seek(Duration(seconds: targetPos));
    } catch (e) {
      _logger.logWarning('恢复播放进度失败: $e');
    }
  }

  int? _restoreTargetSecondsFromHistory(PlayProgressData data) {
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

  void _armPlaybackPositionGuard(Duration anchor) {
    _playbackPositionGuardAnchor = anchor;
    _playbackPositionGuardUntil =
        DateTime.now().add(const Duration(milliseconds: _playbackPositionGuardMs));
  }

  // ===========================================================================
  // 9. 事件监听 (Player Streams)
  // ===========================================================================

  void startListeners() {
    if (_player == null || _listenersStarted) return;
    _listenersStarted = true;
    final sessionId = _playbackSessionId;

    _subscriptions.addAll([
      _player!.stream.playing.listen((playing) {
        if (!_isSessionActive(sessionId)) return;
        if (playing && _hasTriggeredCompletion) _hasTriggeredCompletion = false;
        eventListener?.onPlayingStateChanged(playing);
        WakelockManager.toggle(enable: playing);
      }),

      _player!.stream.completed.listen((completed) {
        if (!_isSessionActive(sessionId)) return;
        if (_isDisposed || _isDisposing) return;
        
        if (completed && !_hasTriggeredCompletion && !_isSeeking && !isSwitchingQuality.value) {
          final pos = _player!.state.position;
          final dur = _player!.state.duration;
          final isRealEnd = isRealCompletion(pos.inMilliseconds, dur.inMilliseconds);
          _playbackLog(
            'stream.completed true pos=${pos.inMilliseconds}ms dur=${dur.inMilliseconds}ms '
            'isRealEnd=$isRealEnd switchingQ=${isSwitchingQuality.value}',
          );

          if (!isRealEnd && pos.inSeconds > 0) {
            final progress = dur.inSeconds > 0 ? pos.inMilliseconds / dur.inMilliseconds : 1.0;
            _logger.logDebug('断网假完成检测: progress=${(progress * 100).toInt()}%, 尝试重试');
            _handleStalled();
            return;
          }

          _hasTriggeredCompletion = true;
          _hasJustCompleted = true;
          _notifyVideoEndOnce();
        }
        if (!completed) {
          _hasTriggeredCompletion = false;
        }
      }),

      _player!.stream.position.listen((position) {
        if (!_isSessionActive(sessionId) || _isDisposed || _isDisposing || _isSeeking) return;
        final guard = _playbackPositionGuardUntil;
        if (guard != null &&
            DateTime.now().isBefore(guard) &&
            position.inMilliseconds + _spuriousBackwardJumpMs <
                _playbackPositionGuardAnchor.inMilliseconds) {
          final now = DateTime.now();
          final last = _lastPlaybackBackwardLogAt;
          if (last == null || now.difference(last).inMilliseconds > 600) {
            _lastPlaybackBackwardLogAt = now;
            _playbackLog(
              'position guard drop pos=${position.inMilliseconds}ms anchor=${_playbackPositionGuardAnchor.inMilliseconds}ms '
              'until=${guard.toIso8601String()}',
            );
          }
          return;
        }
        if (isSwitchingQuality.value && position.inSeconds <= 1) return;

        if (!_hasPlaybackStarted) {
          if (position.inSeconds == 0) return;
          _hasPlaybackStarted = true;
        }

        if (position.inSeconds <= 1 && _hasJustCompleted) {
          _hasJustCompleted = false;
        }

        // 循环重播检测
        if (loopMode.value == LoopMode.on && !isSwitchingQuality.value && !_isSeeking &&
            position.inSeconds <= 1 && _lastReportedPosition.inSeconds > 5) {
          final dur = _player?.state.duration ?? Duration.zero;
          if (isRealCompletion(_lastReportedPosition.inMilliseconds, dur.inMilliseconds) && dur.inSeconds > 0) {
            _playbackLog(
              'loop-file 循环重播检测 -> onVideoEnd lastReported=${_lastReportedPosition.inSeconds}s dur=${dur.inSeconds}s',
            );
            _notifyVideoEndOnce();
          }
        }

        final prevMs = _position.inMilliseconds;
        final curMs = position.inMilliseconds;
        if (curMs + 2500 < prevMs && prevMs > 3000 && !_isSeeking) {
          final now = DateTime.now();
          final last = _lastPlaybackBackwardLogAt;
          if (last == null || now.difference(last).inMilliseconds > 800) {
            _lastPlaybackBackwardLogAt = now;
            _playbackLog(
              'position backward jump ${prevMs}ms -> ${curMs}ms '
              'dur=${_player?.state.duration.inMilliseconds ?? 0}ms',
            );
          }
        }

        // PTS 调试日志
        if (position.inSeconds % 10 == 0 && position.inSeconds > 0 && _lastPtsLoggedSecond != position.inSeconds) {
          _lastPtsLoggedSecond = position.inSeconds;
          _logPtsState();
        }

        _updatePositionState(position);
        if (position > Duration.zero && !hasEverPlayed.value) {
          hasEverPlayed.value = true;
        }
      }),

      _player!.stream.duration.listen((duration) {
        if (!_isSessionActive(sessionId)) return;
        if (duration > Duration.zero) _updateDurationSecond();
      }),

      _player!.stream.buffer.listen((buffer) {
        if (!_isSessionActive(sessionId)) return;
        _updateBufferedSecond();
      }),

      _player!.stream.buffering.listen((buffering) {
        if (!_isSessionActive(sessionId)) return;
        if (buffering) {
          _bufferingShowTimer?.cancel();
          _bufferingShowTimer = Timer(const Duration(milliseconds: _bufferingSustainMs), () {
            _bufferingShowTimer = null;
            if (_isSessionActive(sessionId) && _player!.state.buffering) {
              isBuffering.value = true;
            }
          });
          _stalledTimer?.cancel();
          _stalledTimer = Timer(const Duration(seconds: 15), () {
            if (_isSessionActive(sessionId) && _player!.state.buffering) {
              _handleStalled();
            }
          });
        } else {
          _bufferingShowTimer?.cancel();
          _bufferingShowTimer = null;
          isBuffering.value = false;
          _stalledTimer?.cancel();
        }
      }),

      _player!.stream.error.listen((error) {
        if (!_isSessionActive(sessionId)) return;
        if (error.isEmpty) return;
        _logger.logDebug('播放错误: $error');

        if (error.startsWith('tcp: ') || error.startsWith('Failed to open ') ||
            error.startsWith('Can not open external file ')) {
          Future.delayed(const Duration(seconds: 3), () {
            if (!_isSessionActive(sessionId)) return;
            if (_player!.state.buffering && _player!.state.buffer == Duration.zero) {
              _logger.logDebug('网络错误确认: buffering 且缓冲为空, 重试');
              _handleStalled();
            }
          });
        }
      }),

      _player!.stream.log.listen((log) {
        if (!_isSessionActive(sessionId)) return;
        if (log.prefix == 'av_sync' || log.prefix == 'audio' || log.prefix == 'cplayer' ||
            log.text.contains('patients') || log.text.contains('A-V:') ||
            log.text.contains('sync') || log.text.contains('drop') ||
            log.text.contains('delay') || log.text.contains('underrun') ||
            log.text.contains('reset') || log.text.contains('timestamp') ||
            log.text.contains('desync')) {
          _logger.logDebug('[mpv:${log.prefix}] ${log.text}');
        }
      }),
    ]);

    _connectivitySubscription ??= Connectivity().onConnectivityChanged.listen((results) {
      final isConnected = results.any((r) => r != ConnectivityResult.none);
      if (isConnected && errorMessage.value != null) {
        errorMessage.value = null;
        _handleStalled();
      }
    });
  }

  void removeListeners() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions =[];
    _listenersStarted = false;
    _stalledTimer?.cancel();
    _stalledTimer = null;
    _seekTimer?.cancel();
    _seekTimer = null;
    _bufferingShowTimer?.cancel();
    _bufferingShowTimer = null;
  }

  // ===========================================================================
  // 10. 音频会话、生命周期与设置管理
  // ===========================================================================

  Future<void> _initAudioSession() async {
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

  void _handleAudioInterruption(AudioInterruptionEvent event) {
    if (_player == null || _isDisposed) return;
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          _player!.setVolume((_player!.state.volume * 0.5).clamp(0, 100));
          break;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          _wasPlayingBeforeInterruption = _player!.state.playing;
          if (_wasPlayingBeforeInterruption) pause(isInterrupt: true);
          break;
      }
    } else {
      switch (event.type) {
        case AudioInterruptionType.duck:
          _player!.setVolume((_player!.state.volume * 2).clamp(0, 100));
          break;
        case AudioInterruptionType.pause:
          if (_wasPlayingBeforeInterruption) {
            _wasPlayingBeforeInterruption = false;
            if (_player != null && !_isDisposed && !_player!.state.playing) play();
          }
          break;
        case AudioInterruptionType.unknown:
          _wasPlayingBeforeInterruption = false;
          break;
      }
    }
  }

  void _handleBecomingNoisy() {
    if (_player == null || _isDisposed) return;
    if (_player!.state.playing) pause();
  }

  void handleAppLifecycleState(bool isPaused) {
    if (_player == null || _isDisposed) return;

    if (isPaused) {
      if (!backgroundPlayEnabled.value) pause();
      final pos = _player!.state.position;
      if (pos.inSeconds > 0) _userIntendedPosition = pos;
    } else {
      if (_videoTitle != null) {
        audioHandler.setMediaItem(
          id: _currentResourceId?.toString() ?? '',
          title: _videoTitle!,
          artist: _videoAuthor,
          artUri: _videoCoverUri,
        );
      }
    }
  }

  Future<void> toggleBackgroundPlay() async {
    backgroundPlayEnabled.value = !backgroundPlayEnabled.value;
    final prefs = await _preferences;
    await prefs.setBool(_backgroundPlayKey, backgroundPlayEnabled.value);
  }

  Future<void> toggleLoopMode() async {
    final nextMode = (loopMode.value.index + 1) % LoopMode.values.length;
    loopMode.value = LoopMode.values[nextMode];
    await _syncLoopProperty();
    final prefs = await _preferences;
    await prefs.setInt(_loopModeKey, loopMode.value.index);
  }

  // ===========================================================================
  // 11. Helper 辅助方法
  // ===========================================================================

  int _nextPlaybackSessionId() => ++_playbackSessionId;

  bool _isSessionActive(int sessionId) => !_isDisposed && _player != null && _playbackSessionId == sessionId;

  /// 调试：统一前缀，在 kDebugMode 下经 [LoggerService.logDebug] 输出到控制台
  void _playbackLog(String message) {
    _logger.logDebug(message, tag: 'Playback');
  }

  void _resetPlaybackStates() {
    _bufferingShowTimer?.cancel();
    _bufferingShowTimer = null;
    isBuffering.value = false;
    hasEverPlayed.value = false;
    _hasPlaybackStarted = false;
    _hasTriggeredCompletion = false;
    _hasJustCompleted = false;
    _isSeeking = false;
    _pendingSeekAfterSwitch = null;
    _playbackPositionGuardUntil = null;
    _playbackPositionGuardAnchor = Duration.zero;
    _lastReportedPosition = Duration.zero;
    _lastPtsLoggedSecond = -1;
    _playbackLog('resetPlaybackStates session=$_playbackSessionId');
  }

  void setInitialDurationHint(double? duration) {
    if (duration == null || duration <= 0) return;
    durationSeconds.value = duration.toInt();
  }

  void setVideoMetadata({required String title, String? author, Uri? coverUri}) {
    _videoTitle = title;
    _videoAuthor = author;
    _videoCoverUri = coverUri;
    audioHandler.setMediaItem(
      id: _currentResourceId?.toString() ?? '',
      title: title,
      artist: author,
      artUri: coverUri,
    );
  }

  void setVideoContext({required String vid, String? rid, int part = 1}) {
    _currentVid = vid;
    _currentRid = rid;
    _currentPart = part;
  }

  String getQualityDisplayName(String quality) => getQualityLabel(quality);

  Future<void> _enqueueOperation(Future<void> Function() operation) {
    _operationQueue = _operationQueue.then((_) => operation()).catchError((e, st) {
      _logger.logError(message: '播放操作队列执行失败', error: e, stackTrace: st is StackTrace ? st : StackTrace.current);
    });
    return _operationQueue;
  }

  Future<void> _seekInternal(Duration position) async {
    await _seekBufferWaitIfNeeded();

    if (_player!.state.duration.inSeconds != 0) {
      _playbackLog('seekInternal ${position.inMilliseconds}ms (duration ready)');
      await _player!.seek(position);
      if (!_isDisposed && _player != null) {
        _armPlaybackPositionGuard(position);
      }
    } else {
      _seekTimer?.cancel();
      _seekTimer = Timer.periodic(const Duration(milliseconds: 200), (Timer t) async {
        if (_isDisposed || _player == null) {
          t.cancel();
          _seekTimer = null;
          _isSeeking = false;
          return;
        }
        if (_player!.state.duration.inSeconds != 0) {
          t.cancel();
          _seekTimer = null;
          await _seekBufferWaitIfNeeded();
          if (_isDisposed || _player == null) return;
          try {
            await _player!.seek(position);
            if (!_isDisposed && _player != null) {
              _armPlaybackPositionGuard(position);
            }
          } catch (e) {
            _logger.logWarning('seek 执行失败: $e');
          }
          _isSeeking = false;
        }
      });
    }
  }

  Future<void> _seekBufferWaitIfNeeded() async {
    if (_player == null || _player!.state.buffer != Duration.zero) return;
    try {
      await _player!.stream.buffer.first.timeout(const Duration(milliseconds: 300));
    } catch (_) {
      // 超时是正常情况，不需要日志
    }
  }

  void _notifyVideoEndOnce() {
    final now = DateTime.now();
    if (_lastVideoEndAt != null && now.difference(_lastVideoEndAt!).inMilliseconds < _videoEndDebounceMs) {
      _playbackLog(
        'onVideoEnd debounced (${now.difference(_lastVideoEndAt!).inMilliseconds}ms since last)',
      );
      return;
    }
    _lastVideoEndAt = now;
    _playbackLog('onVideoEnd -> eventListener');
    eventListener?.onVideoEnd();
  }

  void _updateNotifierValue(ValueNotifier<int> notifier, int newValue) {
    if (notifier.value != newValue) notifier.value = newValue;
  }

  Future<void> _waitForVideoReadyBeforePlay(int sessionId) async {
    if (_player == null) return;
    final completer = Completer<void>();
    final subs = <StreamSubscription>[];

    void tryComplete() {
      if (completer.isCompleted || !_isSessionActive(sessionId)) return;
      final w = _player?.state.width ?? 0;
      final h = _player?.state.height ?? 0;
      final bufMs = _player?.state.buffer.inMilliseconds ?? 0;
      if ((w > 0 && h > 0 && bufMs >= 1200) || bufMs >= 2500) {
        if (!completer.isCompleted) completer.complete();
      }
    }

    subs.add(_player!.stream.width.listen((_) => tryComplete()));
    subs.add(_player!.stream.height.listen((_) => tryComplete()));
    subs.add(_player!.stream.buffer.listen((_) => tryComplete()));

    final timeout = Timer(Duration(milliseconds: _startupReadyTimeoutMs), () {
      if (!completer.isCompleted) completer.complete();
    });

    tryComplete();
    await completer.future;
    timeout.cancel();
    for (final sub in subs) { sub.cancel(); }

    if (_videoController != null && _isSessionActive(sessionId)) {
      try {
        await _videoController!.waitUntilFirstFrameRendered
            .timeout(const Duration(milliseconds: 1200));
      } catch (_) {}
    }
  }

  Future<void> _handleStalled() async {
    await _enqueueOperation(() async {
      if (_isHandlingStall || _isInitializing || isLoading.value || isSwitchingQuality.value || _isSeeking || _seekInFlight) return;
      if (_lastSeekAt != null && DateTime.now().difference(_lastSeekAt!).inSeconds < 4) return;
      if (_currentResourceId == null || currentQuality.value == null || _player == null) return;

      _isHandlingStall = true;
      try {
        final currentPos = _player!.state.position;
        if (currentPos <= Duration.zero) return;

        // 先上报故障并强制切换线路（视频卡顿优先换线恢复，而非死磕当前线路）
        final line = NetworkLineSelector().selectedLine;
        if (line != null) {
          _playbackLog('_handleStalled 上报 $line 故障 + 强制切换线路');
          NetworkLineSelector().reportLineFailure(line);
          NetworkLineSelector().forceSwitchLine();
        }

        _playbackLog('_handleStalled reload quality=${currentQuality.value} pos=${currentPos.inSeconds}s');
        await _reloadWithDataSource(currentQuality.value!, currentPos);
        _userIntendedPosition = currentPos;
      } catch (e) {
        _logger.logWarning('_handleStalled 失败: $e');
      } finally {
        _isHandlingStall = false;
      }
    });
  }

  Future<void> _reloadWithDataSource(String? quality, Duration position) async {
    final targetQuality = quality ?? currentQuality.value;
    if (targetQuality == null || _currentResourceId == null) return;

    final dataSource = await _getDataSourceForQuality(targetQuality);
    if (_isDisposed) return;

    await setDataSource(dataSource, seekTo: position.inSeconds > 0 ? position : Duration.zero, autoPlay: true);
  }

  Future<DataSource> _getDataSourceForQuality(String quality) async {
    if (_supportsDash && _manifest != null) {
      if (_manifest!.isExpired && _currentResourceId != null) {
        _manifest = await _streamService.getDashManifest(_currentResourceId!);
      }
      final ds = _manifest!.getDataSource(quality);
      if (ds != null) return ds;
    }
    return _streamService.getM3u8DataSource(_currentResourceId!, quality);
  }

  Future<void> _syncLoopProperty() async {
    if (_player == null) return;
    try {
      _player!.setProperty('loop-file', loopMode.value == LoopMode.on ? 'inf' : 'no');
    } catch (e) {
      _logger.logWarning('设置循环模式失败: $e');
    }
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await _preferences;
      backgroundPlayEnabled.value = prefs.getBool(_backgroundPlayKey) ?? false;
      final loopModeValue = prefs.getInt(_loopModeKey) ?? 0;
      loopMode.value = LoopMode.values[loopModeValue];
      _settingsLoaded = true;
    } catch (e) {
      _logger.logWarning('加载播放器设置失败: $e');
    }
  }

  Future<String> _getPreferredQuality(List<String> qualities) async {
    try {
      final prefs = await _preferences;
      final preferredName = prefs.getString(_preferredQualityKey);
      return findBestQualityMatch(qualities, preferredName);
    } catch (e) {
      _logger.logWarning('获取首选清晰度失败: $e');
    }
    return getDefaultQuality(qualities);
  }

  Future<void> _savePreferredQuality(String quality) async {
    try {
      final prefs = await _preferences;
      await prefs.setString(_preferredQualityKey, formatQualityDisplayName(quality));
    } catch (e) {
      _logger.logWarning('保存首选清晰度失败: $e');
    }
  }

  /// 从 demuxer-cache-state 解析视频缓存区间右端点（时间轴绝对秒数，失败返回 0）
  Future<int> _tryGetVideoCacheRangeEndSeconds() async {
    try {
      final cacheStr = await _player!.getProperty('demuxer-cache-state');
      if (cacheStr.isEmpty) return 0;
      final videoRangeMatch =
          RegExp(r'video\[\d+\]:\s*([\d.]+)\s*-\s*([\d.]+)', caseSensitive: false)
              .firstMatch(cacheStr);
      if (videoRangeMatch != null) {
        final end = double.tryParse(videoRangeMatch.group(2) ?? '') ?? 0.0;
        if (end > 0) return end.ceil();
      }
    } catch (e) {
      _logger.logDebug('获取视频缓冲区间失败: $e');
    }
    return 0;
  }

  Future<void> _logPtsState() async {
    if (_player == null) return;
    try {
      final videoPtsStr = await _player!.getProperty('video-pts');
      final audioPtsStr = await _player!.getProperty('audio-pts');
      final avsyncStr = await _player!.getProperty('avsync');
      final videoPts = double.tryParse(videoPtsStr) ?? 0;
      final audioPts = double.tryParse(audioPtsStr) ?? 0;
      final avsync = double.tryParse(avsyncStr) ?? 0;
      _logger.logDebug('[PTS] video=${videoPts.toStringAsFixed(3)}s, audio=${audioPts.toStringAsFixed(3)}s, avsync=${avsync.toStringAsFixed(3)}s');
    } catch (_) {
      // PTS 日志是诊断用，获取失败静默忽略
    }
  }

  @visibleForTesting
  static bool hasValidVideoSize(String raw) {
    if (raw.isEmpty) return false;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map) {
        final w = (parsed['w'] as num?)?.toInt() ?? 0;
        final h = (parsed['h'] as num?)?.toInt() ?? 0;
        return w > 0 && h > 0;
      }
    } catch (_) {
      // JSON 解析失败表示 raw 不是有效 JSON，正常返回 false
    }
    return false;
  }

  @visibleForTesting
  static bool isRealCompletion(int posMs, int durMs) {
    if (durMs <= 0) return true;
    final progress = posMs / durMs;
    return progress >= 0.9;
  }

  // ===========================================================================
  // 11b. 外挂字幕（须在 [Player.open] 成功之后挂载，与 web「先播再 hydrate」同源顺序）
  // ===========================================================================

  Future<void> _syncExternalSubtitleTracks(int sessionId) async {
    final key = _subtitleResourceKey;
    if (key == null || key.isEmpty || _player == null) return;
    try {
      final list = await SubtitleApiService.fetchTracks(key);
      if (!_isSessionActive(sessionId)) return;

      subtitleTracks.value = List<SubtitleTrackItem>.from(list);

      if (list.isEmpty) {
        selectedSubtitleIndex.value = null;
        await _player!.setSubtitleTrack(SubtitleTrack.no());
        return;
      }

      final preferredIdx = await PlayerSettingsService.pickPreferredSubtitleTrackIndex(list);
      if (preferredIdx < list.length) {
        await _applySubtitleTrackItem(sessionId, list[preferredIdx], preferredIdx);
        return;
      }
      final def = list.indexWhere((t) => t.isDefault);
      final idx = def >= 0 ? def : 0;
      await _applySubtitleTrackItem(sessionId, list[idx], idx);
      return;
    } catch (e) {
      _logger.logWarning('字幕列表加载失败: $e');
      if (!_isSessionActive(sessionId)) return;
      subtitleTracks.value = [];
      selectedSubtitleIndex.value = null;
      try {
        await _player?.setSubtitleTrack(SubtitleTrack.no());
      } catch (_) {/* noop */}
    }
  }

  Future<void> _applySubtitleTrackItem(
    int sessionId,
    SubtitleTrackItem item,
    int index, {
    bool persistPreference = false,
  }) async {
    if (!_isSessionActive(sessionId) || _player == null) return;
    try {
      // 根据网络线路决定首次尝试的 URL，失败后自动降级到另一条（多 OSS 容灾）
      final line = NetworkLineSelector().selectedLine;
      final candidates = <String>[];
      if (line == NetworkLine.backup && item.backupUrl != null) {
        candidates.add(item.backupUrl!);
        candidates.add(item.url);
      } else {
        candidates.add(item.url);
        if (item.backupUrl != null) candidates.add(item.backupUrl!);
      }
      String? text;
      for (final url in candidates) {
        try {
          text = await SubtitleApiService.fetchVttPlain(url);
          break;
        } catch (e) {
          _logger.logWarning('字幕线路降级: lang=${item.lang} url=$url err=$e');
        }
      }
      if (text == null) {
        _logger.logWarning('字幕所有线路均失败: lang=${item.lang}');
        // 上报当前线路故障，触发重探
        final currentLine = NetworkLineSelector().selectedLine;
        if (currentLine != null) {
          NetworkLineSelector().reportLineFailure(currentLine);
        }
        return;
      }
      if (!_isSessionActive(sessionId) || _player == null) return;
      try {
        _player!.setProperty('sub-visibility', 'no');
        _player!.setProperty('sub-ass', 'no');
        _player!.setProperty('sub-border-style', 'outline-and-shadow');
        _player!.setProperty('sub-back-color', '#00000000');
        _player!.setProperty('sub-shadow-offset', '0');
      } catch (_) {}
      await _player!.setSubtitleTrack(
        SubtitleTrack.data(
          text,
          title: item.displayLabel,
          language: item.lang,
        ),
      );
      try {
        _player!.setProperty('sub-visibility', 'no');
        _player!.setProperty('sub-ass', 'no');
        _player!.setProperty('sub-border-style', 'outline-and-shadow');
        _player!.setProperty('sub-back-color', '#00000000');
        _player!.setProperty('sub-shadow-offset', '0');
      } catch (_) {}
      if (_isSessionActive(sessionId)) {
        selectedSubtitleIndex.value = index;
        if (persistPreference) {
          unawaited(
            PlayerSettingsService.saveSubtitlePreference(
              label: item.displayLabel,
              lang: item.lang,
            ),
          );
        }
      }
    } catch (e) {
      _logger.logWarning('字幕挂载失败 (${item.lang}): $e');
    }
  }

  Future<void> selectSubtitleIndex(int index, {bool persistPreference = true}) async {
    if (_player == null) return;
    final list = subtitleTracks.value;
    if (index < 0 || index >= list.length) return;
    final sid = _playbackSessionId;
    await _applySubtitleTrackItem(sid, list[index], index,
        persistPreference: persistPreference);
  }

  Future<void> toggleSubtitleQuick() async {
    if (_player == null) return;
    final tracks = subtitleTracks.value;
    if (tracks.isEmpty) return;
    if (selectedSubtitleIndex.value != null) {
      await disableSubtitles();
      return;
    }
    final i = await PlayerSettingsService.pickPreferredSubtitleTrackIndex(tracks);
    await selectSubtitleIndex(i, persistPreference: false);
  }

  Future<void> disableSubtitles() async {
    if (_player == null) return;
    final sid = _playbackSessionId;
    try {
      await _player!.setSubtitleTrack(SubtitleTrack.no());
    } catch (e) {
      _logger.logWarning('关闭字幕失败: $e');
    }
    if (_isSessionActive(sid)) {
      selectedSubtitleIndex.value = null;
    }
  }

  // ===========================================================================
  // 12. 释放资源 Dispose
  // ===========================================================================

  Future<void> _disposeAudioSession() async {
    try {
      await _audioSession?.setActive(false);
    } catch (e) {
      _logger.logDebug('释放音频焦点失败: $e');
    }
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    _interruptionSubscription = null;
    _becomingNoisySubscription = null;
    _audioSession = null;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposing = true;
    _isDisposed = true;

    WakelockManager.disable();
    await _disposeAudioSession();

    eventListener = null;
    removeListeners();
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;

    await audioHandler.stopIfOwner(_audioOwnerId);
    audioHandler.detachPlayerIfOwner(_audioOwnerId);

    _manifest = null;
    _cacheService.cleanupAllTempCache();

    if (_player != null) {
      await _player!.dispose();
      _player = null;
    }

    _positionStreamController.close();

    availableQualities.dispose();
    currentQuality.dispose();
    isLoading.dispose();
    errorMessage.dispose();
    isPlayerInitialized.dispose();
    isSwitchingQuality.dispose();
    loopMode.dispose();
    backgroundPlayEnabled.dispose();
    isBuffering.dispose();
    hasEverPlayed.dispose();
    sliderPositionSeconds.dispose();
    durationSeconds.dispose();
    bufferedSeconds.dispose();
    isSliderMoving.dispose();
    subtitleTracks.dispose();
    selectedSubtitleIndex.dispose();

    super.dispose();
  }
}