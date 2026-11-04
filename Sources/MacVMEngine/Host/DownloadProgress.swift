import Foundation

/// 下载进度的接收方。在 `handler` 绑定的任务里发生的下载（镜像、安装盘、IPSW、驱动盘）都会定期回报，
/// 不用沿着各个安装流程逐层传参。
public enum DownloadProgress {
    /// `received` 为已写到磁盘的字节数，`total` 取不到时为 nil。在任意线程调用。
    public typealias Handler = @Sendable (_ received: Int64, _ total: Int64?) -> Void

    @TaskLocal public static var handler: Handler?
}
