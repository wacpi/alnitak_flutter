/// URL 工具类 — 多 OSS 容灾相关 URL 处理。
class UrlUtils {
  /// 从已拼接域名的完整 URL 推导备用 OSS URL。
  /// 仅对经过后端代理的路径有效（/api/image/、/api/subtitle/）。
  /// 直接 OSS 直链无法从客户端推导备用 URL。
  static String? getBackupUrl(String fullUrl) {
    if (fullUrl.isEmpty) return null;
    if (fullUrl.contains('backup=true')) return null;

    final uri = Uri.tryParse(fullUrl);
    if (uri == null) return null;

    if (uri.path.startsWith('/api/image/') ||
        uri.path.startsWith('/api/subtitle/')) {
      final sep = uri.hasQuery ? '&' : '?';
      return '$fullUrl${sep}backup=true';
    }

    return null;
  }
}
