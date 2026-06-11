import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../config/api_config.dart';
import '../models/subtitle_track_item.dart';
import '../utils/http_client.dart';

/// 分 P 字幕 API（对齐 web `src/api/subtitle.ts`）
///
/// **调用顺序（播放端建议）**
/// 1. 主视频 [Player.open]/[Media] 已成功。
/// 2. [fetchTracks]，选默认轨或首轨。
/// 3. [fetchVttPlain]（独立 Dio，不向 OSS 带站点 Authorization）。
/// 4. `player.setSubtitleTrack(SubtitleTrack.data(...))`.
class SubtitleApiService {
  static final Dio _dio = HttpClient().dio;

  static final Dio _plainDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 25),
      receiveTimeout: const Duration(seconds: 60),
      responseType: ResponseType.plain,
      headers: const {'Accept': 'text/plain, */*'},
    ),
  );

  static Future<List<SubtitleTrackItem>> fetchTracks(String resourceShortId) async {
    final key = resourceShortId.trim();
    if (key.isEmpty) return [];

    final response = await _dio.get<Map<String, dynamic>>(
      '/api/v1/video/subtitle/list',
      queryParameters: {'resourceShortId': key},
    );

    final data = response.data;
    if (data == null || data['code'] != 200) {
      return [];
    }

    final root = data['data'];
    if (root is! Map<String, dynamic>) return [];
    final raw = root['tracks'];
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((e) => SubtitleTrackItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 拉取远端 VTT/SRT 文本（后端代理路径或 OSS 直链）。
  static Future<String> fetchVttPlain(String url) async {
    final u = url.trim();
    if (u.isEmpty) throw Exception('字幕地址为空');

    final fullUrl = u.startsWith('http') ? u : '${ApiConfig.baseUrl}$u';
    final res = await _plainDio.get<String>(fullUrl);
    final body = res.data;
    if (body == null || body.isEmpty) {
      throw Exception('字幕文件为空');
    }
    return body;
  }

  /// 上传字幕：`resourceShortId`、`lang`、`label?`、`isDefault?`、`file`。
  static Future<void> upload({
    required String resourceShortId,
    required String lang,
    required File file,
    String label = '',
    bool isDefault = false,
  }) async {
    final form = FormData.fromMap({
      'resourceShortId': resourceShortId.trim(),
      'lang': lang.trim(),
      'label': label.trim(),
      'isDefault': isDefault,
      'file': await MultipartFile.fromFile(
        file.path,
        filename: p.basename(file.path),
      ),
    });

    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/video/subtitle/upload',
      data: form,
    );

    final data = response.data;
    if (data == null || data['code'] != 200) {
      throw Exception(data?['msg']?.toString() ?? '字幕上传失败');
    }
  }

  static Future<void> deleteTrack(int id) async {
    final response = await _dio.delete<Map<String, dynamic>>(
      '/api/v1/video/subtitle/$id',
    );
    final data = response.data;
    if (data == null || data['code'] != 200) {
      throw Exception(data?['msg']?.toString() ?? '字幕删除失败');
    }
  }
}
