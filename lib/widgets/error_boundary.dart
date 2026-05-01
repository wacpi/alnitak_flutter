import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../services/logger_service.dart';
import '../pages/main_page.dart';

typedef ErrorWidgetBuilder = Widget Function(BuildContext context, Object error, StackTrace stackTrace);

class ErrorBoundary extends StatefulWidget {
  final Widget child;
  final ErrorWidgetBuilder? errorBuilder;
  final void Function(Object error, StackTrace stackTrace)? onError;

  const ErrorBoundary({
    super.key,
    required this.child,
    this.errorBuilder,
    this.onError,
  });

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  bool _hasError = false;
  Object _error = Object();
  StackTrace _stackTrace = StackTrace.empty;

  // 用于在 dispose 时还原全局错误回调，避免覆盖外层注册者。
  FlutterExceptionHandler? _previousFlutterOnError;
  bool Function(Object, StackTrace)? _previousPlatformOnError;
  // 我们注册到 FlutterError.onError 的闭包引用，仅当当前 handler 仍是它时才还原。
  FlutterExceptionHandler? _flutterOnErrorRef;
  bool Function(Object, StackTrace)? _platformOnErrorRef;
  bool _handlersRegistered = false;

  // 已计划在下一帧切换到错误态，避免一帧内重复 setState 触发风暴。
  bool _errorRenderScheduled = false;

  @override
  void didUpdateWidget(ErrorBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) {
      _hasError = false;
      _errorRenderScheduled = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _registerErrorHandlers();
  }

  @override
  void dispose() {
    _restoreErrorHandlers();
    super.dispose();
  }

  void _registerErrorHandlers() {
    _previousFlutterOnError = FlutterError.onError;
    _previousPlatformOnError = PlatformDispatcher.instance.onError;

    _flutterOnErrorRef = (FlutterErrorDetails details) {
      // 先调用上一层 handler（含 framework 默认输出），避免吞掉错误信息
      _previousFlutterOnError?.call(details);
      _handleError(details.exception, details.stack ?? StackTrace.empty);
    };
    _platformOnErrorRef = (Object error, StackTrace stack) {
      final handled = _previousPlatformOnError?.call(error, stack) ?? false;
      _handleError(error, stack);
      return handled || true;
    };

    FlutterError.onError = _flutterOnErrorRef;
    PlatformDispatcher.instance.onError = _platformOnErrorRef;
    _handlersRegistered = true;
  }

  void _restoreErrorHandlers() {
    if (!_handlersRegistered) return;
    // 仅当全局 handler 仍是我们注册的那个时才还原；
    // 若已被外部再次覆盖，则保持现状以免破坏链路。
    if (identical(FlutterError.onError, _flutterOnErrorRef)) {
      FlutterError.onError = _previousFlutterOnError;
    }
    if (identical(PlatformDispatcher.instance.onError, _platformOnErrorRef)) {
      PlatformDispatcher.instance.onError = _previousPlatformOnError;
    }
    _handlersRegistered = false;
  }

  void _handleError(Object error, StackTrace stackTrace) {
    if (!mounted) return;

    LoggerService.instance.logError(
      message: 'ErrorBoundary 捕获到错误',
      error: error,
      stackTrace: stackTrace,
      context: {'hasError': true},
    );
    widget.onError?.call(error, stackTrace);

    // 已经处于错误展示态或已计划切换，仅记录日志，避免错误风暴
    if (_hasError || _errorRenderScheduled) return;

    final binding = SchedulerBinding.instance;
    final phase = binding.schedulerPhase;
    final inFrame = phase == SchedulerPhase.transientCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks ||
        phase == SchedulerPhase.persistentCallbacks;

    void apply() {
      if (!mounted || _hasError) return;
      setState(() {
        _hasError = true;
        _error = error;
        _stackTrace = stackTrace;
      });
    }

    if (inFrame) {
      // build / layout / paint 阶段禁止 setState，推迟到下一帧
      _errorRenderScheduled = true;
      binding.addPostFrameCallback((_) {
        _errorRenderScheduled = false;
        apply();
      });
      // 触发下一帧
      binding.scheduleFrame();
    } else {
      apply();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return widget.errorBuilder?.call(context, _error, _stackTrace) ??
          _defaultErrorWidget();
    }
    return widget.child;
  }

  Widget _defaultErrorWidget() {
    return Material(
      child: Center(
child: Padding(
          padding: EdgeInsets.all(24.r),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64.sp,
                color: Colors.red[400],
              ),
              SizedBox(height: 16.h),
              Text(
                '出了点问题',
                style: Theme.of(context).textTheme.headlineSmall,
),
              SizedBox(height: 8.h),
              Text(
                _error.toString(),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                textAlign: TextAlign.center,
),
              SizedBox(height: 24.h),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const MainPage()),
                    (route) => false,
                  );
                },
                icon: const Icon(Icons.home),
                label: const Text('返回首页'),
              ),
              if (kDebugMode) ...[
SizedBox(height: 16.h),
                ExpansionTile(
                  title: const Text('错误详情'),
                  children: [
                    Padding(
                      padding: EdgeInsets.all(8.r),
                      child: SelectableText(
                        _stackTrace.toString(),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.sp,
                          color: Colors.grey[800],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class AsyncErrorBoundary extends StatefulWidget {
  final Widget child;
  final Widget Function(BuildContext context, Object error, VoidCallback retry)? errorBuilder;

  const AsyncErrorBoundary({
    super.key,
    required this.child,
    this.errorBuilder,
  });

  @override
  State<AsyncErrorBoundary> createState() => _AsyncErrorBoundaryState();
}

class _AsyncErrorBoundaryState extends State<AsyncErrorBoundary> {
  Object? _error;
  VoidCallback? _retry;

  void _resetError() {
    if (mounted) {
      setState(() {
        _error = null;
        _retry = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return widget.errorBuilder?.call(context, _error!, _resetError) ??
          _defaultErrorWidget();
    }
    return ErrorBoundary(
      onError: (error, stack) {
        _error = error;
        _retry = () => _resetError();
      },
      child: widget.child,
    );
  }

  Widget _defaultErrorWidget() {
    return Material(
      child: Center(
child: Padding(
          padding: EdgeInsets.all(24.r),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 64.sp,
                color: Colors.orange[400],
              ),
              SizedBox(height: 16.h),
              Text(
                '加载失败',
                style: Theme.of(context).textTheme.titleLarge,
),
              SizedBox(height: 8.h),
              Text(
                _error?.toString() ?? '未知错误',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                textAlign: TextAlign.center,
),
              SizedBox(height: 24.h),
              ElevatedButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
