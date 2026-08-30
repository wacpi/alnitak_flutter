/// 媒体源类型
enum DataSourceType { network, file, asset }

/// 媒体数据源（参考 pilipala DataSource）
///
/// 统一描述视频和音频的播放源信息
class DataSource {
  /// 视频源（URL 或本地临时文件路径）
  final String videoSource;

  /// 外挂音频源 URL（用于 audio-files 挂载）
  final String? audioSource;

  /// 源类型
  final DataSourceType type;

  /// HTTP 请求头
  final Map<String, String>? httpHeaders;

  /// 是否为原生 DASH MPD 源（mpv 直接加载 MPD 整个清单，音视频由播放器原生解析）
  ///
  /// 为 true 时 [videoSource] 是完整 MPD URL，[audioSource] 恒为 null。
  /// 播放器不再需要 audio-files 外挂音频，也不应使用音视频分离流的补丁参数。
  final bool nativeMpd;

  const DataSource({
    required this.videoSource,
    this.audioSource,
    this.type = DataSourceType.network,
    this.httpHeaders,
    this.nativeMpd = false,
  });
}
