import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../config/api_config.dart';
import 'http_client.dart';

/// 网络线路。
enum NetworkLine { primary, backup }

/// 全局网络线路选择器。
///
/// 应用启动时自动检测主/备 OSS 线路延迟 + 吞吐量，
/// 为整个会话选择最优线路。图片和视频统一使用此结果。
///
/// 检测策略：
/// 1. 并行测主备延迟（Range: bytes=0-0）
/// 2. 若延迟接近（<200ms）则追加吞吐量测试（下载完整响应体）
/// 3. 综合评分选最优
class NetworkLineSelector {
  // ===== 常量 =====
  /// 周期性重探间隔（对齐 web `network-line.ts` 30s 策略）
  static const int _recheckIntervalMs = 30 * 1000;

  /// 线路连续失败阈值——当前线路连续 N 次组件上报失败后自动重探
  static const int _maxConsecutiveFailures = 2;

  // ===== 单例 =====
  static final NetworkLineSelector _instance = NetworkLineSelector._();
  factory NetworkLineSelector() => _instance;
  NetworkLineSelector._();

  // ===== 响应式状态 =====
  final ValueNotifier<NetworkLine?> _selectedLine = ValueNotifier(null);
  final ValueNotifier<bool> _isChecking = ValueNotifier(false);

  ValueNotifier<NetworkLine?> get selectedLineNotifier => _selectedLine;
  NetworkLine? get selectedLine => _selectedLine.value;
  ValueNotifier<bool> get isCheckingNotifier => _isChecking;
  bool get isChecking => _isChecking.value;

  // ===== 健康追踪 =====
  final Map<NetworkLine, int> _consecutiveFailures = {
    NetworkLine.primary: 0,
    NetworkLine.backup: 0,
  };

  // ===== 周期性重探 =====
  Timer? _recheckTimer;

  // ===== 延迟检测 =====
  /// 发 Range: bytes=0-0 请求测首字节延迟（ms）。
  /// 如果响应中包含 `X-Oss-Latency` 头（后端代为测量的 OSS 延迟），
  /// 优先使用该值而非客户端测到的全程耗时。
  Future<double> _measureLatency(Dio dio, String url) async {
    final sw = Stopwatch()..start();
    try {
      final response = await dio.get(url, options: Options(
        headers: {'Range': 'bytes=0-0'},
        sendTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        // 不需要走完整重试，快速失败即可
        extra: {'noRetry': true},
      ));
      final elapsed = sw.elapsedMilliseconds.toDouble();
      final ossLatency = response.headers.value('X-Oss-Latency');
      if (ossLatency != null) {
        final parsed = double.tryParse(ossLatency);
        if (parsed != null && parsed.isFinite) return parsed;
      }
      return elapsed;
    } catch (_) {
      return double.infinity;
    }
  }

  /// 完整 GET 请求测总响应时间（ms），含首字节 + 传输耗时。
  /// 如果响应中包含 `X-Oss-Latency` 头（后端代为测量的 OSS 延迟），
  /// 优先使用该值而非客户端测到的全程耗时（避免后端内部测量开销被计入）。
  Future<double> _measureFullResponse(Dio dio, String url) async {
    final sw = Stopwatch()..start();
    try {
      final response = await dio.get(url, options: Options(
        sendTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        extra: {'noRetry': true},
      ));
      final elapsed = sw.elapsedMilliseconds.toDouble();
      final ossLatency = response.headers.value('X-Oss-Latency');
      if (ossLatency != null) {
        final parsed = double.tryParse(ossLatency);
        if (parsed != null && parsed.isFinite) return parsed;
      }
      return elapsed;
    } catch (_) {
      return double.infinity;
    }
  }

  // ===== 周期性重探 =====

  /// 启动周期性线路重探（每 30 秒），对齐 web `network-line.ts scheduleRecheck`。
  /// 幂等——重复调用不会启动多个定时器。
  ///
  /// 在 [check] / [ensureChecked] 之后调用即可——selector 首次 probe 完成即开始周期巡查。
  void startPeriodicRecheck() {
    if (_recheckTimer != null) return; // 幂等
    _recheckTimer = Timer.periodic(
      const Duration(milliseconds: _recheckIntervalMs),
      (_) => check(),
    );
  }

  /// 停止周期性重探。
  void stopPeriodicRecheck() {
    _recheckTimer?.cancel();
    _recheckTimer = null;
  }

  // ===== 组件健康反馈 =====

  /// 组件报告某条线路发生失败。
  ///
  /// - [failedLine]: 发生失败的线路（组件知道它试了哪条）
  /// - 如果当前选中的线路连续失败达到 [_maxConsecutiveFailures]，
  ///   自动触发 re-probe，重新评估主/备线路质量。
  void reportLineFailure(NetworkLine failedLine) {
    _consecutiveFailures[failedLine] =
        (_consecutiveFailures[failedLine] ?? 0) + 1;
    final current = _selectedLine.value;
    if (current != null && failedLine == current) {
      final failures = _consecutiveFailures[current] ?? 0;
      debugPrint(
        '[NetworkLine] 当前线路 $current 连续 $failures 次失败，触发重探',
      );
      if (failures >= _maxConsecutiveFailures) {
        _consecutiveFailures[current] = 0;
        unawaited(check());
      }
    }
  }

  /// 组件报告某条线路恢复成功（重置该线路的连续失败计数）。
  void reportLineSuccess(NetworkLine line) {
    _consecutiveFailures[line] = 0;
  }

  /// 强制立即切换到另一条线路（不等待 probe 结果），同时触发后台重探验证。
  ///
  /// 用于视频卡顿等急需换线的场景——先换再验证，恢复优先。
  void forceSwitchLine() {
    final current = _selectedLine.value ?? NetworkLine.primary;
    final newLine =
        current == NetworkLine.primary ? NetworkLine.backup : NetworkLine.primary;
    if (_selectedLine.value == newLine) {
      // 已经是另一条了，直接上报故障触发重探
      reportLineFailure(current);
      return;
    }
    debugPrint('[NetworkLine] 强制切换: $current → $newLine');
    _selectedLine.value = newLine;
    // 后台重探确认新线路质量
    unawaited(check());
  }

  // ===== 线路检测 =====
  /// 执行一次完整的线路检测并更新全局状态。
  /// 幂等：检测中再次调用返回进行中的结果。
  Future<NetworkLine> check() async {
    if (_isChecking.value && _selectedLine.value != null) {
      return _selectedLine.value!;
    }

    _isChecking.value = true;
    try {
      final dio = HttpClient().dio;
      final probePath = '/api/image/probe';
      final primaryUrl = '${ApiConfig.baseUrl}$probePath';
      final backupUrl = '${ApiConfig.baseUrl}$probePath?backup=true';

      // Phase 1: 延迟检测（并行）
      final results = await Future.wait([
        _measureLatency(dio, primaryUrl),
        _measureLatency(dio, backupUrl),
      ]);
      final primaryLatency = results[0];
      final backupLatency = results[1];

      double primaryScore = primaryLatency;
      double backupScore = backupLatency;

      // Phase 2: 延迟接近时，吞吐量做 tiebreaker
      if ((primaryLatency - backupLatency).abs() < 200) {
        final tr = await Future.wait([
          _measureFullResponse(dio, primaryUrl),
          _measureFullResponse(dio, backupUrl),
        ]);
        primaryScore = tr[0];
        backupScore = tr[1];
      }

      _selectedLine.value =
          backupScore < primaryScore ? NetworkLine.backup : NetworkLine.primary;

      // 重置两条线路的连续失败计数——新探结果就是最新权威
      _consecutiveFailures[NetworkLine.primary] = 0;
      _consecutiveFailures[NetworkLine.backup] = 0;

      debugPrint(
        '[NetworkLine] 主=${primaryScore.toStringAsFixed(0)}ms '
        '备=${backupScore.toStringAsFixed(0)}ms '
        '→ ${_selectedLine.value == NetworkLine.backup ? "备用" : "主"}',
      );

      return _selectedLine.value!;
    } finally {
      _isChecking.value = false;
    }
  }

  // ===== 惰性初始化 =====
  Future<NetworkLine>? _initOnce;

  /// 应用启动时调用一次。后续返回缓存结果。
  Future<NetworkLine> ensureChecked() {
    if (_selectedLine.value != null) {
      return Future.value(_selectedLine.value);
    }
    _initOnce ??= check();
    return _initOnce!;
  }

  /// 等待检测完成，但最多等 [timeout] 时长，超时默认 [NetworkLine.primary]。
  Future<NetworkLine> ensureCheckedWithTimeout({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_selectedLine.value != null) return _selectedLine.value!;
    try {
      return await ensureChecked().timeout(timeout);
    } catch (_) {
      // 超时或失败时默认主线路，不让 UI 阻塞
      _selectedLine.value ??= NetworkLine.primary;
      return NetworkLine.primary;
    }
  }

  void dispose() {
    _recheckTimer?.cancel();
    _recheckTimer = null;
    _selectedLine.dispose();
    _isChecking.dispose();
  }
}
