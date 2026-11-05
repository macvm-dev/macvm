import AppKit
import MacVMEngine
import MacVMModel

/// 跟着虚拟机窗口的焦点经客户机代理同步文本剪贴板：窗口成为主窗口时把宿主剪贴板推给客户机，失去主窗口时把客户机剪贴板取回宿主。
/// 只在焦点切换时同步，不轮询。
@MainActor
final class ClipboardSync {
    private let bundle: VMBundle
    /// 代理调用串行执行，结果按发出的顺序回到主线程：推与取的先后要与焦点切换的先后一致。
    private let queue = DispatchQueue(label: "macvm.clipboard")
    /// 上次成功推给或取自客户机的文本，即当时客户机剪贴板的内容；还没成功过时为 nil。
    /// 取回时客户机的文本与它相同说明客户机里没复制过东西，不写宿主剪贴板：推送失败时宿主上新复制的内容不会被客户机的旧内容盖掉。
    private var guestText: String?
    /// 上次读或写宿主剪贴板时它的 `changeCount`；宿主剪贴板没变时不再推送。
    private var hostChangeCount: Int?

    init(bundle: VMBundle) { self.bundle = bundle }

    /// 设了 `MACVM_CLIPBOARD_DEBUG` 时把每次同步写到标准错误。
    nonisolated private static let debug = ProcessInfo.processInfo.environment["MACVM_CLIPBOARD_DEBUG"] != nil

    nonisolated private static func log(_ name: String, _ message: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("[clipboard] \(Date().timeIntervalSince1970) \(name) \(message())\n".utf8))
    }

    /// 窗口成为主窗口时调用。宿主剪贴板没变时只记下客户机当前的内容，作为离开时比较的基准。
    func push() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let bundle = bundle
        if changeCount != hostChangeCount, let text = pasteboard.string(forType: .string), text != guestText {
            Self.log(bundle.name, "push \(text.prefix(40))")
            queue.async {
                let start = Date()
                let result = Result { try GuestClipboard.setText(bundle, text) }
                Self.log(bundle.name, "push done in \(Date().timeIntervalSince(start))s: \(result)")
                let ok = (try? result.get()) != nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard ok else { return }
                        self.guestText = text
                        self.hostChangeCount = changeCount
                    }
                }
            }
        } else {
            hostChangeCount = changeCount
            guard guestText == nil else { Self.log(bundle.name, "push skipped"); return }
            queue.async {
                let text = try? GuestClipboard.text(bundle)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if self.guestText == nil { self.guestText = text }
                    }
                }
            }
        }
    }

    /// 窗口失去主窗口时调用。
    func pull() {
        let bundle = bundle
        Self.log(bundle.name, "pull")
        queue.async {
            let start = Date()
            let result = Result { try GuestClipboard.text(bundle) }
            Self.log(bundle.name, "pull done in \(Date().timeIntervalSince(start))s: \(result)")
            guard let text = try? result.get() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 没有基准时分不出客户机里有没有复制过，这次只记下基准。
                    guard let known = self.guestText else { self.guestText = text; return }
                    self.guestText = text
                    guard text != known, !text.isEmpty else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    self.hostChangeCount = pasteboard.changeCount
                }
            }
        }
    }
}
