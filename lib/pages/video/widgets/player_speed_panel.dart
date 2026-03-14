import 'package:flutter/material.dart';

/// 倍速选择面板（从 CustomPlayerUI 拆出）
/// 依赖由父组件传入
class PlayerSpeedPanel extends StatelessWidget {
  static const List<double> defaultSpeedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  final List<double> speeds;
  final double currentSpeed;
  final void Function(double speed) onSelect;
  final double right;
  final double bottom;

  const PlayerSpeedPanel({
    super.key,
    required this.speeds,
    required this.currentSpeed,
    required this.onSelect,
    this.right = 100,
    this.bottom = 50,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: right - 12, // 向右偏移，与原逻辑一致
      bottom: bottom,
      child: GestureDetector(
        onTap: () {}, // 拦截点击穿透
        child: Container(
          width: 64,
          constraints: const BoxConstraints(maxHeight: 180),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: speeds.map((speed) {
                final isSelected = speed == currentSpeed;
                return InkWell(
                  onTap: () => onSelect(speed),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    alignment: Alignment.center,
                    child: Text(
                      speed == 1.0 ? '正常' : '${speed}x',
                      style: TextStyle(
                        color: isSelected ? Colors.blue : Colors.white,
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}
