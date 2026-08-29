import 'dart:async';
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

  /// 探测 ayypd.cn：3s 内有响应 → 内网，否则外网
  static Future<void> detectNetwork() async {
    try {
      final url = _buildUrl(
        https: _httpsEnabled,
        host: internalHost,
        port: _httpsEnabled ? internalPortHttps : internalPortHttp,
      );
      final dio = Dio(BaseOptions(
        baseUrl: url,
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
      ));
      final resp = await dio.get('/api/v1/auth/ping');
      useInternal = resp.statusCode == 200;
    } catch (_) {
      useInternal = false;
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
