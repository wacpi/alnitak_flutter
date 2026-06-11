import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../utils/network_line_selector.dart';
import '../utils/url_utils.dart';
import '../utils/image_utils.dart';
import 'cached_image_widget.dart';

/// 多 OSS 容灾图片组件。
///
/// 根据全局 [NetworkLineSelector] 的结果决定先尝试主/备线路，
/// 加载失败后自动切换到另一条。两条都失败后停止重试。
///
/// 完全兼容 [CachedImage] 的 API，接受相对路径或完整 URL。
class OssImage extends StatefulWidget {
  /// 原始路径（相对或完整），同 CachedImage 的 imageUrl。
  /// 内部通过 [ImageUtils.getFullImageUrl] 解析，然后推导备用 URL。
  final String imageUrl;

  final BoxFit? fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final Widget? errorWidget;
  final BorderRadius? borderRadius;
  final String? cacheKey;

  const OssImage({
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
  State<OssImage> createState() => _OssImageState();
}

class _OssImageState extends State<OssImage> {
  String _currentUrl = '';
  bool _triedFallback = false;
  String? _primaryUrl;
  String? _backupUrl;

  @override
  void initState() {
    super.initState();
    NetworkLineSelector().selectedLineNotifier.addListener(_onLineChanged);
    _resolve();
  }

  @override
  void didUpdateWidget(OssImage old) {
    super.didUpdateWidget(old);
    if (widget.imageUrl != old.imageUrl) {
      _triedFallback = false;
      _resolve();
    }
  }

  @override
  void dispose() {
    NetworkLineSelector().selectedLineNotifier.removeListener(_onLineChanged);
    super.dispose();
  }

  void _onLineChanged() {
    if (!mounted) return;
    _triedFallback = false;
    _resolve();
  }

  void _resolve() {
    if (widget.imageUrl.isEmpty) {
      _currentUrl = '';
      return;
    }

    _primaryUrl = ImageUtils.getFullImageUrl(widget.imageUrl);
    _backupUrl = UrlUtils.getBackupUrl(_primaryUrl!);

    final line = NetworkLineSelector().selectedLine;
    if (line == NetworkLine.backup && _backupUrl != null) {
      _currentUrl = _backupUrl!;
    } else {
      _currentUrl = _primaryUrl!;
    }

    if (mounted) setState(() {});
  }

  void _onLoadError() {
    final selector = NetworkLineSelector();

    if (!_triedFallback) {
      _triedFallback = true;

      final primary = _primaryUrl;
      final backup = _backupUrl;
      if (primary == null) return;

      // 切换到另一条线路
      if (_currentUrl == primary && backup != null) {
        _currentUrl = backup;
      } else if (_currentUrl != primary) {
        _currentUrl = primary;
      } else {
        return; // 没有可用的回退
      }

      if (mounted) setState(() {});
      return;
    }

    // 两条线路都已尝试过且均失败 → 上报当前线路故障
    final line = NetworkLineSelector().selectedLine;
    if (line != null) {
      debugPrint('[OssImage] 主备线路均失败，上报 $line 故障');
      selector.reportLineFailure(line);
    }
  }

  Widget _buildPlaceholder(BuildContext context) {
    if (widget.placeholder != null) return widget.placeholder!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDark ? const Color(0xFF2C2C2C) : Colors.grey[200],
      width: widget.width,
      height: widget.height,
    );
  }

  Widget _buildError(BuildContext context) {
    if (widget.errorWidget != null) return widget.errorWidget!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDark ? const Color(0xFF3C3C3C) : Colors.grey[300],
      width: widget.width,
      height: widget.height,
      child: Icon(
        Icons.broken_image,
        color: isDark ? const Color(0xFF808080) : Colors.grey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_currentUrl.isEmpty) return _buildPlaceholder(context);

    final effectiveCacheKey = widget.cacheKey ??
        SmartCacheManager.getStableCacheKey(_currentUrl);

    Widget imageWidget = CachedNetworkImage(
      key: ValueKey('oss_$_currentUrl'),
      imageUrl: _currentUrl,
      cacheKey: effectiveCacheKey,
      cacheManager: SmartCacheManager(),
      fit: widget.fit ?? BoxFit.cover,
      width: widget.width,
      height: widget.height,
      fadeInDuration: const Duration(milliseconds: 50),
      fadeOutDuration: Duration.zero,
      placeholder: (context, url) => _buildPlaceholder(context),
      errorWidget: (context, url, error) {
        // 下一帧切换到备用线路
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onLoadError();
        });
        return _buildError(context);
      },
      memCacheWidth: _safeToInt(widget.width),
      memCacheHeight: _safeToInt(widget.height),
      maxHeightDiskCache: 800,
      maxWidthDiskCache: 800,
    );

    if (widget.borderRadius != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius!,
        child: imageWidget,
      );
    }

    return imageWidget;
  }
}

/// 安全地将 double 转换为 int，处理 Infinity 和 NaN
int? _safeToInt(double? value) {
  if (value == null || value.isNaN || value.isInfinite) return null;
  return value.toInt();
}
