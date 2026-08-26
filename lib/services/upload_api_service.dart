import 'dart:io';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:media_kit/media_kit.dart';
import '../utils/http_client.dart';

/// 上传API服务 - 参考PC端实现
///
/// Token 刷新机制说明：
/// - 使用 HttpClient 的 AuthInterceptor 统一管理 token
/// - 当请求返回 code=3000 时拦截器自动刷新 token 并重试
class UploadApiService {
  static final Dio _dio = HttpClient().dio;

  /// 上传图片
  /// 返回图片URL
  static Future<String> uploadImage(File file) async {
    final fileName = path.basename(file.path);
    final fileSize = await file.length();
    final mimeType = _guessMimeType(fileName);

    try {
      // 1. 请求后端签名
      final presignResponse = await _dio.post('/api/v1/upload/presignImage', data: {
        'filename': fileName,
        'size': fileSize,
        'mimeType': mimeType,
      });
      final presignData = presignResponse.data as Map<String, dynamic>;
      if (presignData['code'] != 200) {
        throw Exception(presignData['msg'] ?? '获取上传凭证失败');
      }
      final presignInfo = presignData['data'] as Map<String, dynamic>;

      // 2. 直传 OSS
      if (presignInfo['ossType'] == 'r2' || presignInfo['ossType'] == 'minio') {
        // R2 / MinIO: PUT 整个文件
        final uploadRes = await Dio().put(
          presignInfo['presignedUrl'] as String,
          data: file.openRead(),
          options: Options(headers: {'Content-Type': mimeType}),
          onSendProgress: (sent, total) {},
        );
        if (uploadRes.statusCode == null || uploadRes.statusCode! < 200 || uploadRes.statusCode! >= 300) {
          throw Exception('直传 OSS 失败 (HTTP ${uploadRes.statusCode})');
        }
      } else {
        // 阿里云 / 腾讯: 表单 POST
        final formData = FormData.fromMap({
          'key': presignInfo['key'],
          'OSSAccessKeyId': presignInfo['accessKeyId'],
          'policy': presignInfo['policy'],
          'signature': presignInfo['signature'],
          'callback': presignInfo['callback'],
          'Content-Type': mimeType,
          'file': await MultipartFile.fromFile(file.path, filename: fileName),
        });
        final uploadRes = await Dio().post(
          presignInfo['uploadUrl'] as String,
          data: formData,
        );
        final uploadBody = uploadRes.data;
        if (uploadBody is Map && uploadBody['code'] != 0 && uploadBody['code'] != 200) {
          throw Exception(uploadBody['msg'] ?? '直传 OSS 失败');
        }
      }

      // 3. 通知后端确认
      final confirmRes = await _dio.post('/api/v1/upload/confirmImage', data: {
        'ossKey': presignInfo['key'],
      });
      final confirmData = confirmRes.data as Map<String, dynamic>;
      if (confirmData['code'] == 200) {
        return confirmData['data']['url'] as String;
      } else {
        throw Exception(confirmData['msg'] ?? '图片确认失败');
      }
    } catch (e) {
      // fallback: 原始 VPS 代理上传
      final formData = FormData.fromMap({
        'image': await MultipartFile.fromFile(
          file.path,
          filename: fileName,
        ),
      });
      final response = await _dio.post('/api/v1/upload/image', data: formData);
      final data = response.data as Map<String, dynamic>;
      if (data['code'] == 200) {
        return data['data']['url'] as String;
      } else {
        throw Exception(data['msg'] ?? '上传图片失败');
      }
    }
  }

  static String _guessMimeType(String fileName) {
    final ext = path.extension(fileName).toLowerCase();
    const mimeMap = {
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.avif': 'image/avif',
      '.heic': 'image/heic',
    };
    return mimeMap[ext] ?? 'application/octet-stream';
  }

  /// 探测视频元数据 + 截取封面
  /// 返回 { cover: objectKey, duration, width, height }
  static Future<Map<String, dynamic>> _probeVideo(File file) async {
    final result = <String, dynamic>{
      'coverPath': null,
      'duration': 0.0,
      'width': 0,
      'height': 0,
    };

    late final Player player;
    try {
      player = Player();
      await player.open(Media(file.path));

      await Future.delayed(const Duration(milliseconds: 500));

      final state = player.state;
      result['duration'] = state.duration.inSeconds.toDouble();
      result['width'] = state.width ?? 0;
      result['height'] = state.height ?? 0;

      await player.seek(const Duration(seconds: 1));
      await Future.delayed(const Duration(milliseconds: 500));

      final screenshotBytes = await player.screenshot(format: 'image/jpeg');
      if (screenshotBytes != null && screenshotBytes.isNotEmpty) {
        final tempDir = Directory.systemTemp;
        final coverFile = File('${tempDir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await coverFile.writeAsBytes(screenshotBytes);
        result['coverPath'] = coverFile.path;
      }
    } catch (e) {
      // 截封面失败不影响上传
    } finally {
      try { await player.dispose(); } catch (_) {}
    }

    return result;
  }

  /// 上传视频 - 参考PC端实现
  /// 返回视频资源信息
  ///
  /// [vid] 可选的视频ID，用于添加多分P（参考PC端：有vid时使用不同的endpoint）
  /// [filename] 可选的原始文件名，如果不传则使用file路径的文件名
  /// [onCancel] 可选的取消回调，返回true表示需要取消上传
  static Future<Map<String, dynamic>> uploadVideo({
    required File file,
    required String title,
    required Function(double) onProgress,
    String? vid,
    String? filename,
    bool Function()? onCancel,
  }) async {
    final fileMd5 = await _calculateFileMd5(file, onCancel: onCancel);
    final fileSize = await file.length();
    if (onCancel?.call() == true) throw Exception('上传已取消');
    final fileName = filename ?? path.basename(file.path);

    // 后台探测视频（截封面 + 元数据，不阻塞上传）
    final probeFuture = _probeVideo(file);

    final checkResult = await _checkUploadedChunks(fileMd5, fileSize);
    final uploadedChunks = checkResult['chunks'] as List<int>;
    final instantUpload = checkResult['instantUpload'] as bool;
    final fileID = checkResult['fileID'] as String? ?? '';
    if (onCancel?.call() == true) throw Exception('上传已取消');

    final probe = await probeFuture;

    if (instantUpload) {
      onProgress(1.0);
      return _getVideoInfo(fileID: fileID, size: fileSize, title: title, vid: vid, probe: probe);
    }

    // 尝试直传 OSS
    final useOSS = await _tryDirectUpload(
      file: file,
      fileMd5: fileMd5,
      fileName: fileName,
      fileSize: fileSize,
      uploadedChunks: uploadedChunks,
      onProgress: onProgress,
      onCancel: onCancel,
      fileID: fileID,
    );

    if (!useOSS) {
      // fallback: 原始 VPS 代理分片上传
      await _uploadInChunks(
        file: file,
        fileMd5: fileMd5,
        fileName: fileName,
        uploadedChunks: uploadedChunks,
        onProgress: onProgress,
        onCancel: onCancel,
      );
      if (onCancel?.call() == true) throw Exception('上传已取消');
      await _mergeChunks(hash: fileMd5, fileID: fileID, size: fileSize);
    }

    if (onCancel?.call() == true) throw Exception('上传已取消');
    return _getVideoInfo(fileID: fileID, size: fileSize, title: title, vid: vid, probe: probe);
  }

  /// 尝试直传 OSS，返回 true 表示成功（或秒传），false 表示应回退 VPS 代理
  static Future<bool> _tryDirectUpload({
    required File file,
    required String fileMd5,
    required String fileName,
    required int fileSize,
    required List<int> uploadedChunks,
    required Function(double) onProgress,
    required bool Function()? onCancel,
    required String fileID,
  }) async {
    const int chunkSize = 5 * 1024 * 1024;
    const int maxRetries = 5;

    try {
      final totalChunks = (fileSize / chunkSize).ceil();

      // 1. 初始化直传（只返回第一批20个预签名URL）
      final initRes = await _dio.post('/api/v1/upload/initVideo', data: {
        'hash': fileMd5,
        'size': fileSize,
        'fileName': fileName,
        'totalChunks': totalChunks,
      });
      final initData = initRes.data as Map<String, dynamic>;
      if (initData['code'] != 200) return false;

      final initInfo = initData['data'] as Map<String, dynamic>;
      final initFileID = initInfo['fileID'] as String;
      final initUploadID = initInfo['uploadID'] as String?;
      final initTotalChunks = initInfo['totalChunks'] as int? ?? totalChunks;
      final initChunks = initInfo['chunks'] as List<dynamic>?;
      var nextBatchStart = initInfo['nextBatchStart'] as int? ?? -1;

      // 秒传
      if (initTotalChunks == 0) {
        onProgress(1.0);
        return true;
      }

      if (initChunks == null || initChunks.isEmpty) return false;

      // 2. 分批上传：收集 {partNumber, etag}
      final parts = <Map<String, dynamic>>[];
      var uploadedCount = uploadedChunks.length;
      List<dynamic> currentChunks = initChunks;

      while (currentChunks.isNotEmpty) {
        if (onCancel?.call() == true) throw Exception('上传已取消');

        for (final chunk in currentChunks) {
          final chunkMap = chunk as Map<String, dynamic>;
          final index = chunkMap['index'] as int;
          final partNumber = chunkMap['partNumber'] as int;
          final presignURL = chunkMap['presignURL'] as String;

          if (uploadedChunks.contains(index)) continue;

          final start = index * chunkSize;
          final end = (start + chunkSize > fileSize) ? fileSize : start + chunkSize;

          // 带重试的 PUT 上传，返回 ETag
          String? etag;
          for (int retry = 0; retry <= maxRetries; retry++) {
            try {
              etag = await _putChunkToOSS(presignURL, file, start, end);
              break;
            } catch (_) {
              if (retry < maxRetries) {
                await Future.delayed(Duration(milliseconds: 1000 * (1 << retry)));
                continue;
              }
              return false;
            }
          }

          if (etag == null) return false;

          parts.add({'partNumber': partNumber, 'etag': etag});
          uploadedCount++;
          onProgress((uploadedCount / initTotalChunks).clamp(0.0, 1.0));
        }

        // 当前批次上传完毕，续签下一批
        if (nextBatchStart == -1 || nextBatchStart >= initTotalChunks) break;

        if (onCancel?.call() == true) throw Exception('上传已取消');

        final presignRes = await _dio.post('/api/v1/upload/presignChunks', data: {
          'fileID': initFileID,
          'start': nextBatchStart,
          'count': 20,
        });
        final presignData = presignRes.data as Map<String, dynamic>;
        if (presignData['code'] != 200) return false;

        final presignInfo = presignData['data'] as Map<String, dynamic>;
        currentChunks = presignInfo['chunks'] as List<dynamic>? ?? [];
        nextBatchStart = presignInfo['nextBatchStart'] as int? ?? -1;
      }

      if (onCancel?.call() == true) throw Exception('上传已取消');

      // 3. 校验分片数
      if (parts.length != initTotalChunks) return false;

      // 4. 通知服务器完成合并
      final completeRes = await _dio.post('/api/v1/upload/completeVideo', data: {
        'fileID': initFileID,
        'uploadID': initUploadID,
        'parts': parts,
      });
      final completeData = completeRes.data as Map<String, dynamic>;
      if (completeData['code'] != 200) return false;

      onProgress(1.0);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// PUT 分片到 OSS，返回 ETag
  static Future<String> _putChunkToOSS(String presignURL, File file, int start, int end) async {
    final dio = Dio();
    try {
      final raf = await file.open();
      await raf.setPosition(start);
      final bytes = await raf.read(end - start);
      await raf.close();

      final response = await dio.put(
        presignURL,
        data: Stream.fromIterable([bytes]),
        options: Options(
          headers: {
            'Content-Length': bytes.length,
            'Content-Type': 'application/octet-stream',
          },
        ),
      );

      final etag = response.headers.value('etag');
      if (etag == null) throw Exception('Missing ETag header');
      return etag;
    } finally {
      dio.close();
    }
  }

  /// 流式计算文件MD5（避免大文件内存溢出）
  static Future<String> _calculateFileMd5(File file, {bool Function()? onCancel}) async {
    final stream = file.openRead();

    Stream<List<int>> cancelableStream = stream.transform(
      StreamTransformer.fromHandlers(
        handleData: (data, sink) {
          if (onCancel?.call() == true) {
            sink.close();
            throw Exception('MD5计算已取消');
          }
          sink.add(data);
        },
      ),
    );

    final digest = await md5.bind(cancelableStream).first;
    final md5Hash = digest.toString();

    return md5Hash;
  }

  /// 检查已上传的分片
  /// 返回 { chunks: 已上传分片列表, fileID: 视频文件ID, instantUpload: 是否可秒传 }
  static Future<Map<String, dynamic>> _checkUploadedChunks(String hash, int size) async {
    final response = await _dio.post(
      '/api/v1/upload/checkVideo',
      data: {'hash': hash, 'size': size},
    );

    final data = response.data as Map<String, dynamic>;
    if (data['code'] == 200) {
      final chunks = data['data']['chunks'] as List<dynamic>?;
      final chunkList = chunks?.map((e) => e as int).toList() ?? [];
      final fileID = data['data']['fileID'] as String? ?? '';

      // 后端返回 [-1] 表示文件已就绪，可以秒传
      if (chunkList.length == 1 && chunkList[0] == -1) {
        return {'chunks': <int>[], 'fileID': fileID, 'instantUpload': true};
      }
      return {'chunks': chunkList, 'fileID': fileID, 'instantUpload': false};
    } else {
      throw Exception(data['msg'] ?? '检查分片失败');
    }
  }

  /// 分片上传
  static Future<void> _uploadInChunks({
    required File file,
    required String fileMd5,
    required String fileName,
    required List<int> uploadedChunks,
    required Function(double) onProgress,
    bool Function()? onCancel,
  }) async {
    const int chunkSize = 5 * 1024 * 1024; // 5MB
    const int maxConcurrent = 5;

    final fileSize = await file.length();
    final totalChunks = (fileSize / chunkSize).ceil();


    final chunksToUpload = <int>[];
    for (int i = 0; i < totalChunks; i++) {
      if (!uploadedChunks.contains(i)) {
        chunksToUpload.add(i);
      }
    }

    if (chunksToUpload.isEmpty) {
      onProgress(1.0);
      return;
    }

    int uploadedCount = uploadedChunks.length;

    for (int i = 0; i < chunksToUpload.length; i += maxConcurrent) {
      if (onCancel?.call() == true) {
        throw Exception('上传已取消');
      }

      final endIndex = (i + maxConcurrent > chunksToUpload.length)
          ? chunksToUpload.length
          : i + maxConcurrent;
      final futures = <Future>[];

      for (int j = i; j < endIndex; j++) {
        final chunkIndex = chunksToUpload[j];
        futures.add(_uploadChunk(
          file: file,
          hash: fileMd5,
          fileName: fileName,
          chunkIndex: chunkIndex,
          totalChunks: totalChunks,
          chunkSize: chunkSize,
          fileSize: fileSize,
        ));
      }

      await Future.wait(futures);

      uploadedCount += futures.length;
      final progress = uploadedCount / totalChunks;
      onProgress(progress);

    }
  }

  /// 上传单个分片
  static Future<void> _uploadChunk({
    required File file,
    required String hash,
    required String fileName,
    required int chunkIndex,
    required int totalChunks,
    required int chunkSize,
    required int fileSize,
  }) async {
    final start = chunkIndex * chunkSize;
    final end = (start + chunkSize > fileSize) ? fileSize : start + chunkSize;

    final randomAccessFile = await file.open();
    await randomAccessFile.setPosition(start);
    final chunkBytes = await randomAccessFile.read(end - start);
    await randomAccessFile.close();

    final formData = FormData.fromMap({
      'hash': hash,
      'name': fileName,
      'chunkIndex': chunkIndex.toString(),
      'totalChunks': totalChunks.toString(),
      'size': fileSize.toString(),
      'video': MultipartFile.fromBytes(
        chunkBytes,
        filename: 'chunk_$chunkIndex',
      ),
    });

    final response = await _dio.post(
      '/api/v1/upload/chunkVideo',
      data: formData,
    );

    final data = response.data as Map<String, dynamic>;
    if (data['code'] != 200) {
      throw Exception(data['msg'] ?? '分片上传失败 (chunk $chunkIndex)');
    }
  }

  /// 合并分片
  static Future<void> _mergeChunks({required String hash, required String fileID, required int size}) async {
    final response = await _dio.post(
      '/api/v1/upload/mergeVideo',
      data: {'hash': hash, 'fileID': fileID, 'size': size},
    );

    final data = response.data as Map<String, dynamic>;
    if (data['code'] != 200) {
      throw Exception(data['msg'] ?? '合并分片失败');
    }
  }

  /// 获取视频信息
static Future<Map<String, dynamic>> _getVideoInfo({required String fileID, required int size, required String title, String? vid, Map<String, dynamic>? probe}) async {
    final endpoint = vid != null ? '/api/v1/upload/video/$vid' : '/api/v1/upload/video';


    final response = await _dio.post(
      endpoint,
      data: {
        'fileID': fileID,
        'size': size,
        'title': title,
        if (probe != null) ...{
          if ((probe['duration'] ?? 0) > 0) 'duration': probe['duration'],
          if ((probe['width'] ?? 0) > 0) 'width': probe['width'],
          if ((probe['height'] ?? 0) > 0) 'height': probe['height'],
        },
      },
    );

    final data = response.data as Map<String, dynamic>;
    if (data['code'] == 200) {
      return data['data']['resource'] as Map<String, dynamic>;
    } else {
      throw Exception(data['msg'] ?? '获取视频信息失败');
    }
  }

  /// 删除视频资源
  static Future<void> deleteVideoResource(int resourceId) async {
    final response = await _dio.post(
      '/api/v1/upload/video/resource/delete',
      data: {'id': resourceId},
    );

    final data = response.data as Map<String, dynamic>;
    if (data['code'] != 200) {
      throw Exception(data['msg'] ?? '删除视频资源失败');
    }
  }
}
