import AppKit
import MacVMEngine
import MacVMModel

/// 跟着虚拟机窗口的焦点经客户机代理同步剪贴板：窗口成为主窗口时把宿主剪贴板推给客户机，失去主窗口时把客户机剪贴板取回宿主。
/// 只在焦点切换时同步，不轮询。剪贴板里有文件时复制文件本身（不超过 `GuestClipboard.maxFiles`），进度经 `GuestTransferActivity` 显示在窗口里。
@MainActor
final class ClipboardSync {
    private let bundle: VMBundle
    /// 代理调用串行执行，结果按发出的顺序回到主线程：推与取的先后要与焦点切换的先后一致。
    private let queue = DispatchQueue(label: "macvm.clipboard")
    /// 上次成功推给或取自客户机后客户机剪贴板的内容；还没成功过时为 nil。
    /// 取回时客户机的内容与它相同说明客户机里没复制过东西，不写宿主剪贴板：推送失败时宿主上新复制的内容不会被客户机的旧内容盖掉。
    private var guest: GuestClipboard.Contents?
    /// 上次读或写宿主剪贴板时它的 `changeCount`；宿主剪贴板没变时不再推送。
    private var hostChangeCount: Int?
    /// 进行中的文件复制；焦点再切换时取消，免得旧的复制完成后盖掉新的剪贴板。
    private var transfer: GuestTransferActivity?

    init(bundle: VMBundle) { self.bundle = bundle }

    /// 设了 `MACVM_CLIPBOARD_DEBUG` 时把每次同步写到标准错误。
    nonisolated private static let debug = ProcessInfo.processInfo.environment["MACVM_CLIPBOARD_DEBUG"] != nil

    nonisolated private static func log(_ name: String, _ message: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("[clipboard] \(Date().timeIntervalSince1970) \(name) \(message())\n".utf8))
    }

    /// 窗口成为主窗口时调用。宿主剪贴板没变时只记下客户机当前的内容，作为离开时比较的基准。
    func push() {
        transfer?.progress.cancel()
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let bundle = bundle
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if changeCount != hostChangeCount, !urls.isEmpty {
            pushFiles(urls, changeCount: changeCount)
        } else if changeCount != hostChangeCount, let text = pasteboard.string(forType: .string), text != guest?.text || guest?.files.isEmpty == false {
            Self.log(bundle.name, "push \(text.prefix(40))")
            queue.async {
                let start = Date()
                let result = Result { try GuestClipboard.setText(bundle, text) }
                Self.log(bundle.name, "push done in \(Date().timeIntervalSince(start))s: \(result)")
                let ok = (try? result.get()) != nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard ok else { return }
                        self.guest = GuestClipboard.Contents(text: text)
                        self.hostChangeCount = changeCount
                    }
                }
            }
        } else {
            hostChangeCount = changeCount
            guard guest == nil else { Self.log(bundle.name, "push skipped"); return }
            queue.async {
                let contents = try? GuestClipboard.contents(bundle)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if self.guest == nil { self.guest = contents }
                    }
                }
            }
        }
    }

    /// 文件在复制完之前客户机里粘贴不到；超过上限的不复制，提示改用拖放。
    private func pushFiles(_ urls: [URL], changeCount: Int) {
        let bundle = bundle
        Self.log(bundle.name, "push files \(urls.map(\.lastPathComponent))")
        let activity = GuestTransferActivity(vmName: bundle.name, title: String(l10n: "Copying clipboard files to the virtual machine…"))
        transfer = activity
        activity.run { progress in
            let total = GuestFileTransfer.totalSize(urls)
            guard total <= GuestClipboard.maxFiles else {
                Self.markPushed(self, changeCount, contents: nil)
                throw MacVMError.unsupported(String(l10n: "The copied files (\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))) are too large to paste into the virtual machine. Drag them into its window instead"))
            }
            do {
                try GuestClipboard.setFiles(bundle, urls, progress: progress)
            } catch {
                // 失败（如代理过旧）后宿主剪贴板没变就不再重试，免得每次切回窗口都报一遍；取消的下次切回再推。
                if !progress.isCancelled { Self.markPushed(self, changeCount, contents: nil) }
                throw error
            }
            Self.markPushed(self, changeCount, contents: try? GuestClipboard.contents(bundle))
        }
    }

    nonisolated private static func markPushed(_ sync: ClipboardSync, _ changeCount: Int, contents: GuestClipboard.Contents?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                sync.hostChangeCount = changeCount
                if let contents { sync.guest = contents }
            }
        }
    }

    /// 窗口失去主窗口时调用。
    func pull() {
        let bundle = bundle
        Self.log(bundle.name, "pull")
        queue.async {
            let start = Date()
            let result = Result { try GuestClipboard.contents(bundle) }
            Self.log(bundle.name, "pull done in \(Date().timeIntervalSince(start))s: \(result)")
            guard let contents = try? result.get() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(contents) }
            }
        }
    }

    private func apply(_ contents: GuestClipboard.Contents) {
        // 没有基准时分不出客户机里有没有复制过，这次只记下基准。
        guard let known = guest else { guest = contents; return }
        guest = contents
        if !contents.files.isEmpty {
            if contents.files != known.files { pullFiles(contents) }
            return
        }
        guard contents.text != known.text, !contents.text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contents.text, forType: .string)
        hostChangeCount = pasteboard.changeCount
    }

    /// 把客户机剪贴板里的文件复制进宿主的暂存目录，复制完把宿主剪贴板换成它们。暂存目录只留最近一次的。
    private func pullFiles(_ contents: GuestClipboard.Contents) {
        transfer?.progress.cancel()
        let bundle = bundle
        let paths = contents.files.map(\.path)
        let activity = GuestTransferActivity(vmName: bundle.name, title: String(l10n: "Copying clipboard files from the virtual machine…"))
        transfer = activity
        activity.run { progress in
            let staging = try Self.freshStaging(for: bundle.name)
            let urls = try GuestFileTransfer.receive(paths, into: staging, bundle: bundle, progress: progress, limit: GuestClipboard.maxFiles)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !progress.isCancelled else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects(urls as [NSURL])
                    self.hostChangeCount = pasteboard.changeCount
                }
            }
        }
    }

    /// 本虚拟机新的剪贴板暂存目录，先删掉以前的。
    nonisolated private static func freshStaging(for name: String) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let base = caches.appending(path: "MacVM/Clipboard/\(name)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: base)
        let dir = base.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
