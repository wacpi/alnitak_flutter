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
import 'package:connectivity_plus/connectivity_plus.dart';

import '../services/video_stream_service.dart';
import '../services/cache_service.dart';
import '../services/logger_service.dart';
import '../services/player_settings_service.dart';
import '../services/audio_focus_service.dart';
import '../services/playback_progress_service.dart';
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
  // Enable only for a targeted native-player investigation:
  // flutter run --dart-define=ALNITAK_MPV_TRACE=true
  // Full trace emits hundreds of native log lines per second and makes a debug
  // build visibly janky when every line is bridged to Dart and written to disk.
  static const bool _enableMpvTrace =
      bool.fromEnvironment('ALNITAK_MPV_TRACE', defaultValue: false);
  // ===========================================================================
  // 1. 服务与基础依赖
  // ===========================================================================
  final VideoStreamService _streamService = VideoStreamService();
  final CacheService _cacheService = CacheService();
  final LoggerService _logger = LoggerService.instance;

  /// 音频焦点管理（会话配置/中断/becomingNoisy）
  late final AudioFocusService _audioFocus;

  /// 播放进度恢复
  late final PlaybackProgressService _progressService;

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
  final ValueNotifier<bool> hasEverPlayed =
      ValueNotifier(false); // 区分首次加载与播放中缓冲
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

  /// 当前会话是否已应用过保存的清晰度偏好（原生 DASH 轨道覆盖，每会话一次）
  bool _preferredQualityAppliedForSession = false;
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

  /// 当前 [_manifest] 所属线路（primary/backup），用于换线后强制重取
  NetworkLine? _manifestLine;
  String? _currentVid;

  // ignore: unused_field
  String? _currentRid; // 保留以备将来使用（如进度上报）
  int _currentPart = 1;
  String? _videoTitle;
  String? _videoAuthor;
  Uri? _videoCoverUri;

  // 音频中断处理（逻辑委托 AudioFocusService）

  // 常量与防抖控制
  int _lastPtsLoggedSecond = -1;
  DateTime? _lastVideoEndAt;
  DateTime? _lastPlaybackBackwardLogAt;
  static const int _bufferingSustainMs = 1500;
  static const int _videoEndDebounceMs = 800;
  static const int _playbackPositionGuardMs = 2000;
  static const int _spuriousBackwardJumpMs = 1600;

  /// DASH MPD 定时续签提前量（ms）：key TTL 到期前 30 分钟触发
  static const int _dashRefreshAheadMs = 30 * 60 * 1000;

  /// DASH key 有效期（ms）：服务端 Redis 24h
  static const int _dashKeyTtlMs = 24 * 60 * 60 * 1000;

  // ===========================================================================
  // 5. 各种订阅与定时器
  // ===========================================================================
  PlayerEventListener? eventListener;
  VoidCallback? onReplayAfterCompletion;

  final StreamController<Duration> _positionStreamController =
      StreamController.broadcast();
  Stream<Duration> get positionStream => _positionStreamController.stream;

  List<StreamSubscription> _subscriptions = [];
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  Timer? _stalledTimer;
  Timer? _seekTimer;
  Timer? _bufferingShowTimer;
  Timer? _dashRefreshTimer;
  bool _cacheRangeLookupInFlight = false;
  int _cacheRangeLookupGeneration = 0;

  /// 最近一次成功解析出的音视频共同缓存区间右端点（绝对时间轴秒）。
  /// 作用会话内粘性权威终点（sticky）：后续查询失败时钳制兜底，
  /// 保证缓冲条既不因查询失败而塌缩消失，也绝不超前到真实音视频共同缓存之外。
  double _lastAuthoritativeMediaCacheRangeEndSeconds = 0;

  /// 本会话是否已成功解析过至少一次权威音视频共同缓存终点。
  bool _hasAuthoritativeMediaCacheRangeThisSession = false;
  bool _dashTokenRefreshed = false;

  VideoPlayerController() {
    _audioFocus = AudioFocusService(
      isPlaying: () => _player?.state.playing ?? false,
      onPause: ({bool isInterrupt = false}) => pause(isInterrupt: isInterrupt),
      onResumePlay: () async {
        if (_player != null && !_isDisposed && !_player!.state.playing) {
          await play();
        }
      },
      onDuck: (duck) {
        if (_player == null || _isDisposed) return;
        final factor = duck ? 0.5 : 2.0;
        _player!.setVolume((_player!.state.volume * factor).clamp(0, 100));
      },
    );

    _progressService = PlaybackProgressService(
      isDisposed: () => _isDisposed,
      isSessionActive: _isSessionActive,
      isPlayerInitialized: () => isPlayerInitialized.value,
      currentVid: () => _currentVid,
      currentPart: () => _currentPart,
      currentPosition: () => _player?.state.position ?? Duration.zero,
      onSeek: seek,
      log: _playbackLog,
    );
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
      _dashTokenRefreshed = false;

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
      _manifestLine = NetworkLineSelector().selectedLine;
      _supportsDash = manifest.supportsDash;
      availableQualities.value = manifest.qualities;
      if (manifest.qualities.isEmpty) throw Exception('没有可用的清晰度');

      currentQuality.value =
          await _getPreferredQuality(availableQualities.value);

      if (_isDisposed || _currentResourceId != resourceId) return;

      // 获取 DataSource：DASH 直连 或回退 m3u8
      final DataSource dataSource;
      if (_supportsDash) {
        final ds = manifest.getDataSource(
          currentQuality.value!,
          preferNativeMpd: manifest.supportsNativeQualitySwitching,
        );
        if (ds == null) throw Exception('清晰度数据不可用');
        dataSource = ds;
      } else {
        dataSource = await _streamService.getM3u8DataSource(
            resourceId, currentQuality.value!);
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
      _logger.logError(
          message: '初始化失败', error: e, stackTrace: StackTrace.current);
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
    final ensureSw = Stopwatch()..start();
    _playerCreationFuture = _createPlayerInternal();
    try {
      await _playerCreationFuture;
    } finally {
      _playerCreationFuture = null;
    }
    ensureSw.stop();
    _playbackLog('_ensurePlayerReady done (${ensureSw.elapsedMilliseconds}ms)');
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
    if (_enableMpvTrace) {
      // C 方案实证：提升内核/ffmpeg 日志级别，抓 DASH 分片打开、init 下载、seek 过程
      // 关键日志（dashdec.c）：
      //   AV_LOG_DEBUG   "Downloading an initialization section of size %PRI64d"
      //   AV_LOG_VERBOSE "DASH request for url '%s', offset %PRI64d" / "DASH seek pos[..]"
      // media-kit 的 MPVLogLevel 直接映射到 mpv_request_log_messages，
      // 但 mpv 内部还有按模块的 msg-level 过滤，需显式放开 ffmpeg/lavf。
      opt['msg-level'] =
          'ffmpeg=debug,lavf=debug,cplayer=debug,demux=debug,status=no';
    }
    final bufferSizeBytes = expandBuffer ? 32 * 1024 * 1024 : 16 * 1024 * 1024;

    final createSw = Stopwatch()..start();
    _player = await Player.create(
      configuration: PlayerConfiguration(
        bufferSize: bufferSizeBytes,
        logLevel: _enableMpvTrace ? MPVLogLevel.trace : MPVLogLevel.warn,
        options: opt,
      ),
    );
    createSw.stop();
    _playbackLog(
        'Player.create() done (${createSw.elapsedMilliseconds}ms, decode=$decodeMode, buf=${bufferSizeBytes ~/ 1024 ~/ 1024}MB)');

    _audioFocus.attachPlayer(
      _player!,
      onSeek: (pos) => seek(pos),
    );

    // 音频会话初始化与 mpv 属性配置互不依赖，串行会直接增加冷启动时延。
    await Future.wait([
      _audioFocus.init(),
      _configurePlayerOnce(decodeMode),
    ]);

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

    // 基础播放配置（与媒体源格式无关）
    _player!.setProperty('video-sync', 'audio');
    _player!.setProperty('interpolation', 'no');
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

  /// 按数据源模式设置 mpv 流相关属性（在 open 前调用）
  ///
  /// - 原生 DASH MPD：mpv 通过 libavformat 直接解析整个 MPD，
  ///   音视频/多清晰度由播放器原生处理，恢复 mpv 默认 seek/缓存行为。
  /// - 分离流回退（JSON/m3u8）：保持音视频分离流所需的补丁参数。
  Future<void> _applyStreamModeProperties(bool nativeMpd) async {
    if (_player == null) return;
    try {
      if (nativeMpd) {
        // 恢复 mpv 默认：允许 demuxer 正常回读，seek 交给播放器原生精确处理
        // demuxer-max-back-bytes 是整数类型选项（默认 50 MiB），不能传 'default' 字符串
        _player!.setProperty('hr-seek', 'default');
        _player!.setProperty('demuxer-max-back-bytes', '52428800');
        _player!.setProperty('demuxer-readahead-secs', '10');
      } else {
        // 音视频分离流：精确 seek 以防 A/V 不同步，限制 demuxer 回读规避 PTS 回溯
        _player!.setProperty('hr-seek', 'yes');
        _player!.setProperty('demuxer-max-back-bytes', '0');
        _player!.setProperty('demuxer-readahead-secs', '12');
      }
    } catch (e) {
      _logger.logDebug('设置流模式属性失败: $e');
    }
  }

  // ===========================================================================
  // 7. 数据源加载与核心播放逻辑
  // ===========================================================================

  /// 设置播放数据源
  Future<void> setDataSource(
    DataSource dataSource, {
    Duration seekTo = Duration.zero,
    bool autoPlay = true,
    bool retainAudioFocus = false,
  }) async {
    if (_isDisposed) return;
    final sessionId = _nextPlaybackSessionId();
    // 仅在本次确实申请过音频焦点时，才在失败路径归还，避免误释放前一次会话持有的焦点。
    var audioFocusActivated = false;

    try {
      isLoading.value = true;

      if (_player != null && _player!.state.playing) {
        // 同一视频切档无需释放/重新申请音频焦点，避免 Android 音频会话往返
        // 造成首帧和声音恢复额外等待。
        if (retainAudioFocus) {
          await _player!.pause();
        } else {
          await pause();
        }
      }

      removeListeners();
      _resetPlaybackStates();

      // 防止 UI 闪跳位置 0
      _position = _sliderPosition = seekTo;
      _updateSliderPositionSecond();
      // 新数据源不能沿用旧媒体的缓冲长度；在收到新流事件前缓冲终点就是 seek 点。
      _updateNotifierValue(bufferedSeconds, seekTo.inSeconds);

      await _ensurePlayerReady();
      startListeners();

      final shouldPlayAfterStable = autoPlay;
      _playbackLog(
        'setDataSource begin session=$sessionId seekTo=${seekTo.inSeconds}s play=$shouldPlayAfterStable '
        'vid=$_currentVid part=$_currentPart',
      );
      _mpvTrace(
        'setDataSource begin session=$sessionId seekTo=${seekTo.inSeconds}s vid=$_currentVid part=$_currentPart',
      );

      // 原生 DASH MPD：由 mpv 解析整个 MPD（音视频 + 多清晰度），
      // 不需要 audio-files 外挂音频，也不应使用音视频分离流的补丁参数。
      // 回退路径（JSON 分离流）仍按需组装外挂音频参数。
      Map<String, String>? extras;
      if (!dataSource.nativeMpd &&
          dataSource.audioSource != null &&
          dataSource.audioSource!.isNotEmpty) {
        final escapedAudio = Platform.isWindows
            ? dataSource.audioSource!.replaceAll(';', r'\;')
            : dataSource.audioSource!.replaceAll(':', r'\:');
        extras = {'audio-files': '"$escapedAudio"'};
      }

      await _applyStreamModeProperties(dataSource.nativeMpd);
      // 先申请音频焦点，再让 mpv 在打开媒体时立即播放。以前 open(play: false)
      // 后额外等 1.5s 的“首帧就绪”闸门会让本地/已缓存视频也无谓延迟。
      if (shouldPlayAfterStable) {
        await _audioFocus.activate();
        audioFocusActivated = true;
      }
      final openSw = Stopwatch()..start();
      _mpvTrace('player.open() begin (nativeMpd=${dataSource.nativeMpd})');

      await _player!.open(
        Media(
          dataSource.videoSource,
          start: seekTo,
          extras: extras,
          httpHeaders: dataSource.httpHeaders,
        ),
        play: shouldPlayAfterStable,
      );
      openSw.stop();
      _mpvTrace('player.open() returned (${openSw.elapsedMilliseconds}ms)');

      if (!_isSessionActive(sessionId)) return;

      isLoading.value = false;
      isPlayerInitialized.value = true;
      _armPlaybackPositionGuard(seekTo);

      _startDashRefreshTimer();

      unawaited(_syncExternalSubtitleTracks(sessionId));
    } catch (e) {
      // 音频焦点在 open 之前已申请，失败时必须归还，否则会一直占用到 pause()。
      if (audioFocusActivated) {
        await _audioFocus.deactivate();
      }
      if (!_isSessionActive(sessionId)) return;
      _isSeeking = false;
      isLoading.value = false;
      errorMessage.value = ErrorHandler.getErrorMessage(e);
      _logger.logError(
          message: 'setDataSource 失败',
          error: e,
          stackTrace: StackTrace.current);
    }
  }

  Future<void> play() async {
    if (_isDisposed || _player == null) return;
    await _audioFocus.activate();
    await _player!.play();
  }

  Future<void> pause({bool isInterrupt = false}) async {
    if (_isDisposed || _player == null) return;
    await _player!.pause();
    if (!isInterrupt) {
      await _audioFocus.deactivate();
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
    if (currentQuality.value == quality ||
        _currentResourceId == null ||
        isSwitchingQuality.value) {
      return;
    }

    await _enqueueOperation(() async {
      if (_isDisposed || _player == null) return;
      if (currentQuality.value == quality || _currentResourceId == null) return;

      final playerPos = _player!.state.position;
      final position =
          playerPos.inMilliseconds > 0 ? playerPos : _userIntendedPosition;
      _logger.logDebug('changeQuality: $quality, 保存位置 ${position.inSeconds}s');

      isSwitchingQuality.value = true;

      try {
        // 原生 DASH MPD：直接切换视频轨（不重开播放器，无中断）
        final switched = await _switchQualityViaTrack(quality);
        if (!switched) {
          // 回退路径（JSON/m3u8 分离流 或 track 未就绪）：重载数据源
          await _reloadWithDataSource(quality, position);
        }
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
    _sliderPosition = position;
    _updateSliderPositionSecond();
    // 在 seek 真正提交前保持拖拽态，避免旧 position stream 事件把滑块
    // 从用户刚放开的目标点又写回旧播放点，造成肉眼可见的回跳。
    unawaited(_seekAndReleaseSlider(position));
  }

  Future<void> _seekAndReleaseSlider(Duration position) async {
    try {
      await seek(position);
    } finally {
      if (!_isDisposed) {
        isSliderMoving.value = false;
        _sliderPosition = position;
        _updateSliderPositionSecond();
      }
    }
  }

  void _updatePositionState(Duration position) {
    _position = position;
    _updatePositionSecond();
    _positionStreamController.add(position);
    _userIntendedPosition = position;

    if (eventListener != null && position.inSeconds > 0) {
      final diff =
          (position.inMilliseconds - _lastReportedPosition.inMilliseconds)
              .abs();
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
    _updateNotifierValue(
        durationSeconds, _player?.state.duration.inSeconds ?? 0);
  }

  void _updateBufferedSecond() {
    final player = _player;
    if (player == null) {
      _updateNotifierValue(bufferedSeconds, 0);
      return;
    }

    _applyBufferedBarEnd(player, cacheRangeEnd: 0);

    // demuxer-cache-state 需要一次 platform round-trip；buffer stream 高频更新时
    // 只允许一个查询在途，避免 Dart/UI 线程积压同类异步任务。
    if (_supportsDash && !_cacheRangeLookupInFlight) {
      final sessionId = _playbackSessionId;
      final lookupGeneration = ++_cacheRangeLookupGeneration;
      _cacheRangeLookupInFlight = true;
      _tryGetOverallCacheRangeEndSeconds().then((rangeEnd) {
        if (_isDisposed ||
            _player != player ||
            !_isSessionActive(sessionId) ||
            _cacheRangeLookupGeneration != lookupGeneration) {
          return;
        }
        // 成功解析出音视频共同缓存终点后，作为本会话内的权威终点（sticky 锚），
        // 供后续查询失败时做钳制上界，保证条既不塌缩消失也不超前。
        _lastAuthoritativeMediaCacheRangeEndSeconds = rangeEnd.toDouble();
        _hasAuthoritativeMediaCacheRangeThisSession = true;
        _applyBufferedBarEnd(_player!, cacheRangeEnd: rangeEnd);
      }).whenComplete(() {
        // 仅允许当前查询解除自己的单飞守卫。旧会话的异步回调不能把新
        // 查询误标记为完成，否则会并发堆积 platform round-trip。
        if (_cacheRangeLookupGeneration == lookupGeneration) {
          _cacheRangeLookupInFlight = false;
        }
      });
    }
  }

  void _applyBufferedBarEnd(Player player, {required int cacheRangeEnd}) {
    final pos = player.state.position.inSeconds;
    final dur = player.state.duration.inSeconds;
    // demuxer-cache-state 的权威值是“当前音视频共同可播放”的绝对终点。
    // 音画任何一条未就绪都不应被绘制为已缓冲。
    var endAbs = cacheRangeEnd;
    var source = 'audioVideoIntersection';
    if (endAbs <= 0) {
      // media_kit 的 state.buffer 直接映射 mpv demuxer-cache-time，即最后
      // 一帧缓存数据的“绝对时间戳”而非“从当前位置起的时长”。mpv 官方也
      // 标注此值只是猜测，因此仅在权威 cache-state 缺失时作为显示兜底。
      endAbs = player.state.buffer.inSeconds;
      source = 'approximateCacheTimeFallback';
    }
    if (endAbs <= pos &&
        _hasAuthoritativeMediaCacheRangeThisSession &&
        _lastAuthoritativeMediaCacheRangeEndSeconds > pos) {
      // 最近一次的权威共同终点可防止短暂查询失败时缓冲条塌缩。
      endAbs = _lastAuthoritativeMediaCacheRangeEndSeconds.ceil();
      source = 'stickyClamp';
    } else if (endAbs <= pos) {
      source = 'collapsedToPosition';
    }
    endAbs = math.max(pos, endAbs);
    if (dur > 0) {
      endAbs = math.min(endAbs, dur);
    }
    if (_enableMpvTrace) {
      _logger.logDebug('[DASH缓存] 应用决策=$source pos=$pos '
          '入参=$cacheRangeEnd sticky=$_lastAuthoritativeMediaCacheRangeEndSeconds '
          '-> 终点=$endAbs 秒');
    }
    _updateNotifierValue(bufferedSeconds, endAbs);
  }

  /// 获取并恢复播放进度（委托 [PlaybackProgressService]）
  Future<void> fetchAndRestoreProgress() async {
    if (_isDisposed) return;
    final sessionId = _playbackSessionId;
    await _progressService.fetchAndRestore(sessionId);
  }

  /// 由历史进度计算恢复目标秒数（透传，供测试/复用）
  @visibleForTesting
  int? restoreTargetSecondsFromHistory(PlayProgressData data) =>
      _progressService.restoreTargetSecondsFromHistory(data);

  void _armPlaybackPositionGuard(Duration anchor) {
    _playbackPositionGuardAnchor = anchor;
    _playbackPositionGuardUntil = DateTime.now()
        .add(const Duration(milliseconds: _playbackPositionGuardMs));
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

        if (completed &&
            !_hasTriggeredCompletion &&
            !_isSeeking &&
            !isSwitchingQuality.value) {
          final pos = _player!.state.position;
          final dur = _player!.state.duration;
          final isRealEnd =
              isRealCompletion(pos.inMilliseconds, dur.inMilliseconds);
          _playbackLog(
            'stream.completed true pos=${pos.inMilliseconds}ms dur=${dur.inMilliseconds}ms '
            'isRealEnd=$isRealEnd switchingQ=${isSwitchingQuality.value}',
          );

          if (!isRealEnd && pos.inSeconds > 0) {
            final progress = dur.inSeconds > 0
                ? pos.inMilliseconds / dur.inMilliseconds
                : 1.0;
            _logger.logDebug(
                '断网假完成检测: progress=${(progress * 100).toInt()}%, 尝试重试');
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
        if (!_isSessionActive(sessionId) ||
            _isDisposed ||
            _isDisposing ||
            _isSeeking) {
          return;
        }
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
        if (loopMode.value == LoopMode.on &&
            !isSwitchingQuality.value &&
            !_isSeeking &&
            position.inSeconds <= 1 &&
            _lastReportedPosition.inSeconds > 5) {
          final dur = _player?.state.duration ?? Duration.zero;
          if (isRealCompletion(
                  _lastReportedPosition.inMilliseconds, dur.inMilliseconds) &&
              dur.inSeconds > 0) {
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
        if (position.inSeconds % 10 == 0 &&
            position.inSeconds > 0 &&
            _lastPtsLoggedSecond != position.inSeconds) {
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
        // 切换清晰度期间冻结缓冲条：旧缓冲继续播放，新轨数据补满后才更新
        if (isSwitchingQuality.value) return;
        _updateBufferedSecond();
      }),
      _player!.stream.tracks.listen((tracks) async {
        if (!_isSessionActive(sessionId)) return;
        // 原生 DASH MPD：mpv 自动选轨只比较分辨率/码率，同分辨率同码率存在
        // 30/60fps 多轨时固定取流顺序第一条（30fps），不会读取保存的帧率偏好。
        // 轨道首次就绪时按 currentQuality（已解析用户保存偏好）重新应用轨道。
        if (_preferredQualityAppliedForSession) {
          return;
        }
        if (!_supportsDash ||
            _manifest?.mpdUrl == null ||
            _manifest?.supportsNativeQualitySwitching != true) {
          return;
        }
        final quality = currentQuality.value;
        if (quality == null || quality.isEmpty) return;

        // 无论成功与否只尝试一次，避免后续轨道变更事件反复触发
        _preferredQualityAppliedForSession = true;
        try {
          final switched = await _switchQualityViaTrack(quality);
          if (switched) {
            _playbackLog('[DASH] 首帧前按偏好清晰度 $quality 应用视频轨');
          }
        } catch (e) {
          _logger.logDebug('首帧前应用偏好清晰度失败: $e');
        }
      }),
      _player!.stream.buffering.listen((buffering) {
        if (!_isSessionActive(sessionId)) return;
        if (buffering) {
          _bufferingShowTimer?.cancel();
          _bufferingShowTimer =
              Timer(const Duration(milliseconds: _bufferingSustainMs), () {
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

        // OSS 签名过期（HTTP 403 / Access Denied）→ MPD 续签
        if (error.contains('403') ||
            error.contains('Access Denied') ||
            error.contains('Forbidden')) {
          _playbackLog('[DASH] 检测到 403，触发 MPD 续签');
          _dashTokenRefreshed = false;
          _refreshDashManifest();
          return;
        }

        if (error.startsWith('tcp: ') ||
            error.startsWith('Failed to open ') ||
            error.startsWith('Can not open external file ')) {
          Future.delayed(const Duration(seconds: 3), () {
            if (!_isSessionActive(sessionId)) return;
            if (_player!.state.buffering &&
                _player!.state.buffer == Duration.zero) {
              _logger.logDebug('网络错误确认: buffering 且缓冲为空, 重试');
              _handleStalled();
            }
          });
        }
      }),
      _player!.stream.log.listen((log) {
        if (!_isSessionActive(sessionId)) return;
        // Full native trace is intentionally opt-in. Debug builds otherwise
        // still retain warning/error logs without blocking the UI isolate.
        if (_enableMpvTrace) {
          _logger.writeMpvTrace('[mpv:${log.prefix}] ${log.text}');
        }
        if (log.prefix == 'av_sync' ||
            log.prefix == 'audio' ||
            log.prefix == 'cplayer' ||
            log.text.contains('patients') ||
            log.text.contains('A-V:') ||
            log.text.contains('sync') ||
            log.text.contains('drop') ||
            log.text.contains('delay') ||
            log.text.contains('underrun') ||
            log.text.contains('reset') ||
            log.text.contains('timestamp') ||
            log.text.contains('desync')) {
          _logger.logDebug('[mpv:${log.prefix}] ${log.text}');
        }
      }),
    ]);

    _connectivitySubscription ??=
        Connectivity().onConnectivityChanged.listen((results) {
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
    _subscriptions = [];
    _listenersStarted = false;
    _stalledTimer?.cancel();
    _stalledTimer = null;
    _seekTimer?.cancel();
    _seekTimer = null;
    _bufferingShowTimer?.cancel();
    _bufferingShowTimer = null;
    _cacheRangeLookupInFlight = false;
    _cacheRangeLookupGeneration++;
    _cacheRangeLookupInFlight = false;
    _dashRefreshTimer?.cancel();
    _dashRefreshTimer = null;
  }

  // ===========================================================================
  // 10. 生命周期与设置管理
  // ===========================================================================

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
    await PlayerSettingsService.setBackgroundPlayEnabled(
        backgroundPlayEnabled.value);
  }

  Future<void> toggleLoopMode() async {
    final nextMode = (loopMode.value.index + 1) % LoopMode.values.length;
    loopMode.value = LoopMode.values[nextMode];
    await _syncLoopProperty();
    await PlayerSettingsService.setLoopModeIndex(loopMode.value.index);
  }

  // ===========================================================================
  // 11. Helper 辅助方法
  // ===========================================================================

  int _nextPlaybackSessionId() => ++_playbackSessionId;

  bool _isSessionActive(int sessionId) =>
      !_isDisposed && _player != null && _playbackSessionId == sessionId;

  /// 调试：统一前缀，在 kDebugMode 下经 [LoggerService.logDebug] 输出到控制台
  void _playbackLog(String message) {
    _logger.logDebug(message, tag: 'Playback');
  }

  /// C 方案实证：播放链路关键事件写入 mpv_trace.log，用于与 mpv/ffmpeg 日志对齐分析
  void _mpvTrace(String message) {
    if (kDebugMode) {
      _logger.writeMpvTrace('[APP] $message');
    }
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
    _preferredQualityAppliedForSession = false;
    _playbackPositionGuardUntil = null;
    _playbackPositionGuardAnchor = Duration.zero;
    _lastReportedPosition = Duration.zero;
    _lastPtsLoggedSecond = -1;
    _cacheRangeLookupInFlight = false;
    _cacheRangeLookupGeneration++;
    _lastAuthoritativeMediaCacheRangeEndSeconds = 0;
    _hasAuthoritativeMediaCacheRangeThisSession = false;
    _playbackLog('resetPlaybackStates session=$_playbackSessionId');
  }

  void setInitialDurationHint(double? duration) {
    if (duration == null || duration <= 0) return;
    durationSeconds.value = duration.toInt();
  }

  void setVideoMetadata(
      {required String title, String? author, Uri? coverUri}) {
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
    _operationQueue =
        _operationQueue.then((_) => operation()).catchError((e, st) {
      _logger.logError(
          message: '播放操作队列执行失败',
          error: e,
          stackTrace: st is StackTrace ? st : StackTrace.current);
    });
    return _operationQueue;
  }

  Future<void> _seekInternal(Duration position) async {
    _mpvTrace('_seekInternal begin target=${position.inMilliseconds}ms');
    final seekSw = Stopwatch()..start();
    await _seekBufferWaitIfNeeded();

    if (_player!.state.duration.inSeconds != 0) {
      _playbackLog(
          'seekInternal ${position.inMilliseconds}ms (duration ready)');
      await _player!.seek(position);
      if (!_isDisposed && _player != null) {
        _armPlaybackPositionGuard(position);
      }
      seekSw.stop();
      _mpvTrace(
          '_seekInternal done (${seekSw.elapsedMilliseconds}ms, duration ready)');
    } else {
      _mpvTrace('_seekInternal waiting duration ready (polling 200ms)');
      _seekTimer?.cancel();
      _seekTimer =
          Timer.periodic(const Duration(milliseconds: 200), (Timer t) async {
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
          seekSw.stop();
          _mpvTrace(
              '_seekInternal done (${seekSw.elapsedMilliseconds}ms, duration polling)');
          _isSeeking = false;
        }
      });
    }
  }

  Future<void> _seekBufferWaitIfNeeded() async {
    if (_player == null || _player!.state.buffer != Duration.zero) return;
    try {
      await _player!.stream.buffer.first
          .timeout(const Duration(milliseconds: 300));
    } catch (_) {
      // 超时是正常情况，不需要日志
    }
  }

  void _notifyVideoEndOnce() {
    final now = DateTime.now();
    if (_lastVideoEndAt != null &&
        now.difference(_lastVideoEndAt!).inMilliseconds < _videoEndDebounceMs) {
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

  Future<void> _handleStalled() async {
    await _enqueueOperation(() async {
      if (_isHandlingStall ||
          _isInitializing ||
          isLoading.value ||
          isSwitchingQuality.value ||
          _isSeeking ||
          _seekInFlight) {
        return;
      }
      if (_lastSeekAt != null &&
          DateTime.now().difference(_lastSeekAt!).inSeconds < 4) {
        return;
      }
      if (_currentResourceId == null ||
          currentQuality.value == null ||
          _player == null) {
        return;
      }

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

        _playbackLog(
            '_handleStalled reload quality=${currentQuality.value} pos=${currentPos.inSeconds}s');
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

    await setDataSource(
      dataSource,
      seekTo: position.inSeconds > 0 ? position : Duration.zero,
      autoPlay: true,
      retainAudioFocus: true,
    );
  }

  /// 原生 DASH MPD：通过 mpv 视频轨切换清晰度（不重开播放器）
  ///
  /// 后端 dash-unified MPD 每个清晰度是一个独立 Representation，
  /// mpv 原生加载后每条视频轨对应一个清晰度。
  /// quality 形如 "1920x1080_3000k_30"（WxH_码率_帧率）或旧格式 "720p"。
  /// 匹配失败（track 未就绪 / MPD 未加载）返回 false，由调用方回退重载。
  Future<bool> _switchQualityViaTrack(String quality) async {
    final player = _player;
    if (player == null ||
        !_supportsDash ||
        _manifest?.mpdUrl == null ||
        _manifest?.supportsNativeQualitySwitching != true) {
      return false;
    }

    final targetHeight = _parseQualityHeight(quality);
    if (targetHeight == null) return false;

    final targetFps = _parseQualityFps(quality);

    final tracks = player.state.tracks.video;
    if (tracks.isEmpty) return false;

    // mpv 视频轨高度 = Representation 文件实际高度（demux-h）：
    // 横屏 "1920x1080_..." → 1080；竖屏 "1080x1920_..." → 1920（高边）
    // 同高度可能存在多轨（如 1080p30 / 1080p60），按帧率取最优。
    VideoTrack? match;
    for (final t in tracks) {
      if (t.id == 'no' || t.id == 'auto') continue;
      if (t.h != targetHeight) continue;
      // 无帧率目标或当前轨无帧率时，采用首个匹配轨
      if (targetFps == null || t.fps == null) {
        match ??= t;
        continue;
      }
      // 帧率接近度优于当前候选才替换（取最接近目标帧率的轨道）
      if (match == null) {
        match = t;
        continue;
      }
      final currentGap = (t.fps! - targetFps).abs();
      final bestGap =
          match.fps != null ? (match.fps! - targetFps).abs() : double.infinity;
      if (currentGap < bestGap) match = t;
    }
    if (match == null) return false;

    await player.setVideoTrack(match);
    // 使切轨前发起的缓存查询失效，避免旧视频轨的结果回写当前缓存条。
    _cacheRangeLookupGeneration++;
    _cacheRangeLookupInFlight = false;
    _playbackLog(
        '[DASH] 切换视频轨到清晰度 $quality (track id=${match.id}, h=${match.h})');
    return true;
  }

  /// 从清晰度字符串解析真实高度（匹配 mpv demux-h）
  ///
  /// 新格式 "1920x1080_3000k_30" → 1080；竖屏 "1080x1920_3000k_30" → 1920（高边）
  /// 旧格式 "720p" → 720
  static int? _parseQualityHeight(String quality) {
    final parts = quality.split('_');
    if (parts.isNotEmpty && parts[0].contains('x')) {
      final dims = parts[0].split('x');
      if (dims.length == 2) return int.tryParse(dims[1]);
    }
    final match = RegExp(r'^(\d+)p', caseSensitive: false).firstMatch(quality);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }

  /// 从清晰度字符串解析帧率（用于同高度多轨选择）
  ///
  /// "1920x1080_3000k_30" → 30；无帧率信息返回 null（此时按首个匹配轨切换）
  static int? _parseQualityFps(String quality) {
    final parts = quality.split('_');
    return parts.length >= 3 ? int.tryParse(parts[2]) : null;
  }

  // ──────────────────────────────────────────────
  //  DASH MPD 定时续签
  // ──────────────────────────────────────────────

  /// 启动 MPD 定时续签：在服务端 key 过期前 30 分钟重新拉取 MPD 并切换源。
  /// 长视频场景下 key 过期会导致后续请求 403 无限加载，必须在过期前重取。
  void _startDashRefreshTimer() {
    _dashRefreshTimer?.cancel();
    _dashRefreshTimer = null;
    if (!_supportsDash || _currentResourceId == null) return;
    final delay = Duration(milliseconds: _dashKeyTtlMs - _dashRefreshAheadMs);
    _dashRefreshTimer = Timer(delay, _onDashRefreshTimerTick);
    _playbackLog('[DASH] 定时续签已启动, ${delay.inHours}h 后触发');
  }

  Future<void> _onDashRefreshTimerTick() async {
    if (_isDisposed || _player == null || _currentResourceId == null) return;
    _playbackLog('[DASH] 定时续签触发');
    await _enqueueOperation(() async {
      if (_isDisposed || _player == null || _currentResourceId == null) return;
      try {
        final currentPos = _player!.state.position;
        _streamService.clearManifestCache(_currentResourceId!);
        _manifest = await _streamService.getDashManifest(_currentResourceId!);
        _manifestLine = NetworkLineSelector().selectedLine;
        if (_isDisposed || _player == null || _currentResourceId == null) {
          return;
        }
        final quality = currentQuality.value;
        if (quality == null) return;
        final ds = _manifest!.getDataSource(
          quality,
          preferNativeMpd: _manifest!.supportsNativeQualitySwitching,
        );
        if (ds == null) return;
        await setDataSource(ds, seekTo: currentPos, autoPlay: true);
        _dashTokenRefreshed = true;
        _playbackLog('[DASH] 定时续签完成, currentTime=${currentPos.inSeconds}s');
      } catch (e) {
        _playbackLog('[DASH] 定时续签失败: $e');
      }
    });
  }

  /// MPD 续签（错误触发或强制），支持备份 OSS 切换
  ///
  /// 入队执行，与 changeQuality/_handleStalled/_onDashRefreshTimerTick 串行，
  /// 避免并发 setDataSource 造成 removeListeners/open 交错。
  Future<void> _refreshDashManifest({bool useBackup = false}) async {
    if (_isDisposed || _player == null || _currentResourceId == null) return;
    if (_dashTokenRefreshed) return;
    _playbackLog('[DASH] MPD 续签, backup=$useBackup');
    await _enqueueOperation(() => _doRefreshDashManifestInner(useBackup));
  }

  Future<void> _doRefreshDashManifestInner(bool useBackup) async {
    try {
      final currentPos = _player!.state.position;
      _streamService.clearManifestCache(_currentResourceId!);
      _manifest = await _streamService.getDashManifest(_currentResourceId!);
      _manifestLine = NetworkLineSelector().selectedLine;
      if (_isDisposed || _player == null || _currentResourceId == null) return;
      final quality = currentQuality.value;
      if (quality == null) return;
      final ds = _manifest!.getDataSource(
        quality,
        preferNativeMpd: _manifest!.supportsNativeQualitySwitching,
      );
      if (ds == null) return;
      await setDataSource(ds, seekTo: currentPos, autoPlay: true);
      _dashTokenRefreshed = true;
      _playbackLog('[DASH] MPD 续签完成, currentTime=${currentPos.inSeconds}s');
    } catch (e) {
      _playbackLog('[DASH] MPD 续签失败: $e');
      if (!useBackup) {
        _playbackLog('[DASH] 切备用 OSS 重试');
        NetworkLineSelector().forceSwitchLine();
        await _doRefreshDashManifestInner(true);
      }
    }
  }

  Future<DataSource> _getDataSourceForQuality(String quality) async {
    if (_supportsDash && _manifest != null) {
      // 过期或线路已切换 → 清缓存强制重取；
      // 不清缓存直接 getDashManifest 会命中 service 的同 key 旧 future（缓存永不失效）
      final currentLine = NetworkLineSelector().selectedLine;
      final lineChanged = currentLine != null &&
          _manifestLine != null &&
          _manifestLine != currentLine;
      if (_currentResourceId != null && (_manifest!.isExpired || lineChanged)) {
        _streamService.clearManifestCache(_currentResourceId!);
        _manifest = await _streamService.getDashManifest(_currentResourceId!);
        _manifestLine = NetworkLineSelector().selectedLine;
      }
      final ds = _manifest!.getDataSource(
        quality,
        preferNativeMpd: _manifest!.supportsNativeQualitySwitching,
      );
      if (ds != null) return ds;
    }
    return _streamService.getM3u8DataSource(_currentResourceId!, quality);
  }

  Future<void> _syncLoopProperty() async {
    if (_player == null) return;
    try {
      _player!.setProperty(
          'loop-file', loopMode.value == LoopMode.on ? 'inf' : 'no');
    } catch (e) {
      _logger.logWarning('设置循环模式失败: $e');
    }
  }

  Future<void> _loadSettings() async {
    try {
      backgroundPlayEnabled.value =
          await PlayerSettingsService.getBackgroundPlayEnabled();
      final loopModeValue = await PlayerSettingsService.getLoopModeIndex();
      loopMode.value = LoopMode.values[loopModeValue];
      _settingsLoaded = true;
    } catch (e) {
      _logger.logWarning('加载播放器设置失败: $e');
    }
  }

  Future<String> _getPreferredQuality(List<String> qualities) async {
    try {
      final preferredName = await PlayerSettingsService.getPreferredQuality();
      return findBestQualityMatch(qualities, preferredName);
    } catch (e) {
      _logger.logWarning('获取首选清晰度失败: $e');
    }
    return getDefaultQuality(qualities);
  }

  Future<void> _savePreferredQuality(String quality) async {
    try {
      await PlayerSettingsService.setPreferredQuality(
          formatQualityDisplayName(quality));
    } catch (e) {
      _logger.logWarning('保存首选清晰度失败: $e');
    }
  }

  /// 从 demuxer-cache-state 解析音视频共同缓存区间右端点（绝对秒数，失败返回 0）。
  ///
  /// 可播放缓冲不是任意一轨的最大缓存：音频和视频都覆盖当前位置的区间，
  /// 其较小终点才是用户实际能够连续播放到的位置。
  Future<int> _tryGetOverallCacheRangeEndSeconds() async {
    try {
      final cacheStr = await _player!.getProperty('demuxer-cache-state');
      if (_enableMpvTrace) {
        _logger.logDebug('[DASH缓存] demuxer-cache-state 原始输出: $cacheStr');
      }
      if (cacheStr.isEmpty) return 0;
      final positionSeconds =
          (_player?.state.position.inMilliseconds.toDouble() ?? 0) /
              Duration.millisecondsPerSecond;
      final structuredEnd = _parseMpvCacheStateEnd(
        cacheStr,
        positionSeconds: positionSeconds,
      );
      if (structuredEnd != null && structuredEnd > positionSeconds) {
        return structuredEnd.ceil();
      }

      // 兼容旧版 libmpv 将 NODE 格式化为 "video[0]: start - end" 文本的情况。
      final videoEnd = _cacheRangeEndCoveringPosition(
        cacheStr,
        mediaType: 'video',
        positionSeconds: positionSeconds,
      );
      if (videoEnd == null) return 0;
      final audioEnd = _cacheRangeEndCoveringPosition(
        cacheStr,
        mediaType: 'audio',
        positionSeconds: positionSeconds,
      );
      // 无音频资源只用视频；有音频时取两者交集，绝不以单轨冒充总体缓冲。
      final end = audioEnd == null ? videoEnd : math.min(videoEnd, audioEnd);
      if (end.isFinite && end > positionSeconds) {
        if (_enableMpvTrace) {
          _logger.logDebug('[DASH缓存] 解析共同终点=$end 秒 '
              '(video=$videoEnd, audio=$audioEnd, ceil=${end.ceil()})');
        }
        return end.ceil();
      }
      if (_enableMpvTrace) {
        _logger.logDebug('[DASH缓存] 未解析到覆盖当前位置的音视频共同区间，'
            '判定查询失败 (end=$end)');
      }
    } catch (e) {
      _logger.logDebug('获取整体缓冲区间失败: $e');
    }
    return 0;
  }

  /// 解析 mpv 官方 demuxer-cache-state 的 NODE/JSON 表示。
  ///
  /// 优先使用 ts-per-stream 的 video/audio cache-end：两者存在时取较小值，
  /// 才能表示音画连续可播放的总体缓冲；无单轨详情时才使用 main demuxer 的
  /// seekable-ranges，它表示真正可用于缓存 seek 的连续区间。
  double? _parseMpvCacheStateEnd(
    String raw, {
    required double positionSeconds,
  }) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;

      final streams = decoded['ts-per-stream'];
      final videoEnd = _streamCacheEnd(streams, 'video');
      if (videoEnd != null) {
        final audioEnd = _streamCacheEnd(streams, 'audio');
        final activeAudio = _player?.state.track.audio.id != 'no';
        // 有活动音轨却拿不到它的时间戳时，不能把 video 单轨缓存当总体缓存。
        // 此时继续尝试 main demuxer 的 seekable-ranges；仍不可用则交给近似值兜底。
        if (!activeAudio || audioEnd != null) {
          return audioEnd == null ? videoEnd : math.min(videoEnd, audioEnd);
        }
      }

      final ranges = decoded['seekable-ranges'];
      if (ranges is List) {
        return _continuousSeekableRangeEnd(ranges, positionSeconds);
      }
    } catch (_) {
      // 某些 libmpv 版本会把 NODE 转成展示文本，随后走下方正则兼容路径。
    }
    return null;
  }

  double? _streamCacheEnd(dynamic streams, String mediaType) {
    dynamic stream;
    if (streams is Map) {
      stream = streams[mediaType];
      if (stream == null) {
        for (final entry in streams.values) {
          if (entry is Map &&
              (entry['type'] == mediaType ||
                  entry['stream-type'] == mediaType)) {
            stream = entry;
            break;
          }
        }
      }
    } else if (streams is List) {
      for (final entry in streams) {
        if (entry is Map &&
            (entry['type'] == mediaType || entry['stream-type'] == mediaType)) {
          stream = entry;
          break;
        }
      }
    }
    if (stream is! Map) return null;
    final value = stream['cache-end'];
    return value is num && value.isFinite ? value.toDouble() : null;
  }

  /// 合并覆盖当前播放位置且首尾相连/重叠的 seekable-ranges，得到真正连续
  /// 可 seek 的缓存末端。mpv 官方说明 ranges 可能无序且会暂时重叠。
  double? _continuousSeekableRangeEnd(List<dynamic> ranges, double position) {
    final parsed = <(double start, double end)>[];
    for (final range in ranges) {
      if (range is! Map) continue;
      final start = range['start'];
      final end = range['end'];
      if (start is num &&
          end is num &&
          start.isFinite &&
          end.isFinite &&
          end >= start) {
        parsed.add((start.toDouble(), end.toDouble()));
      }
    }
    parsed.sort((a, b) => a.$1.compareTo(b.$1));
    double? continuousEnd;
    for (final range in parsed) {
      if (continuousEnd == null) {
        if (range.$1 <= position + 0.25 && range.$2 >= position - 0.25) {
          continuousEnd = range.$2;
        }
      } else if (range.$1 <= continuousEnd + 0.25) {
        continuousEnd = math.max(continuousEnd, range.$2);
      } else {
        break;
      }
    }
    return continuousEnd;
  }

  /// 返回 [mediaType] 在当前位置连续可读的区间右端点；忽略跳转后预读的孤岛，
  /// 以免把旧片段或未连接的缓存错误地绘制到缓冲条。
  double? _cacheRangeEndCoveringPosition(
    String cacheState, {
    required String mediaType,
    required double positionSeconds,
  }) {
    final ranges = RegExp(
      '$mediaType\\[\\d+\\]\\s*:\\s*([\\d.]+)\\s*-\\s*([\\d.]+)',
      caseSensitive: false,
    ).allMatches(cacheState);
    double? end;
    for (final match in ranges) {
      final start = double.tryParse(match.group(1) ?? '');
      final candidateEnd = double.tryParse(match.group(2) ?? '');
      if (start == null ||
          candidateEnd == null ||
          !start.isFinite ||
          !candidateEnd.isFinite ||
          candidateEnd < start ||
          start > positionSeconds + 0.25 ||
          candidateEnd < positionSeconds - 0.25) {
        continue;
      }
      end = end == null ? candidateEnd : math.min(end, candidateEnd);
    }
    return end;
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
      _logger.logDebug(
          '[PTS] video=${videoPts.toStringAsFixed(3)}s, audio=${audioPts.toStringAsFixed(3)}s, avsync=${avsync.toStringAsFixed(3)}s');
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

      final preferredIdx =
          await PlayerSettingsService.pickPreferredSubtitleTrackIndex(list);
      if (preferredIdx < list.length) {
        await _applySubtitleTrackItem(
            sessionId, list[preferredIdx], preferredIdx);
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
      } catch (_) {
        // 字幕关闭失败不阻塞主流程
      }
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
        // 已在 _configurePlayerOnce 设置默认值，但确保 mpv 不干扰 Flutter SubtitleView
        _player!.setProperty('sub-visibility', 'no');
        _player!.setProperty('sub-ass', 'no');
        _player!.setProperty('sub-border-style', 'outline-and-shadow');
        _player!.setProperty('sub-back-color', '#00000000');
        _player!.setProperty('sub-shadow-offset', '0');
      } catch (_) {
        // mpv 编译选项可能裁剪这些属性，静默忽略
      }
      await _player!.setSubtitleTrack(
        SubtitleTrack.data(
          text,
          title: item.displayLabel,
          language: item.lang,
        ),
      );
      // sub-visibility 必须在此之后再次设为 no，因为 setSubtitleTrack 可能重新启用
      try {
        _player!.setProperty('sub-visibility', 'no');
      } catch (_) {
        // mpv 编译选项可能裁剪此属性，静默忽略
      }
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

  Future<void> selectSubtitleIndex(int index,
      {bool persistPreference = true}) async {
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
    final i =
        await PlayerSettingsService.pickPreferredSubtitleTrackIndex(tracks);
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

  Future<void> _disposeAsync() async {
    WakelockManager.disable();
    await _audioFocus.detachPlayer();
    await _audioFocus.dispose();
    if (_player != null) {
      await _player!.dispose();
      _player = null;
    }
    _positionStreamController.close();
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposing = true;
    _isDisposed = true;

    eventListener = null;
    removeListeners();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;

    _manifest = null;
    _manifestLine = null;
    _cacheService.cleanupAllTempCache();

    // DASH 定时续签 Timer 必须取消，否则测试/页面销毁会报 Timer pending
    _dashRefreshTimer?.cancel();
    _dashRefreshTimer = null;

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

    unawaited(_disposeAsync());

    super.dispose();
  }
}
