import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:audio_service/audio_service.dart';
import 'pages/main_page.dart';
import 'pages/settings_page.dart';
import 'theme/app_theme.dart';
import 'services/theme_service.dart';
import 'services/logger_service.dart';
import 'services/player_settings_service.dart';
import 'services/audio_service_handler.dart';
import 'config/api_config.dart';
import 'utils/http_client.dart';
import 'utils/token_manager.dart';
import 'utils/auth_state_manager.dart';
import 'utils/network_line_selector.dart';
import 'widgets/error_boundary.dart';

/// 全局 AudioService handler，供 VideoPlayerController 使用
late VideoAudioHandler audioHandler;

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await _init();
    runApp(const MyApp());
  }, (Object error, StackTrace stack) {
    LoggerService.instance.logError(
      message: '未捕获的异步异常',
      error: error,
      stackTrace: stack,
      context: {'source': 'runZonedGuarded'},
    );
  });
}

Future<void> _init() async {
  MediaKit.ensureInitialized();

  // 并行初始化互不依赖的模块（ThemeService、ApiConfig、TokenManager 等均只需读 SharedPrefs）
  // 注意：AudioService.init 须提前完成以便 audioHandler 就绪；HttpClient.init 依赖 ApiConfig.init，
  // 但 HttpClient 构造时已使用 ApiConfig 静态默认值，init() 只需在后台校正 baseUrl。
  // 不在 main 预配置 AudioSession，避免与 Controller 内 configure 重复导致电话中断后状态异常
  await Future.wait([
    AudioService.init(
      builder: () => VideoAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.alnitak_flutter.audio',
        androidNotificationChannelName: '视频播放',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    ).then((handler) => audioHandler = handler),
    ThemeService().init(),
    ApiConfig.init(),
    TokenManager().initialize(),
    AuthStateManager().initialize(),
    PlayerSettingsService.initialize(),
    ScreenUtil.ensureScreenSize(),
  ]);

  // 必须在 ApiConfig.init 之后校正 Dio baseUrl
  await HttpClient().init();

  // 网络线路探针移到后台执行，不阻塞首帧渲染（之前 blocking 最长 3s）。
  // 组件在探针完成前默认走主线路，probe 完成后自动更新。
  NetworkLineSelector().ensureChecked().then((_) {
    NetworkLineSelector().startPeriodicRecheck();
  });

  if (kDebugMode) {
    LoggerService.instance.logInfo('API 基础地址: ${ApiConfig.baseUrl}', tag: 'App');
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final ThemeService _themeService = ThemeService();

  @override
  void initState() {
    super.initState();
    // 监听主题变化
    _themeService.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    _themeService.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    setState(() {});
  }

  Widget _defaultErrorWidget(BuildContext context, Object error) {
    return Material(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Colors.red[400],
              ),
              const SizedBox(height: 16),
              Text(
                '出了点问题',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                error.toString(),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (context) => const MainPage()),
                    (route) => false,
                  );
                },
                icon: const Icon(Icons.home),
                label: const Text('返回首页'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(375, 812), // 设计稿尺寸（iPhone X 基准）
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, child) {
        return MaterialApp(
          title: 'Alnitak Flutter',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: _themeService.flutterThemeMode,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en', 'US'),
          ],
          locale: const Locale('zh', 'CN'),
          home: ErrorBoundary(
            child: child!,
            errorBuilder: (context, error, stack) => _defaultErrorWidget(context, error),
          ),
          navigatorObservers: const [],
          routes: {
            '/settings': (context) => const SettingsPage(),
          },
        );
      },
      child: const MainPage(),
    );
  }
}
