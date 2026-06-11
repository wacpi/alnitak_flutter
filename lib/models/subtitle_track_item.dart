import '../utils/json_field.dart';

/// 与后端 `GET /api/v1/video/subtitle/list` 返回的 tracks 项一致（见 web subtitle.d.ts）。
class SubtitleTrackItem {
  final int id;
  final String lang;
  final String label;
  final String url;
  final String? backupUrl;
  final bool isDefault;

  const SubtitleTrackItem({
    required this.id,
    required this.lang,
    required this.label,
    required this.url,
    this.backupUrl,
    required this.isDefault,
  });

  factory SubtitleTrackItem.fromJson(Map<String, dynamic> json) {
    return SubtitleTrackItem(
      id: jsonAsInt(json['id']),
      lang: jsonAsString(json['lang']),
      label: jsonAsString(json['label']),
      url: jsonAsString(json['url']),
      backupUrl: jsonAsStringOrNull(json['backupUrl']),
      isDefault: json['isDefault'] == true || json['is_default'] == true,
    );
  }

  /// 语言代码→显示名映射表（对齐 web LANG_CODE_TO_LABEL）
  static const Map<String, String> langCodeToLabel = {
    'zh-Hans': '简体中文',
    'zh-Hant': '繁體中文',
    'en': 'English',
    'ja': '日本語',
    'ko': '한국어',
    'vi': 'Tiếng Việt',
    'th': 'ภาษาไทย',
    'ms': 'Bahasa Melayu',
    'id': 'Bahasa Indonesia',
    'es': 'Español',
    'pt': 'Português',
    'ru': 'Русский',
  };

  /// 播放器 UI：展示名。优先用 label，否则查映射表，最后回退 lang 代码。
  String get displayLabel {
    if (label.isNotEmpty) return label;
    return langCodeToLabel[lang] ?? lang;
  }
}
