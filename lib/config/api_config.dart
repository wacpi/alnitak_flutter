import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// API 配置
///
/// 启动时探测 ayypd.cn：有延迟反馈且返回数据 → 内网优先；
/// 超时或失败 → 使用外网 acgkiss.com。分享地址联动。
class ApiConfig {
  ApiConfig._();

  // ── 内网地址（默认优先） ──
  static const String internalHost = 'anime.ayypd.cn';
  static const int internalPortHttp = 9000;
  static const int internalPortHttps = 9001;
  static const int internalSharePort = 3000;

  // ── 外网地址 ──
  static const String externalHost = 'api.acgkiss.com';
  static const int externalPortHttp = 80;
  static const int externalPortHttps = 443;
  static const String externalShareHost = 'www.acgkiss.com';

  // ── 运行时状态 ──
  static bool _httpsEnabled = true;

  /// true = 内网 ayypd, false = 外网 acgkiss
  static bool useInternal = true;

  static bool get httpsEnabled => _httpsEnabled;

  static String get baseUrl {
    if (useInternal) {
      return _buildUrl(
        https: _httpsEnabled,
        host: internalHost,
        port: _httpsEnabled ? internalPortHttps : internalPortHttp,
      );
    }
    return _buildUrl(
      https: _httpsEnabled,
      host: externalHost,
      port: _httpsEnabled ? externalPortHttps : externalPortHttp,
    );
  }

  /// 分享地址（跟随当前网络）
  static String getShareUrl(String path) {
    final base = useInternal
        ? _buildUrl(
            https: _httpsEnabled,
            host: internalHost,
            port: internalSharePort,
          )
        : _buildUrl(
            https: _httpsEnabled,
            host: externalShareHost,
            port: _httpsEnabled ? externalPortHttps : externalPortHttp,
          );
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return '$base/$cleanPath';
  }

  // ── 初始化 ──

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _httpsEnabled = prefs.getBool(_httpsEnabledKey) ?? true;
  }

  static Future<void> setHttpsEnabled(bool enabled) async {
    _httpsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_httpsEnabledKey, enabled);
  }

  // ── 内网探测 ──

  /// 探测内网：DNS 有记录且 HTTP/HTTPS 端口可达 → 内网，否则外网
  ///
  /// 探测顺序：
  /// 1. DNS 查 [internalHost]（hosts 未绑定则直接判定外网，不白等超时）
  /// 2. 优先 HTTP:9000（开发环境明文端口，Android 已放行 cleartext）
  /// 3. HTTP 不通再试 HTTPS:9001（自签证书场景兜底）
  static Future<void> detectNetwork() async {
    // 1. DNS 预查：hosts / DNS 里没有内网域名记录就直接外网
    final hasInternalRecord = await _hasInternalDns();
    if (!hasInternalRecord) {
      useInternal = false;
      return;
    }

    // 2/3. HTTP 优先探测，HTTPS 兜底
    final httpOk = await _pingInternal(https: false);
    if (httpOk) {
      useInternal = true;
      return;
    }
    final httpsOk = await _pingInternal(https: true);
    useInternal = httpsOk;
  }

  static Future<bool> _hasInternalDns() async {
    try {
      // 2s 超时：避免 WiFi 无 DNS 时长时间阻塞启动
      final results = await InternetAddress.lookup(internalHost)
          .timeout(const Duration(seconds: 2));
      return results.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _pingInternal({required bool https}) async {
    try {
      final url = _buildUrl(
        https: https,
        host: internalHost,
        port: https ? internalPortHttps : internalPortHttp,
      );
      final dio = Dio(BaseOptions(
        baseUrl: url,
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
      ));
      final resp = await dio.get('/api/v1/auth/ping');
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 当前域名不通时的备选地址
  static String get fallbackBaseUrl {
    return _buildUrl(
      https: _httpsEnabled,
      host: useInternal ? externalHost : internalHost,
      port: useInternal
          ? (_httpsEnabled ? externalPortHttps : externalPortHttp)
          : (_httpsEnabled ? internalPortHttps : internalPortHttp),
    );
  }

  // ── URL 构造 ──

  static String _buildUrl({
    required bool https,
    required String host,
    required int port,
  }) {
    final protocol = https ? 'https' : 'http';
    final isDefaultPort = (https && port == 443) || (!https && port == 80);
    return isDefaultPort ? '$protocol://$host' : '$protocol://$host:$port';
  }

  static const String _httpsEnabledKey = 'https_enabled';
}
