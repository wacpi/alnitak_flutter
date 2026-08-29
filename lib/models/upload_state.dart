/// 上传状态模型
///
/// 定义视频上传的显式状态机。流程代码仍保留在 `UploadApiService` 内，
/// 此处仅将原本隐式的阶段与进度显式化，供页面统一驱动 UI。
library;

/// 上传阶段
enum UploadStage {
  /// 计算文件 MD5
  hashing,

  /// 查询已上传分片 / 秒传判定
  checking,

  /// 后台探测视频元数据与封面
  probing,

  /// 直传 OSS 分片
  directUpload,

  /// 回退 VPS 代理分片上传
  chunkUpload,

  /// 合并分片（VPS 路径）
  merging,

  /// 通知后端建资源
  completing,

  /// 上传成功
  done,

  /// 上传失败
  failed,

  /// 用户取消
  cancelled,
}

/// 上传状态快照
///
/// [progress] 约定为 0~1 的**单调不减**值，由服务端内部保证不回跳，
/// 页面无需自行 clamp。仅 [UploadStage.failed] / [cancelled] 时
/// [progress] 可能是最近一次的有效值（不表示成功）。
class UploadState {
  const UploadState({
    required this.stage,
    required this.progress,
    this.message,
  });

  final UploadStage stage;

  /// 0~1 单调不减的进度
  final double progress;

  /// 人类可读的阶段描述，如 "直传OSS 12/87"、"计算MD5..."
  final String? message;

  bool get isFinished =>
      stage == UploadStage.done ||
      stage == UploadStage.failed ||
      stage == UploadStage.cancelled;
}