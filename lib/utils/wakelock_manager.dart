import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/logger_service.dart';

/// 跨平台屏幕常亮管理器
///
/// 基于 wakelock_plus 包实现，支持 Android / iOS / Windows / macOS / Linux / Web。
class WakelockManager {
  static final LoggerService _logger = LoggerService.instance;

  /// 启用屏幕常亮
  static Future<void> enable() async {
    try {
      await WakelockPlus.enable();
      if (kDebugMode) {
        _logger.logDebug('[Wakelock] 已启用', tag: 'Wakelock');
      }
    } on PlatformException catch (e) {
      await _logger.logError(message: '[Wakelock] 启用失败: ${e.message}');
    } catch (e) {
      await _logger.logError(message: '[Wakelock] 启用异常: $e');
    }
  }

  /// 禁用屏幕常亮
  static Future<void> disable() async {
    try {
      await WakelockPlus.disable();
      if (kDebugMode) {
        _logger.logDebug('[Wakelock] 已禁用');
      }
    } on PlatformException catch (e) {
      await _logger.logError(message: '[Wakelock] 禁用失败: ${e.message}');
    } catch (e) {
      await _logger.logError(message: '[Wakelock] 禁用异常: $e');
    }
  }

  /// 切换屏幕常亮状态
  static Future<void> toggle({required bool enable}) async {
    if (enable) {
      await WakelockManager.enable();
    } else {
      await WakelockManager.disable();
    }
  }

  /// 获取当前状态
  static Future<bool> isEnabled() => WakelockPlus.enabled;
}
