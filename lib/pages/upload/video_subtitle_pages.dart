import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../models/upload_video.dart';
import '../../models/subtitle_track_item.dart';
import '../../services/subtitle_api_service.dart';
import '../../services/video_submit_api_service.dart';
import '../../theme/theme_extensions.dart';

class DialogSubtitleResult {
  final String lang;
  final String label;
  final bool isDefault;

  DialogSubtitleResult({
    required this.lang,
    required this.label,
    required this.isDefault,
  });
}

/// 选分 P → 编辑该分 P 外挂字幕。
///
/// [resourceKey]：`shortId`，缺省时回退数字 `id`，与字幕 API `resourceShortId` 对齐。
class VideoPartSubtitlePage extends StatefulWidget {
  final String resourceKey;
  final String partTitle;

  const VideoPartSubtitlePage({
    super.key,
    required this.resourceKey,
    required this.partTitle,
  });

  @override
  State<VideoPartSubtitlePage> createState() => _VideoPartSubtitlePageState();
}

class _VideoPartSubtitlePageState extends State<VideoPartSubtitlePage> {
  List<SubtitleTrackItem> _tracks = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final list =
          await SubtitleApiService.fetchTracks(widget.resourceKey);
      if (mounted) setState(() => _tracks = list);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndUpload() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['vtt', 'srt'],
    );
    if (!mounted) return;
    if (r == null || r.files.isEmpty) return;
    final path = r.files.single.path;
    if (path == null) return;
    final file = File(path);
    final langCtl = TextEditingController(text: 'zh-Hans');
    final labelCtl = TextEditingController(text: '中文');

    bool draftDefault = _tracks.isEmpty;
    DialogSubtitleResult? result;
    try {
      result = await showDialog<DialogSubtitleResult>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('上传字幕'),
            content: StatefulBuilder(
              builder: (ctx, setSt) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: langCtl,
                    decoration: const InputDecoration(
                      labelText: '语言码 lang',
                      hintText: '如 zh-Hans、ja',
                    ),
                  ),
                  TextField(
                    controller: labelCtl,
                    decoration: const InputDecoration(
                      labelText: '显示名 label（可选）',
                    ),
                  ),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('设为默认轨道'),
                    value: draftDefault,
                    onChanged: (v) => setSt(() => draftDefault = v ?? false),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(
                    ctx,
                    DialogSubtitleResult(
                      lang: langCtl.text.trim(),
                      label: labelCtl.text.trim(),
                      isDefault: draftDefault,
                    ),
                  );
                },
                child: const Text('上传'),
              ),
            ],
          );
        },
      );
    } finally {
      langCtl.dispose();
      labelCtl.dispose();
    }

    if (result == null || !mounted) return;

    final lang = result.lang;
    if (lang.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写 lang')),
      );
      return;
    }

    try {
      setState(() => _busy = true);
      await SubtitleApiService.upload(
        resourceShortId: widget.resourceKey,
        lang: lang,
        label: result.label,
        isDefault: result.isDefault,
        file: file,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('上传成功')),
        );
      }
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete(int id) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除字幕'),
        content: const Text('确定删除该字幕文件？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (sure != true) return;
    try {
      setState(() => _busy = true);
      await SubtitleApiService.deleteTrack(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除')));
      }
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      appBar: AppBar(
        title: Text('字幕 · ${widget.partTitle}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _busy ? null : _pickAndUpload,
        child: const Icon(Icons.add),
      ),
      body: Stack(
        children: [
          if (_error != null && !_busy)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          else if (_tracks.isEmpty && !_busy)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.subtitles_off_outlined, size: 56, color: colors.iconSecondary),
                  const SizedBox(height: 12),
                  Text('暂无字幕，点击右下角添加', style: TextStyle(color: colors.textSecondary)),
                ],
              ),
            )
          else
            RefreshIndicator(
              onRefresh: _reload,
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _tracks.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final t = _tracks[i];
                  return ListTile(
                    title: Text(t.displayLabel),
                    subtitle: Text(
                      '${t.lang}${t.isDefault ? ' · 默认' : ''} · id:${t.id}\n文件：${p.basename(Uri.tryParse(t.url)?.path ?? t.url)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                      onPressed: () => _confirmDelete(t.id),
                    ),
                  );
                },
              ),
            ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

/// 根据 [vid] 拉取稿件分 P，再进入某一 P 的字幕编辑。
///
/// **顺序**：`getVideoStatus` → 选分 P → [VideoPartSubtitlePage]。
class VideoSubtitleHubPage extends StatefulWidget {
  final String vid;

  const VideoSubtitleHubPage({super.key, required this.vid});

  @override
  State<VideoSubtitleHubPage> createState() => _VideoSubtitleHubPageState();
}

class _VideoSubtitleHubPageState extends State<VideoSubtitleHubPage> {
  VideoStatus? _status;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await VideoSubmitApiService.getVideoStatus(widget.vid);
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _resourceKey(VideoResource r) {
    final s = r.shortId?.trim();
    if (s != null && s.isNotEmpty) return s;
    return r.id;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('字幕管理')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!, textAlign: TextAlign.center),
                ))
              : _status == null || _status!.resources.isEmpty
                  ? Center(
                      child: Text('没有分 P 数据',
                          style: TextStyle(color: colors.textSecondary)))
                  : ListView.builder(
                      itemCount: _status!.resources.length,
                      itemBuilder: (ctx, index) {
                        final r = _status!.resources[index];
                        final key = _resourceKey(r);
                        return ListTile(
                          leading: const Icon(Icons.video_file_outlined),
                          title: Text(r.title.isEmpty ? '分P ${index + 1}' : r.title),
                          subtitle: Text('resource: $key',
                              style: TextStyle(fontSize: 11, color: colors.textSecondary)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => VideoPartSubtitlePage(
                                  resourceKey: key,
                                  partTitle:
                                      r.title.isEmpty ? '分P ${index + 1}' : r.title,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
    );
  }
}
