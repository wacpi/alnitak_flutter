import 'package:flutter/material.dart';

import '../../../controllers/video_player_controller.dart';
import '../../../models/subtitle_track_item.dart';

/// 字幕轨切换面板（与 [PlayerQualityPanel] 同源布局）
class PlayerSubtitlePanel extends StatelessWidget {
  final VideoPlayerController logic;
  final double right;
  final double bottom;
  final VoidCallback onSelect;

  const PlayerSubtitlePanel({
    super.key,
    required this.logic,
    this.right = 16,
    this.bottom = 50,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<SubtitleTrackItem>>(
      valueListenable: logic.subtitleTracks,
      builder: (context, tracks, _) {
        return ValueListenableBuilder<int?>(
          valueListenable: logic.selectedSubtitleIndex,
          builder: (context, cur, _) {
            return Positioned(
              right: right,
              bottom: bottom,
              child: GestureDetector(
                onTap: () {},
                child: Container(
                  width: 100,
                  constraints: const BoxConstraints(maxHeight: 220),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: () async {
                            await logic.disableSubtitles();
                            onSelect();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 10),
                            child: Center(
                              child: Text(
                                '关闭',
                                style: TextStyle(
                                  color: cur == null
                                      ? Colors.blue
                                      : Colors.white70,
                                  fontSize: 13,
                                  fontWeight: cur == null
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                        ),
                        for (var i = 0; i < tracks.length; i++)
                          InkWell(
                            onTap: () async {
                              await logic.selectSubtitleIndex(i);
                              onSelect();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 10),
                              child: Center(
                                child: Text(
                                  tracks[i].displayLabel,
                                  style: TextStyle(
                                    color: cur == i
                                        ? Colors.blue
                                        : Colors.white,
                                    fontSize: 13,
                                    fontWeight: cur == i
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
