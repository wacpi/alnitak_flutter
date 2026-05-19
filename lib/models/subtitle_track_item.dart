import '../utils/json_field.dart';

/// 与后端 `GET /api/v1/video/subtitle/list` 返回的 tracks 项一致（见 web subtitle.d.ts）。
class SubtitleTrackItem {
  final int id;
  final String lang;
  final String label;
  final String url;
  final bool isDefault;

  const SubtitleTrackItem({
    required this.id,
    required this.lang,
    required this.label,
    required this.url,
    required this.isDefault,
  });

  factory SubtitleTrackItem.fromJson(Map<String, dynamic> json) {
    return SubtitleTrackItem(
      id: jsonAsInt(json['id']),
      lang: jsonAsString(json['lang']),
      label: jsonAsString(json['label']),
      url: jsonAsString(json['url']),
      isDefault: json['isDefault'] == true || json['is_default'] == true,
    );
  }

  /// 播放器 UI：展示名
  String get displayLabel => label.isNotEmpty ? label : lang;
}
