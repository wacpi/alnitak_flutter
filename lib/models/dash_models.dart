import '../config/api_config.dart';
import 'data_source.dart';

/// DASH 视频流信息
class DashVideoItem {
  final String id;
  final String baseUrl;
  final int bandwidth;
  final String mimeType;
  final String codecs;
  final int width;
  final int height;
  final String frameRate;

  const DashVideoItem({
    required this.id,
    required this.baseUrl,
    required this.bandwidth,
    required this.mimeType,
    required this.codecs,
    required this.width,
    required this.height,
    required this.frameRate,
  });

  factory DashVideoItem.fromJson(Map<String, dynamic> json) {
    return DashVideoItem(
      id: json['id']?.toString() ?? '',
      baseUrl: json['baseUrl']?.toString() ?? '',
      bandwidth: json['bandwidth'] as int? ?? 0,
      mimeType: json['mimeType']?.toString() ?? 'video/mp4',
      codecs: json['codecs']?.toString() ?? '',
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      frameRate: json['frameRate']?.toString() ?? '30.000',
    );
  }
}

/// DASH 音频流信息
class DashAudioItem {
  final String id;
  final String baseUrl;
  final int bandwidth;
  final String mimeType;
  final String codecs;

  const DashAudioItem({
    required this.id,
    required this.baseUrl,
    required this.bandwidth,
    required this.mimeType,
    required this.codecs,
  });

  factory DashAudioItem.fromJson(Map<String, dynamic> json) {
    return DashAudioItem(
      id: json['id']?.toString() ?? '',
      baseUrl: json['baseUrl']?.toString() ?? '',
      bandwidth: json['bandwidth'] as int? ?? 0,
      mimeType: json['mimeType']?.toString() ?? 'audio/mp4',
      codecs: json['codecs']?.toString() ?? '',
    );
  }
}

/// 单个清晰度的 DASH 数据
class DashStreamInfo {
  final String quality;
  final double duration;
  final DashVideoItem video;
  final DashAudioItem? audio;

  const DashStreamInfo({
    required this.quality,
    required this.duration,
    required this.video,
    this.audio,
  });
}

/// 完整 DASH manifest（所有清晰度）
///
/// 仿 pili_plus：一次性缓存所有清晰度数据，
/// 切换清晰度时直接从缓存取 DataSource，无需再次请求 API。
class DashManifest {
  final Map<String, DashStreamInfo> streams;
  final List<String> qualities;
  final bool supportsDash;
  final DateTime fetchedAt;

  /// 原生 DASH MPD 完整 URL（含清晰度切换/音频分离等全部信息）。
  ///
  /// 非空时优先直接交给播放器加载整个 MPD，由 mpv 原生解析音视频与多清晰度，
  /// 不再手工拆流。为 null 表示该 manifest 来自 JSON/m3u8 回退路径。
  final String? mpdUrl;

  /// 后端声明的清晰度切换方式，来自 `/getResourceQuality` 的 `dashSwitchMode`：
  /// - `"reload"`: 转码产物未对齐，切换需重载固定档清单并保持进度（安全路径）。
  /// - `"representation"`: 转码产物已对齐，可用原生 Representation 无缝切换。
  final String dashSwitchMode;

  /// 是否可用原生 DASH 视频轨切换（mpv `setVideoTrack`）。
  ///
  /// 必须同时满足两个条件：
  /// 1. 所有视频档位属于单个 AdaptationSet（单 AS 多 Rep 结构）；
  /// 2. 后端 `dashSwitchMode == "representation"`（转码产物已对齐）。
  ///
  /// 否则必须走 reload（重载固定档并恢复位置），避免在未对齐产物上
  /// 原生切轨导致重新 seek 拉取而卡黑屏。
  final bool supportsNativeQualitySwitching;

  const DashManifest({
    required this.streams,
    required this.qualities,
    required this.supportsDash,
    required this.fetchedAt,
    this.mpdUrl,
    this.dashSwitchMode = 'reload',
    this.supportsNativeQualitySwitching = false,
  });

  /// 从缓存获取指定清晰度的 DataSource
  ///
  /// 对齐的原生 MPD 可让播放器在同一清单内切换；非对齐 MPD 则从
  /// 已解析的固定 rendition 直链创建数据源，以保持切换结果确定。
  DataSource? getDataSource(String quality, {bool preferNativeMpd = true}) {
    if (mpdUrl != null && preferNativeMpd) {
      return DataSource(
        videoSource: mpdUrl!,
        httpHeaders: _defaultHttpHeaders,
        nativeMpd: true,
      );
    }

    final stream = streams[quality];
    if (stream == null) return null;

    final videoUrl = _resolveUrl(stream.video.baseUrl);
    final audioUrl =
        stream.audio != null ? _resolveUrl(stream.audio!.baseUrl) : null;

    return DataSource(
      videoSource: videoUrl,
      audioSource: audioUrl,
      httpHeaders: _defaultHttpHeaders,
    );
  }

  /// 播放器默认 HTTP 请求头（参考 pili_plus）
  static Map<String, String> get _defaultHttpHeaders => {
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'referer': ApiConfig.baseUrl,
      };

  /// 缓存是否已过期（默认 25 分钟，服务端 key TTL 通常 30 分钟）
  bool get isExpired => DateTime.now().difference(fetchedAt).inMinutes >= 25;

  /// 解析 URL：相对路径拼接 baseUrl，绝对路径直接使用
  static String _resolveUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    return '${ApiConfig.baseUrl}$url';
  }
}
