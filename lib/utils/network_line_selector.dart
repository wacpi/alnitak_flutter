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

  // ===== 延迟检测 =====
  /// 发 Range: bytes=0-0 请求测首字节延迟（ms）。
  Future<double> _measureLatency(Dio dio, String url) async {
    final sw = Stopwatch()..start();
    try {
      await dio.get(url, options: Options(
        headers: {'Range': 'bytes=0-0'},
        sendTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        // 不需要走完整重试，快速失败即可
        extra: {'noRetry': true},
      ));
      return sw.elapsedMilliseconds.toDouble();
    } catch (_) {
      return double.infinity;
    }
  }

  /// 完整 GET 请求测总响应时间（ms），含首字节 + 传输耗时。
  Future<double> _measureFullResponse(Dio dio, String url) async {
    final sw = Stopwatch()..start();
    try {
      await dio.get(url, options: Options(
        sendTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        extra: {'noRetry': true},
      ));
      return sw.elapsedMilliseconds.toDouble();
    } catch (_) {
      return double.infinity;
    }
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

  void dispose() {
    _selectedLine.dispose();
    _isChecking.dispose();
  }
}
