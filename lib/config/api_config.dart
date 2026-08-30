import 'package:shared_preferences/shared_preferences.dart';

/// API 端点选择
///
/// 手动指定使用哪个后端地址（不再自动探测）：
/// - [internal]：内网 anime.ayypd.cn
/// - [external]：外网 api.acgkiss.com
/// - [custom]：自定义地址（完整拼写，如 http://192.168.1.10:9000）
enum ApiEndpoint {
  internal,
  external,
  custom;
}

/// API 配置
///
/// 端点由用户在设置页「开发者选项」中手动切换并持久化，
/// 不再启动时探测内网（探测在无 DNS/弱网下不可靠）。
class ApiConfig {
  ApiConfig._();

  // ── 内网地址 ──
  static const String internalHost = 'anime.ayypd.cn';
  static const int internalPortHttp = 9000;
  static const int internalPortHttps = 9001;
  static const int internalSharePort = 3000;

  // ── 外网地址 ──
  static const String externalHost = 'api.acgkiss.com';
  static const int externalPortHttp = 80;
  static const int externalPortHttps = 443;
  static const String externalShareHost = 'www.acgkiss.com';

  // ── 运行时状态（由 init/切换方法写入） ──
  static bool _httpsEnabled = true;
  static ApiEndpoint _endpoint = ApiEndpoint.internal;
  static String _customBaseUrl = '';

  static bool get httpsEnabled => _httpsEnabled;

  static ApiEndpoint get endpoint => _endpoint;

  static String get customBaseUrl => _customBaseUrl;

  static String get baseUrl {
    switch (_endpoint) {
      case ApiEndpoint.internal:
        return _buildUrl(
          https: _httpsEnabled,
          host: internalHost,
          port: _httpsEnabled ? internalPortHttps : internalPortHttp,
        );
      case ApiEndpoint.external:
        return _buildUrl(
          https: _httpsEnabled,
          host: externalHost,
          port: _httpsEnabled ? externalPortHttps : externalPortHttp,
        );
      case ApiEndpoint.custom:
        return _customBaseUrl;
    }
  }

  /// 分享地址（跟随当前端点）
  static String getShareUrl(String path) {
    final String base;
    switch (_endpoint) {
      case ApiEndpoint.internal:
        base = _buildUrl(
          https: _httpsEnabled,
          host: internalHost,
          port: internalSharePort,
        );
      case ApiEndpoint.external:
        base = _buildUrl(
          https: _httpsEnabled,
          host: externalShareHost,
          port: _httpsEnabled ? externalPortHttps : externalPortHttp,
        );
      case ApiEndpoint.custom:
        base = _customBaseUrl;
    }
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return '$base/$cleanPath';
  }

  // ── 持久化 ──

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _httpsEnabled = prefs.getBool(_httpsEnabledKey) ?? true;
    final name = prefs.getString(_endpointKey);
    _endpoint = ApiEndpoint.values.firstWhere(
      (e) => e.name == name,
      orElse: () => ApiEndpoint.internal,
    );
    _customBaseUrl = prefs.getString(_customBaseUrlKey) ?? '';
  }

  static Future<void> setHttpsEnabled(bool enabled) async {
    _httpsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_httpsEnabledKey, enabled);
  }

  static Future<void> setEndpoint(ApiEndpoint endpoint) async {
    _endpoint = endpoint;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_endpointKey, endpoint.name);
  }

  static Future<void> setCustomBaseUrl(String url) async {
    var trimmed = url.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    _customBaseUrl = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customBaseUrlKey, trimmed);
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
  static const String _endpointKey = 'api_endpoint';
  static const String _customBaseUrlKey = 'api_custom_base_url';
}