import 'package:dio/dio.dart';
import '../models/upload_video.dart';
import '../utils/http_client.dart';
import 'logger_service.dart';

/// 视频投稿API服务
class VideoSubmitApiService {
  static final Dio _dio = HttpClient().dio;

  /// 上传视频（提交视频信息）
  static Future<void> uploadVideo(UploadVideo video) async {
    try {
      LoggerService.instance.logInfo(
        '[uploadVideo] 请求 body: ${video.toJson()}',
        tag: 'VideoSubmit',
      );
      final response = await _dio.post(
        '/api/v1/video/uploadVideoInfo',
        data: video.toJson(),
      );

      LoggerService.instance.logInfo(
        '[uploadVideo] 响应 code=${response.data?['code']} msg=${response.data?['msg']}',
        tag: 'VideoSubmit',
      );

      if (response.data['code'] != 200) {
        throw Exception(response.data['msg'] ?? '上传视频失败');
      }
    } on DioException catch (e, st) {
      LoggerService.instance.logApiError(
        apiName: 'uploadVideo',
        url: '/api/v1/video/uploadVideoInfo',
        statusCode: e.response?.statusCode,
        responseBody: e.response?.data?.toString(),
        error: e,
        stackTrace: st,
        requestParams: video.toJson(),
      );
      throw Exception('上传失败: $e');
    } catch (e, st) {
      LoggerService.instance.logError(
        message: 'uploadVideo 失败',
        error: e,
        stackTrace: st,
        context: {'video': video.toJson()},
      );
      throw Exception('上传失败: $e');
    }
  }

  /// 编辑视频
  static Future<void> editVideo(EditVideo video) async {
    try {
      LoggerService.instance.logInfo(
        '[editVideo] 请求 body: ${video.toJson()}',
        tag: 'VideoSubmit',
      );
      final response = await _dio.put(
        '/api/v1/video/editVideoInfo',
        data: video.toJson(),
      );

      LoggerService.instance.logInfo(
        '[editVideo] 响应 code=${response.data?['code']} msg=${response.data?['msg']}',
        tag: 'VideoSubmit',
      );

      if (response.data['code'] != 200) {
        throw Exception(response.data['msg'] ?? '编辑视频失败');
      }
    } on DioException catch (e, st) {
      LoggerService.instance.logApiError(
        apiName: 'editVideo',
        url: '/api/v1/video/editVideoInfo',
        statusCode: e.response?.statusCode,
        responseBody: e.response?.data?.toString(),
        error: e,
        stackTrace: st,
        requestParams: video.toJson(),
      );
      throw Exception('编辑失败: $e');
    } catch (e, st) {
      LoggerService.instance.logError(
        message: 'editVideo 失败',
        error: e,
        stackTrace: st,
        context: {'video': video.toJson()},
      );
      throw Exception('编辑失败: $e');
    }
  }

/// 获取视频状态
  static Future<VideoStatus> getVideoStatus(String vid) async {
    try {
      LoggerService.instance.logInfo('[getVideoStatus] vid=$vid', tag: 'VideoSubmit');
      final response = await _dio.get(
        '/api/v1/video/getVideoStatus',
        queryParameters: {'vid': vid},
      );

      if (response.data['code'] == 200) {
        // PC端返回格式: data.data.video
        final videoData = response.data['data']['video'] as Map<String, dynamic>;
        return VideoStatus.fromJson(videoData);
      } else {
        throw Exception(response.data['msg'] ?? '获取视频状态失败');
      }
    } on DioException catch (e, st) {
      LoggerService.instance.logApiError(
        apiName: 'getVideoStatus',
        url: '/api/v1/video/getVideoStatus',
        statusCode: e.response?.statusCode,
        responseBody: e.response?.data?.toString(),
        error: e,
        stackTrace: st,
        requestParams: {'vid': vid},
      );
      throw Exception('获取失败: $e');
    } catch (e, st) {
      LoggerService.instance.logError(
        message: 'getVideoStatus 失败',
        error: e,
        stackTrace: st,
        context: {'vid': vid},
      );
      throw Exception('获取失败: $e');
    }
  }

  /// 获取用户投稿视频列表（服务端按 category 筛选）
  /// [category] all | published | transcoding | transcode_failed | pending | rejected
  static Future<List<ManuscriptVideo>> getManuscriptVideos({
    int page = 1,
    int pageSize = 20,
    String category = 'all',
  }) async {
    try {
      final response = await _dio.get(
        '/api/v1/video/getUploadVideo',
        queryParameters: {
          'page': page,
          'pageSize': pageSize,
          'category': category,
        },
      );

      if (response.data['code'] == 200) {
        final videoList = response.data['data']['videos'] as List<dynamic>?;
        if (videoList == null) {
          return [];
        }
        return videoList
            .map((item) => ManuscriptVideo.fromJson(item as Map<String, dynamic>))
            .toList();
      } else {
        throw Exception(response.data['msg'] ?? '获取投稿列表失败');
      }
    } on DioException catch (e, st) {
      LoggerService.instance.logApiError(
        apiName: 'getManuscriptVideos',
        url: '/api/v1/video/getUploadVideo',
        statusCode: e.response?.statusCode,
        responseBody: e.response?.data?.toString(),
        error: e,
        stackTrace: st,
        requestParams: {'page': page, 'pageSize': pageSize, 'category': category},
      );
      throw Exception('获取失败: $e');
    } catch (e, st) {
      LoggerService.instance.logError(
        message: 'getManuscriptVideos 失败',
        error: e,
        stackTrace: st,
        context: {'page': page, 'category': category},
      );
      throw Exception('获取失败: $e');
    }
  }

/// 删除视频
  static Future<void> deleteVideo(String vid) async {
    try {
      final response = await _dio.delete('/api/v1/video/deleteVideo/$vid');

      if (response.data['code'] != 200) {
        throw Exception(response.data['msg'] ?? '删除视频失败');
      }
    } on DioException catch (e, st) {
      LoggerService.instance.logApiError(
        apiName: 'deleteVideo',
        url: '/api/v1/video/deleteVideo/$vid',
        statusCode: e.response?.statusCode,
        responseBody: e.response?.data?.toString(),
        error: e,
        stackTrace: st,
        requestParams: {'vid': vid},
      );
      throw Exception('删除失败: $e');
    } catch (e, st) {
      LoggerService.instance.logError(
        message: 'deleteVideo 失败',
        error: e,
        stackTrace: st,
        context: {'vid': vid},
      );
      throw Exception('删除失败: $e');
    }
  }

/// 添加视频资源
  static Future<void> addVideoResource({
    required String vid,
    required String resourceId,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/video/upload/add/resource',
        data: {
          'vid': vid,
          'resourceId': resourceId,
        },
      );

      if (response.data['code'] != 200) {
        throw Exception(response.data['msg'] ?? '添加视频资源失败');
      }
    } catch (e) {
      throw Exception('添加失败: $e');
    }
  }

/// 删除视频资源
  static Future<void> deleteVideoResource({
    required String vid,
    required String resourceId,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/video/upload/delete/resource',
        data: {
          'vid': vid,
          'resourceId': resourceId,
        },
      );

      if (response.data['code'] != 200) {
        throw Exception(response.data['msg'] ?? '删除视频资源失败');
      }
    } catch (e) {
      throw Exception('删除失败: $e');
    }
  }
}
