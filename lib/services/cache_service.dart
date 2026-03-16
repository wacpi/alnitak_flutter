import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 播放器缓存清理服务
class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  /// 清理 MPV 播放器缓存目录
  Future<void> cleanupMpvCache() async {
    try {
      final tempDir = await getTemporaryDirectory();

      final mpvCacheDirs = [
        Directory('${tempDir.path}/mpv_cache'),
        Directory('${tempDir.path}/.mpv_cache'),
        Directory('${tempDir.path}/media_kit_cache'),
        Directory('${tempDir.path}/libmpv'),
        Directory('${tempDir.path}/mpv'),
        Directory('${tempDir.path}/hls_cache'),
      ];

      for (final dir in mpvCacheDirs) {
        if (await dir.exists()) {
          final files = dir.listSync(recursive: true);
          for (final file in files) {
            if (file is File) {
              try {
                await file.delete();
              } catch (_) {}
            }
          }
          try {
            if (dir.listSync().isEmpty) {
              await dir.delete();
            }
          } catch (_) {}
        }
      }

      // 仅清理播放器相关前缀文件，避免误删其他模块临时文件
      try {
        final tempFiles = tempDir.listSync();
        for (final entity in tempFiles) {
          if (entity is File) {
            if (shouldDeleteTempFile(entity.path)) {
              try {
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
    } catch (_) {}
  }

  /// 清理所有缓存
  Future<void> clearAllCache() async {
    await cleanupMpvCache();
  }

  /// 清理所有临时缓存（退出播放时调用）
  Future<void> cleanupAllTempCache() async {
    await cleanupMpvCache();
  }

  String _getFileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isNotEmpty ? parts.last : path;
  }

  @visibleForTesting
  bool shouldDeleteTempFile(String filePath) {
    final fileName = _getFileName(filePath).toLowerCase();
    return fileName.startsWith('mpv') ||
        fileName.startsWith('libmpv') ||
        fileName.startsWith('media_kit');
  }
}
