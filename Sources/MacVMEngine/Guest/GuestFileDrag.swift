import AppKit
import MacVMModel
import UniformTypeIdentifiers

/// 画面视图与客户机之间的文件拖放，由画面视图转来拖放与鼠标事件。
/// 拖入：宿主的文件放到画面上，经代理复制到投放点下的文件夹（`AgentProtocol.PutTarget.drop`）。
/// 拖出：在客户机里按住文件拖出画面时，问代理正在拖的是哪些文件（`drag-files`），换成宿主上的拖动；
/// 放下时才从客户机复制（文件承诺），客户机里原来的拖动由视图按 Esc 取消。
@MainActor
final class GuestFileDrag: NSObject {
    nonisolated private let bundle: VMBundle
    private let os: GuestOS
    private let hasAgent: Bool

    /// 本次按下鼠标期间拖出的状态。
    private enum Press {
        case idle
        case querying
        case found([AgentProtocol.GuestFile])
        /// 这次按下不是在拖文件，或已经交给宿主，松开之前不再问。
        case done
    }
    private var press = Press.done
    /// 每次按下加一，丢弃上一次按下迟到的查询结果。
    private var generation = 0
    /// 按下时拖放剪贴板的变更计数（macOS 客户机）。
    private var baseline: Task<Int64?, Never>?
    /// 代理不认 `drag-files` 后不再问。
    private var dragUnsupported = false

    init(bundle: VMBundle, os: GuestOS, hasAgent: Bool) {
        self.bundle = bundle
        self.os = os
        self.hasAgent = hasAgent
    }

    // MARK: - 拖入

    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    func draggingOperation(_ info: any NSDraggingInfo) -> NSDragOperation {
        hasAgent && !Self.fileURLs(info.draggingPasteboard).isEmpty ? .copy : []
    }

    /// `fraction` 是投放点在客户机画面里的位置（宽、高的比例），不在画面上时为 nil。
    func performDrop(_ info: any NSDraggingInfo, at fraction: CGPoint?) -> Bool {
        let urls = Self.fileURLs(info.draggingPasteboard)
        guard hasAgent, !urls.isEmpty else { return false }
        let target: AgentProtocol.PutTarget = fraction.map { .drop(x: $0.x, y: $0.y) } ?? .desktop
        let title = urls.count == 1 ? "正在把「\(urls[0].lastPathComponent)」复制到虚拟机…" : "正在把 \(urls.count) 个项目复制到虚拟机…"
        let bundle = bundle
        GuestTransferActivity(vmName: bundle.name, title: title).run { progress in
            try GuestFileTransfer.requireSupport(bundle)
            try GuestFileTransfer.send(urls, to: target, bundle: bundle, progress: progress)
        }
        return true
    }

    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: - 拖出

    private var dragOutEnabled: Bool { hasAgent && os != .linux && !dragUnsupported }

    func mouseDown() {
        generation += 1
        press = .idle
        baseline = nil
        guard dragOutEnabled, os == .macOS else { return }
        let bundle = bundle
        baseline = Task.detached { try? AgentClient.call(.dragFiles, bundle: bundle, timeout: 2).serial }
    }

    func mouseUp() {
        press = .done
        baseline = nil
    }

    /// 按着鼠标拖动时调用；返回要在宿主上开始拖动的项，nil 时照常把事件交给客户机。
    /// 第一次拖出画面时问代理，结果回来后的下一次拖动才开始宿主上的拖动。
    func mouseDragged(outside: Bool, at location: NSPoint) -> [NSDraggingItem]? {
        guard dragOutEnabled, outside else { return nil }
        switch press {
        case .idle:
            press = .querying
            let (bundle, generation, baseline) = (bundle, generation, baseline)
            Task {
                let before = await baseline?.value
                let response = await Task.detached { try? AgentClient.open(.dragFiles, bundle: bundle, timeout: 3).0 }.value
                guard generation == self.generation, case .querying = self.press else { return }
                guard let response, response.ok else {
                    if response?.ok == false { self.dragUnsupported = true }
                    self.press = .done
                    return
                }
                let files = response.files ?? []
                // 有 serial 时拖放剪贴板里留着上一次拖动的内容，按下以来变过才算这次在拖。
                let dragging = !files.isEmpty && (response.serial == nil || (before != nil && response.serial != before))
                self.press = dragging ? .found(files) : .done
            }
            return nil
        case .found(let files):
            press = .done
            return files.enumerated().map { index, file in item(file, at: location, offset: CGFloat(index)) }
        case .querying, .done:
            return nil
        }
    }

    private func item(_ file: AgentProtocol.GuestFile, at location: NSPoint, offset: CGFloat) -> NSDraggingItem {
        let type: UTType = file.dir ? .folder : (UTType(filenameExtension: (Self.name(of: file.path) as NSString).pathExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = file
        let item = NSDraggingItem(pasteboardWriter: provider)
        let size = CGFloat(64)
        let frame = NSRect(x: location.x - size / 2 + offset * 8, y: location.y - size / 2 - offset * 8, width: size, height: size)
        item.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(for: type))
        return item
    }

    /// 客户机路径的最后一段；Windows 路径以 `\` 分隔。
    nonisolated static func name(of path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    nonisolated private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()
}

extension GuestFileDrag: NSDraggingSource {
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

extension GuestFileDrag: NSFilePromiseProviderDelegate {
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? AgentProtocol.GuestFile).map { Self.name(of: $0.path) } ?? "untitled"
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { Self.promiseQueue }

    /// 在承诺队列上同步复制完才回调：访达等到回调才认为文件已就位。
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let file = provider.userInfo as? AgentProtocol.GuestFile else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        let bundle = bundle
        let activity = GuestTransferActivity(vmName: bundle.name, title: "正在从虚拟机复制「\(Self.name(of: file.path))」…")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: (any Error)?
        DispatchQueue.main.async {
            activity.run { progress in
                defer { done.signal() }
                do {
                    try GuestFileTransfer.receive([file.path], into: url.deletingLastPathComponent(), bundle: bundle, progress: progress)
                } catch {
                    failure = error
                    throw error
                }
            }
        }
        done.wait()
        completionHandler(failure)
    }
}
