import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/subtitle_track_item.dart';

/// 播放器设置持久化服务
///
/// 从 VideoPlayerController 中提取的纯设置 CRUD 方法，
/// 与播放器运行时状态无关。
class PlayerSettingsService {
  static const String _decodeModeKey = 'video_decode_mode';
  static const String _expandBufferKey = 'video_expand_buffer';
  static const String _audioOutputKey = 'video_audio_output';

  /// 与 Web「subtitle-preference」、wplayer-next 同源 localStorage key
  static const String subtitlePreferenceKey = 'alnitak-pref-subtitle-track';

  static Future<void> saveSubtitlePreference(
      {required String label, required String lang}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      subtitlePreferenceKey,
      jsonEncode({'label': label.trim(), 'lang': lang.trim()}),
    );
  }

  /// 无记忆或未匹配任一轨则返回第一条（下标 `0`）。
  static Future<int> pickPreferredSubtitleTrackIndex(
      List<SubtitleTrackItem> tracks) async {
    if (tracks.isEmpty) return 0;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(subtitlePreferenceKey);
    if (raw == null || raw.isEmpty) return 0;
    try {
      final o = jsonDecode(raw);
      if (o is! Map) return 0;
      final plRaw = o['label'];
      final langRaw = o['lang'];
      final pl = plRaw is String ? plRaw.trim() : '';
      final lang = langRaw is String ? langRaw.trim() : '';
      if (pl.isEmpty && lang.isEmpty) return 0;
      String norm(String s) => s.trim().toLowerCase();
      if (pl.isNotEmpty) {
        final nl = norm(pl);
        for (var i = 0; i < tracks.length; i++) {
          if (norm(tracks[i].displayLabel) == nl) return i;
        }
      }
      if (lang.isNotEmpty) {
        final lc = norm(lang);
        for (var i = 0; i < tracks.length; i++) {
          if (norm(tracks[i].lang) == lc) return i;
        }
      }
    } catch (_) {
      /* bad json */
    }
    return 0;
  }

  static Future<String> getDecodeMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_decodeModeKey) ?? 'no';
  }

  static Future<void> setDecodeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_decodeModeKey, mode);
  }

  static Future<bool> getExpandBuffer() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_expandBufferKey) ?? true;
  }

  static Future<void> setExpandBuffer(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_expandBufferKey, value);
  }

  static Future<String> getAudioOutput() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_audioOutputKey) ?? 'audiotrack';
  }

  static Future<void> setAudioOutput(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_audioOutputKey, value);
  }

  static const String _subtitleConfigKey = 'subtitle_view_configuration';

  /// 响应式通知：有 player widget 监听时，修改设置可实时生效。
  static final subtitleConfigNotifier = ValueNotifier<SubtitleViewConfiguration>(
    const SubtitleViewConfiguration(),
  );

  static Future<void> _initNotifier() async {
    subtitleConfigNotifier.value = await _loadFromPrefs();
  }

  static Future<SubtitleViewConfiguration> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_subtitleConfigKey);
    if (raw == null || raw.isEmpty) return const SubtitleViewConfiguration();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      Color? loadedBg;
      if (map.containsKey('backgroundColor')) {
        loadedBg = map['backgroundColor'] != null ? Color(map['backgroundColor'] as int) : null;
      } else {
        loadedBg = const Color(0xaa000000);
      }
      Color? loadedStroke;
      if (map.containsKey('strokeColor')) {
        loadedStroke = map['strokeColor'] != null ? Color(map['strokeColor'] as int) : null;
      }
      return SubtitleViewConfiguration(
        visible: map['visible'] as bool? ?? true,
        fontSize: (map['fontSize'] as num?)?.toDouble() ?? 32.0,
        fontColor: Color(map['fontColor'] as int? ?? 0xffffffff),
        backgroundColor: loadedBg,
        strokeColor: loadedStroke,
        strokeWidth: (map['strokeWidth'] as num?)?.toDouble() ?? 0.0,
        shadow: map['shadow'] as bool? ?? false,
        fontWeight: FontWeight.values[map['fontWeightIndex'] as int? ?? 3],
      );
    } catch (_) {
      return const SubtitleViewConfiguration();
    }
  }

  static Future<SubtitleViewConfiguration> getSubtitleConfig() async {
    return _loadFromPrefs();
  }

  static Future<void> setSubtitleConfig(SubtitleViewConfiguration config) async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{
      'visible': config.visible,
      'fontSize': config.fontSize,
      'fontColor': config.fontColor.toARGB32(),
      'backgroundColor': config.backgroundColor?.toARGB32(),
      'strokeColor': config.strokeColor?.toARGB32(),
      'strokeWidth': config.strokeWidth,
      'shadow': config.shadow,
      'fontWeightIndex': FontWeight.values.indexOf(config.fontWeight),
    };
    await prefs.setString(_subtitleConfigKey, jsonEncode(map));
    subtitleConfigNotifier.value = config;
  }

  /// 应用启动时调用一次（在 main.dart 中），确保 notifier 持有正确初值。
  static Future<void> initialize() async {
    await _initNotifier();
  }

  static String getDecodeModeDisplayName(String mode) {
    switch (mode) {
      case 'no':
        return '软解码';
      case 'auto-copy':
        return '硬解码';
      default:
        return '软解码';
    }
  }

  static String getAudioOutputDisplayName(String value) {
    switch (value) {
      case 'audiotrack':
        return 'AudioTrack';
      case 'aaudio':
        return 'AAudio';
      case 'opensles':
        return 'OpenSL ES';
      default:
        return value;
    }
  }
}
