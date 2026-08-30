import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../utils/redirect_http_service.dart';

/// 自定义缓存管理器 - 使用稳定的缓存 key 避免重复缓存
///
/// 当 URL 包含时间戳等变化参数时，提取基础 URL 作为缓存 key
/// 这样即使 URL 变化，也会覆盖旧缓存而不是创建新缓存
class SmartCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'smartImageCache';

  static final SmartCacheManager _instance = SmartCacheManager._();
  factory SmartCacheManager() => _instance;

  SmartCacheManager._() : super(
    Config(
      key,
      stalePeriod: const Duration(days: 30), // 【优化】30天后过期，减少重复下载
      maxNrOfCacheObjects: 2000, // 【优化】缓存2000个文件
      repo: JsonCacheInfoRepository(databaseName: key),
      fileService: RedirectAwareHttpFileService(), // 使用支持重定向的服务
    ),
  );

  /// 覆写缓存流：命中缓存但文件为空/缺失时，清除索引并重新下载
  ///
  /// 修复切换 API 地址后出现 `Bad state: LocalFile...is empty`：
  /// 下载中断/失败可能遗留 0 字节文件，直接解码会抛异常。
  ///
  /// 注意：cached_network_image 走 getImageFile(withProgress: true) 时
  /// 内部仍会调用本方法，因此校验必须在所有 withProgress 下都执行。
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    // 命中索引但文件为空/缺失 → 清除索引（触发重新下载）
    await _removeInvalidCacheEntries([key ?? url]);
    // 透传父类流，并校验每个最终产出的 FileInfo：
    // 覆盖“新下载的文件本身就是空的”（服务器返回空 body）场景
    await for (final response in super.getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
    )) {
      if (response is FileInfo && await _isEmptyOrMissing(response.file)) {
        await removeFile(key ?? url);
        throw StateError('下载的文件为空，无法作为图片加载: ${response.file.path}');
      }
      yield response;
    }
  }

  /// 覆写图片缓存流：resized 分支直接 yield 缓存 FileInfo，
  /// 不会经过 [getFileStream]，需在此同样校验空文件
  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) async* {
    // 原 key 与可能的 resized key 都要校验
    final baseKey = key ?? url;
    final keysToCheck = <String>[baseKey];
    if (maxHeight != null || maxWidth != null) {
      var resizedKey = 'resized';
      if (maxWidth != null) resizedKey += '_w$maxWidth';
      if (maxHeight != null) resizedKey += '_h$maxHeight';
      keysToCheck.add('${resizedKey}_$baseKey');
    }
    await _removeInvalidCacheEntries(keysToCheck);
    yield* super.getImageFile(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
    );
  }

  /// 检查缓存命中项，文件不存在或为 0 字节时清除索引（触发重新下载）
  Future<void> _removeInvalidCacheEntries(List<String> keys) async {
    for (final cacheKey in keys) {
      final cached = await getFileFromCache(cacheKey);
      if (cached == null) continue;
      try {
        if (await _isEmptyOrMissing(cached.file)) {
          await removeFile(cacheKey);
        }
      } catch (_) {
        // 校验失败不阻塞加载，交给父类逻辑处理
      }
    }
  }

  /// 文件不存在或为 0 字节时返回 true（无法作为图片解码）
  static Future<bool> _isEmptyOrMissing(File file) async {
    if (!await file.exists()) return true;
    return await file.length() == 0;
  }

  /// 预加载图片到缓存
  /// 用于提前加载即将显示的图片
  static Future<void> preloadImage(String url) async {
    try {
      await _instance.getSingleFile(url, key: getStableCacheKey(url));
    } catch (_) {
      // 预加载失败不影响功能，图片会在显示时重新加载
    }
  }

  /// 批量预加载图片
  static Future<void> preloadImages(List<String> urls) async {
    // 并发预加载，但限制并发数为5
    final futures = <Future>[];
    for (int i = 0; i < urls.length; i++) {
      futures.add(preloadImage(urls[i]));
      // 每5个并发一组
      if (futures.length >= 5) {
        await Future.wait(futures);
        futures.clear();
      }
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  /// 从 URL 提取稳定的缓存 key
  /// 移除时间戳、随机数等变化参数
  static String getStableCacheKey(String url) {
    try {
      final uri = Uri.parse(url);
      // 移除常见的缓存破坏参数
      final cleanParams = Map<String, String>.from(uri.queryParameters)
        ..remove('t')
        ..remove('time')
        ..remove('timestamp')
        ..remove('_t')
        ..remove('_')
        ..remove('random')
        ..remove('r')
        ..remove('v')
        ..remove('version');

      // 重建 URL（不含变化参数）
      final cleanUri = uri.replace(queryParameters: cleanParams.isEmpty ? null : cleanParams);
      return cleanUri.toString();
    } catch (e) {
      // 解析失败时使用原 URL
      return url;
    }
  }
}

/// 安全地将 double 转换为 int，处理 Infinity 和 NaN
int? _safeToInt(double? value) {
  if (value == null || value.isNaN || value.isInfinite) {
    return null;
  }
  return value.toInt();
}

/// 带缓存的网络图片组件
///
/// 自动处理图片加载、缓存、错误和占位符
/// 【优化】使用稳定的缓存 key，避免 URL 变化导致的重复缓存
class CachedImage extends StatelessWidget {
  final String imageUrl;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final Widget? errorWidget;
  final BorderRadius? borderRadius;
  /// 自定义缓存 key（可选）
  /// 如果提供，将使用此 key 而不是从 URL 提取
  final String? cacheKey;

  const CachedImage({
    super.key,
    required this.imageUrl,
    this.fit,
    this.width,
    this.height,
    this.placeholder,
    this.errorWidget,
    this.borderRadius,
    this.cacheKey,
  });

  @override
  Widget build(BuildContext context) {
    // 使用自定义 key 或从 URL 提取稳定 key
    final effectiveCacheKey = cacheKey ?? SmartCacheManager.getStableCacheKey(imageUrl);

    Widget imageWidget = CachedNetworkImage(
      imageUrl: imageUrl,
      cacheKey: effectiveCacheKey, // 【关键】使用稳定的缓存 key
      cacheManager: SmartCacheManager(), // 使用自定义缓存管理器
      fit: fit ?? BoxFit.cover,
      width: width,
      height: height,
      // 【优化】极短的淡入时间，几乎立即显示
      fadeInDuration: const Duration(milliseconds: 50),
      fadeOutDuration: Duration.zero,
      // 加载中：带闪烁动画的骨架屏
      placeholder: placeholder != null
          ? (context, url) => placeholder!
          : (context, url) => _ShimmerPlaceholder(
                width: width,
                height: height,
              ),
      errorWidget: errorWidget != null
          ? (context, url, error) => errorWidget!
          : (context, url, error) {
              final isDark = Theme.of(context).brightness == Brightness.dark;
              return Container(
                color: isDark ? const Color(0xFF3C3C3C) : Colors.grey[300],
                child: Icon(
                  Icons.broken_image,
                  color: isDark ? const Color(0xFF808080) : Colors.grey,
                ),
              );
            },
      // 根据实际显示尺寸缓存（防止 Infinity/NaN 导致崩溃）
      memCacheWidth: _safeToInt(width),
      memCacheHeight: _safeToInt(height),
      maxHeightDiskCache: 800,
      maxWidthDiskCache: 800,
    );

    if (borderRadius != null) {
      return ClipRRect(
        borderRadius: borderRadius!,
        child: imageWidget,
      );
    }

    return imageWidget;
  }
}

/// 静态骨架屏占位符（性能优化：移除动画，减少CPU消耗）
/// 多个图片同时加载时，静态占位符比闪烁动画性能更好
class _ShimmerPlaceholder extends StatelessWidget {
  final double? width;
  final double? height;

  const _ShimmerPlaceholder({this.width, this.height});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: width,
      height: height,
      color: isDark ? const Color(0xFF2C2C2C) : Colors.grey[200],
    );
  }
}

/// 圆形头像图片组件
/// 【优化】使用稳定的缓存 key，避免头像 URL 变化导致的重复缓存
class CachedCircleAvatar extends StatelessWidget {
  final String imageUrl;
  final double radius;
  final Widget? placeholder;
  final Widget? errorWidget;
  /// 自定义缓存 key（可选）
  /// 推荐使用用户 ID 作为缓存 key，这样头像更新时会自动覆盖旧缓存
  final String? cacheKey;

  const CachedCircleAvatar({
    super.key,
    required this.imageUrl,
    this.radius = 20,
    this.placeholder,
    this.errorWidget,
    this.cacheKey,
  });

  @override
  Widget build(BuildContext context) {
    // 使用自定义 key 或从 URL 提取稳定 key
    final effectiveCacheKey = cacheKey ?? SmartCacheManager.getStableCacheKey(imageUrl);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return CircleAvatar(
      radius: radius,
      backgroundColor: isDark ? const Color(0xFF2C2C2C) : Colors.grey[200],
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: imageUrl,
          cacheKey: effectiveCacheKey, // 【关键】使用稳定的缓存 key
          cacheManager: SmartCacheManager(), // 使用自定义缓存管理器
          fit: BoxFit.cover,
          width: radius * 2,
          height: radius * 2,
          // 【优化】极短的淡入时间，几乎立即显示
          fadeInDuration: const Duration(milliseconds: 50),
          fadeOutDuration: Duration.zero,
          // 【性能优化】使用空容器占位，头像背景色已由 CircleAvatar 提供
          placeholder: placeholder != null
              ? (context, url) => placeholder!
              : (context, url) => const SizedBox(),
          errorWidget: errorWidget != null
              ? (context, url, error) => errorWidget!
              : (context, url, error) => Icon(
                    Icons.person,
                    size: radius,
                    color: isDark ? const Color(0xFF808080) : Colors.grey,
                  ),
          memCacheWidth: (radius * 2 * 2).toInt(), // 2x for retina
          memCacheHeight: (radius * 2 * 2).toInt(),
          maxHeightDiskCache: (radius * 2 * 2).toInt(),
          maxWidthDiskCache: (radius * 2 * 2).toInt(),
        ),
      ),
    );
  }
}
