public import Foundation
import MacVMModel

/// 一次在宿主与客户机之间复制文件的进度，开始与结束时在主线程发 `began`、`ended` 通知（对象是本实例），供窗口显示。
public final class GuestTransferActivity: NSObject, @unchecked Sendable {
    public static let began = Notification.Name("MacVMGuestTransferBegan")
    public static let ended = Notification.Name("MacVMGuestTransferEnded")

    public let vmName: String
    public let title: String
    /// 单位是字节；取消它即中止复制。
    public let progress: Progress
    /// 失败的原因；成功或被取消时为 nil。只在主线程上读写。
    public private(set) var failure: String?

    public init(vmName: String, title: String) {
        self.vmName = vmName
        self.title = title
        progress = Progress(totalUnitCount: 0)
        progress.kind = .file
        progress.fileOperationKind = .copying
        progress.localizedDescription = title
    }

    /// 发出 `began`，在后台线程执行 `body`，结束后发出 `ended`。
    @MainActor
    public func run(_ body: @escaping @Sendable (Progress) throws -> Void) {
        NotificationCenter.default.post(name: Self.began, object: self)
        let progress = progress
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            do {
                try body(progress)
            } catch {
                // 取消后中途的读写错误也算取消。
                message = progress.isCancelled ? nil : Self.message(for: error)
            }
            DispatchQueue.main.async { [message] in
                self.failure = message
                NotificationCenter.default.post(name: Self.ended, object: self)
            }
        }
    }

    /// 给人看的失败原因；取消不算失败。
    public static func message(for error: any Error) -> String? {
        switch error {
        case is CancellationError: nil
        case let tooLarge as GuestFileTransfer.TooLarge:
            String(l10n: "The file is too large to copy (\(ByteCountFormatter.string(fromByteCount: tooLarge.total, countStyle: .file)))")
        case let error as MacVMError: error.message
        default: error.localizedDescription
        }
    }
}
