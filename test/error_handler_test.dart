import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alnitak_flutter/utils/error_handler.dart';

void main() {
  group('ErrorHandler.getErrorMessage', () {
    test('DioException connectionTimeout 返回连接超时文案', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionTimeout,
      );
      expect(
        ErrorHandler.getErrorMessage(error),
        contains('超时'),
      );
    });

    test('DioException badResponse 401 返回登录过期', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 401,
        ),
      );
      expect(
        ErrorHandler.getErrorMessage(error),
        contains('登录'),
      );
    });

    test('DioException badResponse 404 返回资源不存在', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 404,
        ),
      );
      expect(
        ErrorHandler.getErrorMessage(error),
        contains('不存在'),
      );
    });

    test('普通异常返回默认文案', () {
      expect(
        ErrorHandler.getErrorMessage(Exception('unknown')),
        '操作失败，请稍后重试',
      );
    });

    test('网络相关字符串返回网络错误文案', () {
      expect(
        ErrorHandler.getErrorMessage(Exception('SocketException: ...')),
        contains('网络'),
      );
    });
  });

  group('ErrorHandler.isNetworkRelatedError', () {
    test('DioException connectionTimeout 视为网络相关', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionTimeout,
      );
      expect(ErrorHandler.isNetworkRelatedError(error), isTrue);
    });

    test('DioException badResponse 401 非网络相关', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 401,
        ),
      );
      expect(ErrorHandler.isNetworkRelatedError(error), isFalse);
    });
  });
}
