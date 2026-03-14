import 'package:flutter/material.dart';

/// 播放器底部栏容器：进度条 + 控制按钮行。
/// 从 CustomPlayerUI 拆出，仅负责布局与样式，具体内容由父组件传入。
class PlayerBottomBar extends StatelessWidget {
  final Widget progressSlider;
  final Widget controlRow;

  const PlayerBottomBar({
    super.key,
    required this.progressSlider,
    required this.controlRow,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 13),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.3)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              progressSlider,
              const SizedBox(height: 2),
              controlRow,
            ],
          ),
        ),
      ),
    );
  }
}
