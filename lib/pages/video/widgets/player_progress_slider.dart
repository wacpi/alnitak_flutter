import 'package:flutter/material.dart';

/// 播放器进度条行（时间 + 进度条 + 时间），从 CustomPlayerUI 拆出。
/// pili_plus 风格：秒级 ValueNotifier，拖拽时由父组件冻结位置更新。
class PlayerProgressSlider extends StatelessWidget {
  final ValueNotifier<int> sliderPositionSeconds;
  final ValueNotifier<int> durationSeconds;
  final ValueNotifier<int> bufferedSeconds;
  final VoidCallback onSliderDragStart;
  final void Function(Duration) onSliderDragUpdate;
  final void Function(Duration) onSliderDragEnd;
  final String Function(Duration) formatDuration;
  final VoidCallback onInteraction;

  const PlayerProgressSlider({
    super.key,
    required this.sliderPositionSeconds,
    required this.durationSeconds,
    required this.bufferedSeconds,
    required this.onSliderDragStart,
    required this.onSliderDragUpdate,
    required this.onSliderDragEnd,
    required this.formatDuration,
    required this.onInteraction,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: sliderPositionSeconds,
      builder: (context, posSeconds, _) {
        return ValueListenableBuilder<int>(
          valueListenable: durationSeconds,
          builder: (context, durSeconds, _) {
            return ValueListenableBuilder<int>(
              valueListenable: bufferedSeconds,
              builder: (context, bufSeconds, _) {
                final maxVal = durSeconds > 0 ? durSeconds.toDouble() : 1.0;
                final displayPos = Duration(seconds: posSeconds);
                final displayDur = Duration(seconds: durSeconds);

                return Row(
                  children: [
                    Text(
                      formatDuration(displayPos),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4.0,
                          thumbShape: const _PlayerSliderThumbShape(
                            enabledThumbRadius: 7,
                            thumbColor: Colors.blue,
                            borderColor: Colors.white,
                            borderWidth: 2,
                          ),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
                          activeTrackColor: Colors.blue,
                          inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                          thumbColor: Colors.blue,
                          secondaryActiveTrackColor: Colors.white.withValues(alpha: 0.5),
                        ),
                        child: Slider(
                          value: posSeconds.toDouble().clamp(0.0, maxVal),
                          min: 0,
                          max: maxVal,
                          secondaryTrackValue: bufSeconds.toDouble().clamp(0.0, maxVal),
                          onChangeStart: (_) => onSliderDragStart(),
                          onChanged: (v) {
                            onSliderDragUpdate(Duration(seconds: v.toInt()));
                            onInteraction();
                          },
                          onChangeEnd: (v) {
                            onSliderDragEnd(Duration(seconds: v.toInt()));
                            onInteraction();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatDuration(displayDur),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _PlayerSliderThumbShape extends SliderComponentShape {
  final double enabledThumbRadius;
  final Color thumbColor;
  final Color borderColor;
  final double borderWidth;

  const _PlayerSliderThumbShape({
    this.enabledThumbRadius = 7.0,
    this.thumbColor = Colors.blue,
    this.borderColor = Colors.white,
    this.borderWidth = 2.0,
  });

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return Size.fromRadius(enabledThumbRadius);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;
    final Paint paint = Paint()
      ..color = thumbColor
      ..style = PaintingStyle.fill;

    final Paint borderPaint = Paint()
      ..color = borderColor
      ..strokeWidth = borderWidth
      ..style = PaintingStyle.stroke;

    final radius = enabledThumbRadius;
    final path = Path()..addOval(Rect.fromCircle(center: center, radius: radius));

    canvas.drawPath(path, borderPaint);
    canvas.drawPath(path, paint);
  }
}
