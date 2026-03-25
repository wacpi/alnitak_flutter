import 'package:uuid/uuid.dart';
import '../utils/http_client.dart';
import '../models/captcha_models.dart';
import 'logger_service.dart';

/// 发送验证码时需要人机验证异常
class SendCodeCaptchaRequiredException implements Exception {
  final String captchaId;

  SendCodeCaptchaRequiredException(this.captchaId);

  @override
  String toString() => '需要人机验证';
}

/// 发送验证码冷却中异常
class SendCodeCooldownException implements Exception {
  final int countdown;
  final String message;

  SendCodeCooldownException(this.countdown, this.message);

  @override
  String toString() => message;
}

/// 发送验证码成功结果
class SendCodeResult {
  final int countdown;
  final String message;

  SendCodeResult({required this.countdown, required this.message});
}

/// 人机验证服务
class CaptchaService {
  static final CaptchaService _instance = CaptchaService._internal();
  factory CaptchaService() => _instance;
  CaptchaService._internal();

  final HttpClient _httpClient = HttpClient();
  final Uuid _uuid = const Uuid();

  /// 生成验证码ID
  String generateCaptchaId() {
    return _uuid.v4();
  }

  /// 获取滑块验证数据
  Future<CaptchaData?> getCaptcha(String captchaId) async {
    try {
      final response = await _httpClient.dio.get(
        '/api/v1/verify/captcha/get',
        queryParameters: {'captchaId': captchaId},
      );


      if (response.data['code'] == 200) {
        return CaptchaData.fromJson(response.data['data']);
      } else {
      }
      return null;
    } catch (e) {
      LoggerService.instance.logWarning('获取验证码失败: $e', tag: 'CaptchaService');
      return null;
    }
  }

  /// 验证滑块
  Future<bool> validateCaptcha({
    required String captchaId,
    required int x,
  }) async {
    try {

      final requestData = CaptchaValidateRequest(
        captchaId: captchaId,
        x: x,
      ).toJson();


      final response = await _httpClient.dio.post(
        '/api/v1/verify/captcha/validate',
        data: requestData,
      );


      final success = response.data['code'] == 200;
      if (success) {
      } else {
      }

      return success;
    } catch (e) {
      LoggerService.instance.logWarning('验证滑块失败: $e', tag: 'CaptchaService');
      return false;
    }
  }

  /// 发送邮箱验证码
  /// [captchaId] 可选，首次调用可不传，如果服务端要求验证会抛出异常
  /// 抛出 [SendCodeCaptchaRequiredException] 表示需要人机验证
  /// 抛出 [SendCodeCooldownException] 表示发送过于频繁，附带剩余冷却秒数
  /// 成功返回 [SendCodeResult] 包含冷却时间和提示消息
  Future<SendCodeResult> sendEmailCode({
    required String email,
    String? captchaId,
  }) async {
    try {
      final data = <String, dynamic>{'email': email};
      if (captchaId != null && captchaId.isNotEmpty) {
        data['captchaId'] = captchaId;
      }

      final response = await _httpClient.dio.post(
        '/api/v1/verify/getEmailCode',
        data: data,
      );

      if (response.data['code'] == 200) {
        final countdown = response.data['data']?['countdown'] as int? ?? 60;
        final msg = response.data['msg'] as String? ?? '验证码已发送，请查收邮箱';
        return SendCodeResult(countdown: countdown, message: msg);
      } else if (response.data['code'] == -1) {
        // 需要人机验证，服务端返回 captchaId
        final serverCaptchaId = response.data['data']?['captchaId'] as String? ?? '';
        if (serverCaptchaId.isNotEmpty) {
          throw SendCodeCaptchaRequiredException(serverCaptchaId);
        }
      } else if (response.data['code'] == 500) {
        // 发送失败，检查是否有冷却时间
        final countdown = response.data['data']?['countdown'] as int?;
        final msg = response.data['msg'] as String? ?? '验证码发送失败';
        if (countdown != null && countdown > 0) {
          throw SendCodeCooldownException(countdown, msg);
        }
        throw Exception(msg);
      }
      throw Exception('验证码发送失败');
    } catch (e) {
      if (e is SendCodeCaptchaRequiredException || e is SendCodeCooldownException) {
        rethrow;
      }
      LoggerService.instance.logWarning('发送邮箱验证码失败: $e', tag: 'CaptchaService');
      rethrow;
    }
  }
}
