import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'package:dio/dio.dart';

import '../utils/http_client.dart';

/// 日志服务：写本地文件并上报服务端
class LoggerService {
  static LoggerService? _instance;
  static LoggerService get instance {
    _instance ??= LoggerService._();
    return _instance!;
  }

  LoggerService._();

  File? _logFile;
  static const String _logFileName = 'error_log.txt';
  static const int _maxLogFileSize = 10 * 1024 * 1024; // 10MB

  /// 初始化日志服务
  Future<void> initialize() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      _logFile = File('${directory.path}/$_logFileName');
      
      // 如果文件过大，清空或归档
      if (await _logFile!.exists()) {
        final fileSize = await _logFile!.length();
        if (fileSize > _maxLogFileSize) {
          await _archiveOldLogs();
        }
      }
    } catch (_) {
      // 日志初始化失败不影响应用启动
    }
  }

  /// 归档旧日志
  Future<void> _archiveOldLogs() async {
    try {
      if (_logFile == null || !await _logFile!.exists()) return;

      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final archiveFile = File('${directory.path}/logs/error_log_$timestamp.txt');
      
      // 创建logs目录
      final logsDir = Directory('${directory.path}/logs');
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }

      // 移动旧日志
      await _logFile!.copy(archiveFile.path);
      await _logFile!.delete();
    } catch (_) {
      // 日志归档失败不阻塞应用
    }
  }

  // ===========================================================================
  // mpv 诊断日志（C 方案临时实证用）
  // ===========================================================================
  File? _mpvTraceFile;
  static const String _mpvTraceFileName = 'mpv_trace.log';
  static const int _maxMpvTraceFileSize = 30 * 1024 * 1024; // 30MB

  /// 记录 mpv / 播放链路诊断日志到 mpv_trace.log（debug 包真机实证用时抓取）
  ///
  /// [line] 已带语义前缀（如 `[APP]` 或 `[mpv:prefix]`），此处只补时间戳。
  /// 不 gate kDebugMode：决定权在调用方。
  ///
  /// 重要：写入经 [writeMpvTrace] 先入内存缓冲，由 [_flushMpvTraceBuffer] 定时/proportion
  /// 批量 flush。trace 级别下 mpv 日志每秒数百条，若每条直接 writeAsString(append) 会在
  /// Android 上产生数百次 open/write/close 系统调用，造成播放/UI 卡顿（曾实测 2.5MB/分钟
  /// 落盘）；且并发写会字节级交错损坏行。缓冲 + 批量 append 同时解决 I/O 频率与行交错问题。
  static const int _mpvTraceFlushThreshold = 32 * 1024; // 缓冲超 32KB 立即落盘
  static const Duration _mpvTraceFlushInterval = Duration(milliseconds: 400);
  final StringBuffer _mpvTraceBuffer = StringBuffer();
  Timer? _mpvTraceFlushTimer;
  bool _mpvTraceFlushing = false;

  Future<void> writeMpvTrace(String line) {
    // 折叠 mpv 文本内嵌换行，保证一行逻辑 = 一行物理（避免碎片行）。
    final content = '${DateFormat('HH:mm:ss.SSS').format(DateTime.now())} '
        '${line.replaceAll(RegExp(r'[\r\n]+'), ' ')}\n';
    _mpvTraceBuffer.write(content);

    if (_mpvTraceBuffer.length >= _mpvTraceFlushThreshold) {
      return flushMpvTrace();
    }
    _mpvTraceFlushTimer ??= Timer(_mpvTraceFlushInterval, flushMpvTrace);
    return Future.value();
  }

  /// 立即将缓冲批量写入文件（供定时器/超阈值/链路关键点调用，幂等）
  Future<void> flushMpvTrace() {
    _mpvTraceFlushTimer?.cancel();
    _mpvTraceFlushTimer = null;
    if (_mpvTraceFlushing) return Future.value();
    if (_mpvTraceBuffer.isEmpty) return Future.value();

    _mpvTraceFlushing = true;
    final content = _mpvTraceBuffer.toString();
    _mpvTraceBuffer.clear();
    return _appendMpvTrace(content).whenComplete(() {
      _mpvTraceFlushing = false;
      // 写入期间又积累了新内容 → 继续排队 flush，避免静默丢弃
      if (_mpvTraceBuffer.isNotEmpty && _mpvTraceFlushTimer == null) {
        _mpvTraceFlushTimer = Timer(
          const Duration(milliseconds: 200),
          flushMpvTrace,
        );
      }
    });
  }

  Future<void> _appendMpvTrace(String content) async {
    try {
      if (_mpvTraceFile == null) {
        // 优先外部存储：/sdcard/Android/data/<pkg>/files/mpv_trace.log，
        // adb shell 直接可读，无需 run-as（MIUI 上 run-as 会被 SELinux 拦截）。
        try {
          final ext = await getExternalStorageDirectory();
          if (ext != null) {
            _mpvTraceFile = File('${ext.path}/$_mpvTraceFileName');
          }
        } catch (_) {
          // 无外部存储（如部分模拟器）时回退应用文档目录
        }
        _mpvTraceFile ??= File('${(await getApplicationDocumentsDirectory()).path}/$_mpvTraceFileName');
      }

      final file = _mpvTraceFile!;
      if (await file.exists()) {
        final size = await file.length();
        if (size > _maxMpvTraceFileSize) {
          // 超限轮转：mpv_trace_old.log 覆盖旧归档
          final old = File(file.path.replaceAll('.log', '_old.log'));
          if (await old.exists()) await old.delete();
          await file.rename(old.path);
        }
      }

      await file.writeAsString(content, mode: FileMode.append);
    } catch (_) {
      // 诊断日志写失败不影响主流程
    }
  }

  static const int _maxReportLength = 2000;

  // 日志上报节流：5 秒内只发一条，避免错误风暴时 HTTP 堵塞
  DateTime _lastReportedAt = DateTime(2000);
  static const Duration _reportThrottleInterval = Duration(seconds: 5);

  void _reportToServer(Map<String, dynamic> payload) {
    // Release 模式下也节流，避免后台重复报错
    final now = DateTime.now();
    if (now.difference(_lastReportedAt) < _reportThrottleInterval) return;
    _lastReportedAt = now;

    Future.microtask(() async {
      try {
        final body = <String, dynamic>{
          'level': payload['level'] ?? 'error',
          'message': _truncate(payload['message'] as String?, _maxReportLength),
          'timestamp': payload['timestamp'],
          if (payload['error'] != null) 'error': _truncate(payload['error']?.toString(), _maxReportLength),
          if (payload['stackTrace'] != null) 'stackTrace': _truncate(payload['stackTrace']?.toString(), 3000),
          if (payload['context'] != null && (payload['context'] as Map).isNotEmpty) 'context': payload['context'],
        };
        await HttpClient().dio.post(
          '/api/v1/client/log',
          data: body,
          options: Options(sendTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 5)),
        );
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('[LoggerService] POST /api/v1/client/log failed: $e');
          debugPrint(st.toString());
        }
      }
    });
  }

  static String? _truncate(String? s, int maxLen) {
    if (s == null) return null;
    return s.length <= maxLen ? s : '${s.substring(0, maxLen)}...';
  }

  /// 仅上报服务端（不写文件），用于消息已读等调试，level 为 info
  void reportEvent(String message, [Map<String, dynamic>? context]) {
    final ts = DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(DateTime.now());
    if (kDebugMode) {
      debugPrint('[reportEvent] $message ${context ?? {}}');
    }
    _reportToServer({
      'level': 'info',
      'message': message,
      'timestamp': ts,
      'context': context ?? {},
    });
  }

  /// 写入日志到文件
  Future<void> _writeToFile(String message) async {
    if (_logFile == null) {
      await initialize();
    }

    try {
      if (_logFile == null) return;

      final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(DateTime.now());
      final logEntry = '[$timestamp] $message\n\n';
      
      // 追加写入文件
      await _logFile!.writeAsString(logEntry, mode: FileMode.append);
    } catch (_) {
      // 日志写文件失败不阻塞主流程
    }
  }

  /// 记录错误日志
  Future<void> logError({
    required String message,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) async {
    final buffer = StringBuffer();
    buffer.writeln('❌ ERROR: $message');
    
    if (error != null) {
      buffer.writeln('Error: $error');
    }
    
    if (stackTrace != null) {
      buffer.writeln('StackTrace:');
      buffer.writeln(stackTrace.toString());
    }
    
    if (context != null && context.isNotEmpty) {
      buffer.writeln('Context:');
      context.forEach((key, value) {
        buffer.writeln('  $key: $value');
      });
    }
    
    buffer.writeln('─' * 80);

    if (kDebugMode) {
      debugPrint(buffer.toString());
    }
    await _writeToFile(buffer.toString());
    _reportToServer({
      'level': 'error',
      'message': message,
      'error': error?.toString(),
      'stackTrace': stackTrace?.toString(),
      'context': context,
      'timestamp': DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(DateTime.now()),
    });
  }

  /// 记录API错误日志
  Future<void> logApiError({
    required String apiName,
    required String url,
    int? statusCode,
    String? responseBody,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? requestParams,
  }) async {
    final context = <String, dynamic>{
      'API名称': apiName,
      '请求URL': url,
      if (statusCode != null) 'HTTP状态码': statusCode,
      if (responseBody != null) '响应体': responseBody.length > 1000 
          ? '${responseBody.substring(0, 1000)}... (截断)' 
          : responseBody,
      if (requestParams != null) '请求参数': requestParams,
    };

    await logError(
      message: 'API请求失败: $apiName',
      error: error,
      stackTrace: stackTrace,
      context: context,
    );
  }

  /// 记录数据加载错误
  Future<void> logDataLoadError({
    required String dataType,
    required String operation,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) async {
    final fullContext = <String, dynamic>{
      '数据类型': dataType,
      '操作': operation,
      if (context != null) ...context,
    };

    await logError(
      message: '数据加载失败: $dataType - $operation',
      error: error,
      stackTrace: stackTrace,
      context: fullContext,
    );
  }

  /// 记录调试信息（仅控制台输出，不写入文件）
  void logDebug(String message, {String? tag}) {
    if (!kDebugMode) return;
    final timestamp = DateFormat('HH:mm:ss.SSS').format(DateTime.now());
    final tagStr = tag != null ? '[$tag] ' : '';
    debugPrint('[$timestamp] 🔍 DEBUG: $tagStr$message');
  }

  /// 记录信息（仅开发环境）
  void logInfo(String message, {String? tag}) {
    if (!kDebugMode) return;
    final timestamp = DateFormat('HH:mm:ss.SSS').format(DateTime.now());
    final tagStr = tag != null ? '[$tag] ' : '';
    debugPrint('[$timestamp] ℹ️ INFO: $tagStr$message');
  }

  /// 记录警告（仅开发环境）
  void logWarning(String message, {String? tag}) {
    if (!kDebugMode) return;
    final timestamp = DateFormat('HH:mm:ss.SSS').format(DateTime.now());
    final tagStr = tag != null ? '[$tag] ' : '';
    debugPrint('[$timestamp] ⚠️ WARN: $tagStr$message');
  }

  /// 记录成功信息（仅开发环境）
  void logSuccess(String message, {String? tag}) {
    if (!kDebugMode) return;
    final timestamp = DateFormat('HH:mm:ss.SSS').format(DateTime.now());
    final tagStr = tag != null ? '[$tag] ' : '';
    debugPrint('[$timestamp] ✅ SUCCESS: $tagStr$message');
  }

  /// 获取日志文件路径
  Future<String?> getLogFilePath() async {
    if (_logFile == null) {
      await initialize();
    }
    return _logFile?.path;
  }

  /// 读取日志内容
  Future<String?> readLogs({int? maxLines}) async {
    if (_logFile == null || !await _logFile!.exists()) {
      return null;
    }

    try {
      final content = await _logFile!.readAsString();
      if (maxLines != null) {
        final lines = content.split('\n');
        if (lines.length > maxLines) {
          return lines.sublist(lines.length - maxLines).join('\n');
        }
      }
      return content;
    } catch (e) {
      return null;
    }
  }

  /// 清空日志
  Future<void> clearLogs() async {
    if (_logFile != null && await _logFile!.exists()) {
      await _logFile!.delete();
      await initialize();
      logInfo('日志已清空');
    }
  }
}
