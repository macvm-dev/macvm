import AppKit
import MacVMEngine

/// 关掉所有窗口后 App 不退出，留在菜单栏继续运行（本进程的虚拟机也不停）。
/// 菜单栏图标显示时，Dock 图标随窗口出现和消失；图标隐藏时 Dock 图标一直保留，否则没有入口能再打开窗口。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 放在这里而不是 `App` 的状态里：退出前要用它判断是否有虚拟机在运行或任务在进行。
    let model = AppModel()
    private var observers: [any NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard NSApp.activationPolicy() != .regular else { return }
                    NSApp.setActivationPolicy(.regular)
                    // 从菜单栏打开窗口时 App 还没有菜单栏和 Dock 图标，切换后要重新激活才会出现。
                    NSApp.activate()
                }
            },
            // 发通知时窗口还可见，等它真正关掉后再数。
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in Self.updateActivationPolicy() }
            },
        ]
        CLIInstaller.installIfNeeded()
        NetworkHelperRegistration.reconcile()
        // 直接运行可执行文件（不经 LaunchServices）启动时系统不会激活 App，窗口压在启动它的终端后面。
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        ChildProcesses.terminateAll()
    }

    /// 新建以外的任务（存模板、首次开机配置 SSH）中断后不会续做，退出前要确认；
    /// 本进程运行的虚拟机先正常关机，全部停下后才退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 关机途中再次退出时由进行中的那一轮答复，这一次不另起。
        guard !shuttingDown else { return .terminateCancel }
        let running = model.runners.keys.sorted()
        let creating = model.resumableCreations
        let other = model.creatingNames.filter { !creating.contains($0) }
        var notes: [String] = []
        if !creating.isEmpty {
            notes.append("\(creating.joined(separator: "、")) 还在创建，退出会中断创建，下次打开 MacVM 时自动继续，已下载的部分不用重下。")
        }
        if !other.isEmpty {
            notes.append("\(other.joined(separator: "、")) 有进行中的任务，退出会中断，不会自动继续。")
        }
        if !notes.isEmpty {
            if !running.isEmpty {
                notes.append("\(running.joined(separator: "、")) 会先关机再退出。")
            }
            let alert = NSAlert()
            alert.messageText = "要退出 MacVM 吗？"
            alert.informativeText = notes.joined(separator: "\n\n")
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "退出")
            NSApp.activate()
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        guard !running.isEmpty else { return .terminateNow }
        shuttingDown = true
        Task { await shutDownThenTerminate() }
        return .terminateLater
    }

    /// 客户机可能停在「是否保存」之类的对话框上迟迟不关机，每等满 `shutdownWait` 问一次是继续等、断电还是不退出了。
    private func shutDownThenTerminate() async {
        defer { shuttingDown = false }
        model.requestStopAll()
        while !(await model.waitUntilAllStopped(timeout: Self.shutdownWait)) {
            let alert = NSAlert()
            alert.messageText = "\(model.runners.keys.sorted().joined(separator: "、")) 还没关机"
            alert.informativeText = "客户机可能在等你保存文档或确认关机，可以到它的窗口里处理后继续等。断电退出会丢失客户机里没保存的内容。"
            alert.addButton(withTitle: "继续等待")
            alert.addButton(withTitle: "断电并退出")
            alert.addButton(withTitle: "不退出")
            NSApp.activate()
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                continue
            case .alertSecondButtonReturn:
                await model.forceStopAll()
            default:
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private var shuttingDown = false
    private static let shutdownWait: Duration = .seconds(60)

    private static func updateActivationPolicy() {
        let menuBarVisible = UserDefaults.standard.object(forKey: StatusMenu.visibleKey) as? Bool ?? true
        // 菜单栏图标与菜单本身的窗口不能成为主窗口，不算在内；最小化的窗口只在 Dock 里，得留着 Dock 图标。
        let hasWindow = NSApp.windows.contains { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
        if menuBarVisible, !hasWindow { NSApp.setActivationPolicy(.accessory) }
    }
}
