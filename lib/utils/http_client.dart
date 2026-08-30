import 'dart:async';
import 'package:dio/dio.dart';
import '../config/api_config.dart';
import '../services/logger_service.dart';
import 'token_manager.dart';

class HttpClient {
  static final HttpClient _instance = HttpClient._internal();
  factory HttpClient() => HttpClient._instance;

  late final Dio dio;

  HttpClient._internal() {
    dio = Dio(BaseOptions(
      baseUrl: ApiConfig.baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
      },
      followRedirects: true,
      maxRedirects: 5,
    ));

    dio.interceptors.addAll([
      AuthInterceptor(this),
      RetryInterceptor(
        dio: dio,
        retries: 10,
        retryDelays: const [
          Duration(seconds: 1), Duration(seconds: 2),
          Duration(seconds: 3), Duration(seconds: 3),
          Duration(seconds: 5), Duration(seconds: 5),
          Duration(seconds: 8), Duration(seconds: 8),
          Duration(seconds: 10), Duration(seconds: 10),
        ],
      ),
    ]);
  }

  /// 校正 Dio baseUrl（ApiConfig.init 之后调用；切换端点后再次调用立即生效）
  void refreshBaseUrl() {
    dio.options.baseUrl = ApiConfig.baseUrl;
    LoggerService.instance.logDebug(
      '[HttpClient] baseUrl = ${ApiConfig.baseUrl} (端点=${ApiConfig.endpoint.name})',
    );
  }

  /// 启动初始化：读取持久化配置后校正 baseUrl
  Future<void> init() async {
    refreshBaseUrl();
  }

  static String? get cachedToken => TokenManager().token;
  static String? get cachedRefreshToken => TokenManager().refreshToken;

  static Future<void> updateCachedTokens({
    required String token,
    required String refreshToken,
  }) => TokenManager().saveTokens(token: token, refreshToken: refreshToken);

  static Future<void> updateCachedToken(String token) =>
      TokenManager().updateToken(token);

  static Future<void> clearCachedTokens() => TokenManager().clearTokens();

  Future<String?> refreshToken() async {
    final tm = TokenManager();
    if (tm.isRefreshFailed) return null;

    final existing = tm.refreshCompleter;
    if (tm.isRefreshing && existing != null) return existing.future;

    final completer = Completer<String?>();
    tm.setRefreshing(true, completer);

    try {
      final rt = tm.refreshToken;
      if (rt == null || rt.isEmpty) {
        tm.markRefreshFailed();
        await tm.handleTokenExpired();
        completer.complete(null);
        return null;
      }

      final resp = await Dio(BaseOptions(
        baseUrl: ApiConfig.baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {'Content-Type': 'application/json'},
      )).post('/api/v1/auth/updateToken', data: {'refreshToken': rt});

      if (resp.data['code'] == 200) {
        final data = resp.data['data'] as Map<String, dynamic>;
        final newToken = data['token'] as String;
        final newRefresh = data['refreshToken'] as String?;
        await tm.updateToken(newToken, refreshToken: newRefresh);
        completer.complete(newToken);
        return newToken;
      }

      tm.markRefreshFailed();
      if (resp.data['code'] == 2000) await tm.handleTokenExpired();
      completer.complete(null);
      return null;
    } catch (_) {
      tm.markRefreshFailed();
      completer.complete(null);
      return null;
    } finally {
      tm.setRefreshing(false, null);
      Future.delayed(const Duration(milliseconds: 100), () {
        if (tm.refreshCompleter == completer) tm.setRefreshing(false, null);
      });
    }
  }
}

/// ──────────────────────────────────────────
///  AuthInterceptor：自动注入 Token + 响应 3000 刷新重试
/// ──────────────────────────────────────────
class AuthInterceptor extends Interceptor {
  final HttpClient _http;
  AuthInterceptor(this._http);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final tm = TokenManager();
    if (!options.headers.containsKey('Authorization') && !tm.isRefreshFailed) {
      final token = tm.token;
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = token;
      }
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    if (response.data is Map && response.data['code'] == 3000) {
      final tm = TokenManager();
      if (!tm.isRefreshFailed) {
        final newToken = await _http.refreshToken();
        if (newToken != null) {
          try {
            response.requestOptions.headers['Authorization'] = newToken;
            final retry = await _http.dio.fetch(response.requestOptions);
            return handler.next(retry);
          } catch (_) {}
        }
      }
    }
    handler.next(response);
  }
}

/// ──────────────────────────────────────────
///  RetryInterceptor：网络错误 / 5xx 自动重试
/// ──────────────────────────────────────────
class RetryInterceptor extends Interceptor {
  final Dio dio;
  final int retries;
  final List<Duration> retryDelays;

  RetryInterceptor({
    required this.dio,
    this.retries = 3,
    this.retryDelays = const [
      Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 3),
    ],
  });

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    // 允许请求通过 extra['maxRetries'] 覆盖全局重试次数
    final maxRetries = err.requestOptions.extra['maxRetries'] as int? ?? retries;
    final count = err.requestOptions.extra['retryCount'] as int? ?? 0;
    if (count < maxRetries && _shouldRetry(err)) {
      err.requestOptions.extra['retryCount'] = count + 1;
      await Future.delayed(
        count < retryDelays.length ? retryDelays[count] : retryDelays.last,
      );
      try {
        return handler.resolve(await dio.fetch(err.requestOptions));
      } on DioException catch (e) {
        return super.onError(e, handler);
      }
    }
    super.onError(err, handler);
  }

  bool _shouldRetry(DioException e) =>
      e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.sendTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.connectionError ||
      (e.response?.statusCode != null && e.response!.statusCode! >= 500);
}
