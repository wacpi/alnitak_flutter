import 'package:flutter/material.dart';

/// 清晰度选择面板（从 CustomPlayerUI 拆出）
/// 依赖由父组件传入，便于单独维护与测试
class PlayerQualityPanel extends StatelessWidget {
  final List<String> qualities;
  final String? currentQuality;
  final String Function(String) getQualityDisplayName;
  final void Function(String quality) onSelect;
  final double right;
  final double bottom;

  const PlayerQualityPanel({
    super.key,
    required this.qualities,
    required this.currentQuality,
    required this.getQualityDisplayName,
    required this.onSelect,
    this.right = 16,
    this.bottom = 50,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: right,
      bottom: bottom,
      child: GestureDetector(
        onTap: () {}, // 拦截点击穿透
        child: Container(
          width: 76,
          constraints: const BoxConstraints(maxHeight: 200),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: qualities.map((quality) {
                final isSelected = quality == currentQuality;
                final displayName = getQualityDisplayName(quality);
                return InkWell(
                  onTap: () => onSelect(quality),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    alignment: Alignment.center,
                    child: buildQualityLabel(displayName, isSelected),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  /// 清晰度标签：高帧率后缀（如 "60"）使用特殊样式（供底部栏画质按钮等复用）
  static Widget buildQualityLabel(String displayName, bool isSelected) {
    final match = RegExp(r'^(.+?P|[24]K)(\d+)$').firstMatch(displayName);
    if (match == null) {
      return Text(
        displayName,
        style: TextStyle(
          color: isSelected ? Colors.blue : Colors.white,
          fontSize: 13,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
        textAlign: TextAlign.center,
      );
    }
    final base = match.group(1)!;
    final fps = match.group(2)!;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: base,
            style: TextStyle(
              color: isSelected ? Colors.blue : Colors.white,
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          TextSpan(
            text: fps,
            style: TextStyle(
              color: isSelected ? Colors.blue : const Color(0xFF4FC3F7),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
