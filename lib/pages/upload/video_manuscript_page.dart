import 'package:flutter/material.dart';
import 'dart:async';
import '../../models/upload_video.dart';
import '../../services/video_submit_api_service.dart';
import '../../widgets/cached_image_widget.dart';
import '../../theme/theme_extensions.dart';
import '../../utils/image_utils.dart';
import '../../utils/time_utils.dart';
import '../../utils/video_status_utils.dart';
import '../../widgets/loading_more_indicator.dart';
import 'video_upload_page.dart';
import 'video_subtitle_pages.dart';

class VideoManuscriptPage extends StatefulWidget {
  const VideoManuscriptPage({super.key});

  @override
  State<VideoManuscriptPage> createState() => _VideoManuscriptPageState();
}

/// 视频筛选分类
enum VideoFilter { all, published, transcoding, transcodeFailed, pendingReview, rejected }

class _VideoManuscriptPageState extends State<VideoManuscriptPage> {
  final ScrollController _scrollController = ScrollController();
  final Set<String> _expandedResourceGroups = <String>{};
  Timer? _silentRefreshTimer;

  List<ManuscriptVideo> _videos = [];
  int _currentPage = 1;
  bool _isLoading = false;
  bool _hasMore = true;
  String? _errorMessage;
  static const int _pageSize = 20;
  VideoFilter _currentFilter = VideoFilter.all;

  /// 当前 Tab 对应的服务端 category 参数
  static String _categoryFromFilter(VideoFilter f) {
    switch (f) {
      case VideoFilter.all:
        return 'all';
      case VideoFilter.published:
        return 'published';
      case VideoFilter.transcoding:
        return 'transcoding';
      case VideoFilter.transcodeFailed:
        return 'transcode_failed';
      case VideoFilter.pendingReview:
        return 'pending';
      case VideoFilter.rejected:
        return 'rejected';
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadVideos();
  }

  @override
  void dispose() {
    _stopSilentRefresh();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent * 0.8 &&
        !_isLoading &&
        _hasMore) {
      _loadMoreVideos();
    }
  }

  Future<void> _loadVideos({bool forceReload = false}) async {
    if (!forceReload && _isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _currentPage = 1;
      if (forceReload) {
        _videos = [];
        _hasMore = true;
      }
    });

    final category = _categoryFromFilter(_currentFilter);

    try {
      final videos = await VideoSubmitApiService.getManuscriptVideos(
        page: 1,
        pageSize: _pageSize,
        category: category,
      );

      if (mounted) {
        setState(() {
          _videos = videos;
          _hasMore = videos.length >= _pageSize;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _silentRefreshTranscodingVideos() async {
    if (!mounted || _isLoading || _currentFilter != VideoFilter.transcoding) {
      return;
    }

    final category = _categoryFromFilter(_currentFilter);
    final targetPage = _currentPage < 1 ? 1 : _currentPage;

    try {
      final refreshed = <ManuscriptVideo>[];
      var hasMore = false;

      for (int page = 1; page <= targetPage; page++) {
        final pageData = await VideoSubmitApiService.getManuscriptVideos(
          page: page,
          pageSize: _pageSize,
          category: category,
        );
        refreshed.addAll(pageData);
        hasMore = pageData.length >= _pageSize;
        if (pageData.isEmpty) {
          break;
        }
      }

      if (!mounted) return;
      if (!_shouldApplySilentRefresh(refreshed)) {
        return;
      }
      setState(() {
        _videos = refreshed;
        _hasMore = hasMore;
        if (refreshed.length < (_currentPage - 1) * _pageSize) {
          _currentPage = (refreshed.length / _pageSize).ceil().clamp(1, targetPage);
        }
      });
    } catch (_) {
      // 静默刷新失败不影响当前 UI
    }
  }

  bool _shouldApplySilentRefresh(List<ManuscriptVideo> refreshed) {
    if (refreshed.length != _videos.length) {
      return true;
    }

    for (int i = 0; i < refreshed.length; i++) {
      final oldVideo = _videos[i];
      final newVideo = refreshed[i];

      if (oldVideo.vid != newVideo.vid) {
        return true;
      }

      // 仅在进度值有实际变化时触发重绘（避免无效 setState）
      if ((oldVideo.transcodingProgress - newVideo.transcodingProgress).abs() > 0.01) {
        return true;
      }

      final oldDetails = oldVideo.transcodingDetails;
      final newDetails = newVideo.transcodingDetails;
      if (oldDetails.length != newDetails.length) {
        return true;
      }

      for (int j = 0; j < oldDetails.length; j++) {
        final oldItem = oldDetails[j];
        final newItem = newDetails[j];
        if (oldItem.resourceId != newItem.resourceId ||
            oldItem.quality != newItem.quality ||
            oldItem.status != newItem.status ||
            (oldItem.progress - newItem.progress).abs() > 0.01) {
          return true;
        }
      }
    }

    return false;
  }

  Future<void> _loadMoreVideos() async {
    if (_isLoading || !_hasMore) return;

    setState(() {
      _isLoading = true;
    });

    final nextPage = _currentPage + 1;
    final category = _categoryFromFilter(_currentFilter);

    try {
      final newVideos = await VideoSubmitApiService.getManuscriptVideos(
        page: nextPage,
        pageSize: _pageSize,
        category: category,
      );

      if (mounted) {
        setState(() {
          _videos.addAll(newVideos);
          _currentPage = nextPage;
          _hasMore = newVideos.length >= _pageSize;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasMore = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载更多失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteVideo(ManuscriptVideo video) async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.card,
        title: Text('确认删除', style: TextStyle(color: colors.textPrimary)),
        content: Text(
          '确定要删除视频"${video.title}"吗?',
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await VideoSubmitApiService.deleteVideo(video.vid);

      if (mounted) {
        setState(() {
          _videos.removeWhere((v) => v.vid == video.vid);
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  Future<void> _editVideo(ManuscriptVideo video) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoUploadPage(vid: video.vid),
      ),
    );

    if (result == true) {
      _loadVideos(forceReload: true); // 刷新列表
    }
  }

  void _onFilterChanged(VideoFilter filter) {
    if (_currentFilter == filter) return;
    setState(() {
      _currentFilter = filter;
    });
    if (filter == VideoFilter.transcoding) {
      _startSilentRefresh();
    } else {
      _stopSilentRefresh();
    }
    _loadVideos(forceReload: true);
  }

  void _startSilentRefresh() {
    _silentRefreshTimer?.cancel();
    _silentRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _silentRefreshTranscodingVideos();
    });
  }

  void _stopSilentRefresh() {
    _silentRefreshTimer?.cancel();
    _silentRefreshTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('视频管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const VideoUploadPage(),
                ),
              );
              if (result == true) {
                _loadVideos(); // 刷新列表
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildFilterBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    final colors = context.colors;
    const filters = [
      (VideoFilter.all, '全部'),
      (VideoFilter.published, '已发布'),
      (VideoFilter.transcoding, '转码中'),
      (VideoFilter.transcodeFailed, '转码失败'),
      (VideoFilter.pendingReview, '待审核'),
      (VideoFilter.rejected, '不通过'),
    ];

    return Container(
      height: 44,
      color: colors.card,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          final (filter, label) = filters[index];
          final isSelected = _currentFilter == filter;
          return Center(
            child: GestureDetector(
              onTap: () => _onFilterChanged(filter),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected ? colors.accentColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: isSelected ? Colors.white : colors.textSecondary,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    final colors = context.colors;
    // 显示错误信息
    if (_errorMessage != null && _videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: colors.iconSecondary),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: colors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadVideos,
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.accentColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 初始加载中
    if (_videos.isEmpty && _isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    // 空状态（无任何稿件）
    if (_videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.video_library_outlined, size: 80, color: colors.iconSecondary),
            const SizedBox(height: 16),
            Text(
              '还没有投稿视频',
              style: TextStyle(fontSize: 16, color: colors.textSecondary),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const VideoUploadPage(),
                  ),
                );
                if (result == true) {
                  _loadVideos();
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('投稿视频'),
            ),
          ],
        ),
      );
    }

    // 筛选后无结果
    if (_videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.filter_list_off, size: 64, color: colors.iconSecondary),
            const SizedBox(height: 16),
            Text(
              '该分类下暂无视频',
              style: TextStyle(fontSize: 16, color: colors.textSecondary),
            ),
          ],
        ),
      );
    }

    // 视频列表
    return RefreshIndicator(
      onRefresh: _loadVideos,
      child: ListView.builder(
        controller: _scrollController,
        itemCount: _videos.length + (_hasMore || _isLoading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _videos.length) {
            return const LoadingMoreIndicator();
          }

          final video = _videos[index];
          return _buildVideoItem(video);
        },
      ),
    );
  }

  Widget _buildVideoItem(ManuscriptVideo video) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: () => _editVideo(video),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面：统一用完整 URL + 全局缓存（同图只缓存一份）
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 120,
                  height: 68,
                  child: video.cover.isNotEmpty
                      ? CachedImage(
                          imageUrl: ImageUtils.getFullImageUrl(video.cover),
                          width: 120,
                          height: 68,
                          fit: BoxFit.cover,
                        )
                      : Container(
                          color: Colors.grey[300],
                          child: const Icon(Icons.video_library_outlined, color: Colors.grey),
                        ),
                ),
              ),
              const SizedBox(width: 12),

              // 信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      video.getStatusText(),
                      style: TextStyle(
                        fontSize: 13,
                        color: VideoStatusUtils.getStatusColor(video.status),
                      ),
                    ),
                    if (video.status == 100 || video.status == 200 || video.status == 300)
                      _buildTranscodingProgressSection(video),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.visibility, size: 14, color: Colors.grey[600]),
                        const SizedBox(width: 4),
                        Text(
                          '${video.clicks}',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            TimeUtils.formatTime(video.createdAt),
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // 操作按钮
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') {
                    _editVideo(video);
                  } else if (value == 'subtitle') {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) =>
                            VideoSubtitleHubPage(vid: video.vid),
                      ),
                    );
                  } else if (value == 'delete') {
                    _deleteVideo(video);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.edit, size: 20),
                        SizedBox(width: 8),
                        Text('编辑'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'subtitle',
                    child: Row(
                      children: [
                        Icon(Icons.subtitles_outlined, size: 20),
                        SizedBox(width: 8),
                        Text('字幕'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, size: 20, color: Colors.red),
                        SizedBox(width: 8),
                        Text('删除', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTranscodingProgressSection(ManuscriptVideo video) {
    final colors = context.colors;
    final details = video.transcodingDetails;
    final progressText = '${video.transcodingProgress.toStringAsFixed(1)}%';

    // 按 resourceId 分组
    final Map<int, List<TranscodingProgressItem>> groups = {};
    for (final d in details) {
      groups.putIfAbsent(d.resourceId, () => []);
      groups[d.resourceId]!.add(d);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 总体进度行
          Row(
            children: [
              Icon(Icons.sync, size: 14, color: colors.warning),
              const SizedBox(width: 4),
              Text('转码进度 $progressText',
                  style: TextStyle(fontSize: 12, color: colors.warning)),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: (video.transcodingProgress.clamp(0, 100)) / 100,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
            backgroundColor: colors.progressBackground,
            valueColor: AlwaysStoppedAnimation<Color>(colors.warning),
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...groups.entries.map((entry) =>
                _buildResourceGroup(video.vid, entry.key, entry.value, colors)),
          ]
        ],
      ),
    );
  }

  Widget _buildResourceGroup(String videoVid, int resourceId,
      List<TranscodingProgressItem> items, dynamic colors) {
    final key = '$videoVid-$resourceId';
    final isExpanded = _expandedResourceGroups.contains(key);
    final n = items.length;
    final totalPct = items.fold(0.0, (s, i) => s + i.progress);
    final avgPct = n > 0 ? (totalPct / n).round() : 0;
    final anyFail = items.any((i) => i.status == 'fail');
    final allWaiting = items.every((i) => i.status == 'waiting');
    final allDone = !allWaiting && !anyFail && items.every((i) => i.status == 'success');
    final upload = items.map((i) => i.upload).firstWhere((u) => u != null, orElse: () => null);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: colors.divider),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 分组头部
            InkWell(
              onTap: () {
                setState(() {
                  if (isExpanded) {
                    _expandedResourceGroups.remove(key);
                  } else {
                    _expandedResourceGroups.add(key);
                  }
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(5),
                    topRight: const Radius.circular(5),
                    bottomRight: isExpanded ? Radius.zero : const Radius.circular(5),
                    bottomLeft: isExpanded ? Radius.zero : const Radius.circular(5),
                  ),
                ),
                child: Row(
                  children: [
                    // 箭头
                    AnimatedRotation(
                      turns: isExpanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(Icons.play_arrow, size: 14, color: colors.textSecondary),
                    ),
                    const SizedBox(width: 6),
                    // 标题
                    Flexible(
                      child: Text(
                        items.first.resourceTitle.isNotEmpty
                            ? items.first.resourceTitle
                            : '分P$resourceId',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: colors.textPrimary),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('$n 个画质', style: TextStyle(fontSize: 11, color: colors.textSecondary)),
                    const Spacer(),
                    // 状态标签
                    if (allWaiting)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: colors.textSecondary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text('排队中', style: TextStyle(fontSize: 10, color: colors.textSecondary)),
                      )
                    else if (anyFail)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: colors.error.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text('失败', style: TextStyle(fontSize: 10, color: colors.error)),
                      )
                    else if (allDone)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: colors.success.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text('完成', style: TextStyle(fontSize: 10, color: colors.success)),
                      ),
                    const SizedBox(width: 8),
                    // 汇总进度条
                    SizedBox(
                      width: 140,
                      child: LinearProgressIndicator(
                        value: allWaiting ? 0 : avgPct / 100,
                        minHeight: 14,
                        borderRadius: BorderRadius.circular(7),
                        backgroundColor: colors.progressBackground,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          anyFail ? colors.error : (allDone ? colors.success : colors.warning),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      allWaiting ? '0%' : '$avgPct%',
                      style: TextStyle(fontSize: 10, color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
            // 展开详情
            if (isExpanded) ...[
              Container(
                padding: const EdgeInsets.fromLTRB(22, 6, 12, 4),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.divider)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...items.map((item) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.quality, style: TextStyle(fontSize: 11, color: colors.textSecondary)),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Expanded(
                                child: LinearProgressIndicator(
                                  value: (item.progress.clamp(0, 100)) / 100,
                                  minHeight: 10,
                                  borderRadius: BorderRadius.circular(5),
                                  backgroundColor: colors.progressBackground,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    item.status == 'fail' ? colors.error :
                                    item.status == 'success' ? colors.success :
                                    colors.warning,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${item.progress.toStringAsFixed(0)}%',
                                style: TextStyle(fontSize: 10, color: colors.textSecondary),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )),
                    // 上传进度
                    if (upload != null && upload.status != 'local')
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(height: 1, color: colors.divider),
                            const SizedBox(height: 6),
                            Text('OSS 上传', style: TextStyle(fontSize: 11, color: colors.textSecondary)),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value: (upload.progress.clamp(0, 100)) / 100,
                                    minHeight: 10,
                                    borderRadius: BorderRadius.circular(5),
                                    backgroundColor: colors.progressBackground,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      upload.status == 'fail' ? colors.error :
                                      upload.status == 'success' ? colors.success :
                                      colors.warning,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${upload.progress.toStringAsFixed(0)}%',
                                  style: TextStyle(fontSize: 10, color: colors.textSecondary),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

}
