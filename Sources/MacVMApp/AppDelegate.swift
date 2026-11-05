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

    /// 本进程运行的虚拟机要停下才能退出：问用户挂起还是关机，能挂起的挂起、其余正常关机，全部停下后才退出。
    /// 新建以外的任务（存模板、首次开机配置 SSH）中断后不会续做，一并在这里提醒。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 停机途中再次退出时由进行中的那一轮答复，这一次不另起。
        guard !shuttingDown else { return .terminateCancel }
        let running = model.runners.keys.sorted()
        let suspendable = running.filter { model.canSuspend($0) }
        let creating = model.resumableCreations
        let other = model.creatingNames.filter { !creating.contains($0) }
        var notes: [String] = []
        if !creating.isEmpty {
            notes.append("\(creating.joined(separator: "、")) 还在创建，退出会中断创建，下次打开 MacVM 时自动继续，已下载的部分不用重下。")
        }
        if !other.isEmpty {
            notes.append("\(other.joined(separator: "、")) 有进行中的任务，退出会中断，不会自动继续。")
        }
        guard !running.isEmpty || !notes.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        if running.isEmpty {
            alert.messageText = "要退出 MacVM 吗？"
            alert.addButton(withTitle: "退出")
        } else {
            alert.messageText = running.count == 1 ? "「\(running[0])」还在运行" : "还有 \(running.count) 台虚拟机在运行"
            notes.insert(Self.stopNote(running: running, suspendable: suspendable), at: 0)
            if !suspendable.isEmpty { alert.addButton(withTitle: "挂起并退出") }
            alert.addButton(withTitle: suspendable.isEmpty ? "关机并退出" : "全部关机并退出")
        }
        alert.informativeText = notes.joined(separator: "\n\n")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApp.activate()
        let choice = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choice < alert.buttons.count - 1 else { return .terminateCancel }
        guard !running.isEmpty else { return .terminateNow }
        let suspend = choice == 0 && !suspendable.isEmpty ? suspendable : []
        shuttingDown = true
        Task { await stopThenTerminate(suspending: suspend) }
        return .terminateLater
    }

    /// 提示里说明各台虚拟机退出时会怎样。
    private static func stopNote(running: [String], suspendable: [String]) -> String {
        let others = running.filter { !suspendable.contains($0) }
        if others.isEmpty {
            return "挂起会保存当前状态，下次开机从这里接着运行；关机要等客户机自己关好。"
        }
        if suspendable.isEmpty {
            return "\(others.joined(separator: "、")) 不支持挂起，退出前要等客户机正常关机。"
        }
        return "挂起时 \(suspendable.joined(separator: "、")) 保存当前状态，下次开机接着运行；\(others.joined(separator: "、")) 不支持挂起，会正常关机。"
    }

    /// 先挂起 `suspending` 里的虚拟机（挂起失败的改为关机），再让其余的正常关机。
    /// 客户机可能停在「是否保存」之类的对话框上迟迟不关机，每等满 `shutdownWait` 问一次是继续等、断电还是不退出了。
    private func stopThenTerminate(suspending: [String]) async {
        defer { shuttingDown = false }
        await model.suspendForQuit(suspending)
        model.requestStopAll()
        while !(await model.waitUntilAllStopped(timeout: Self.shutdownWait)) {
            let alert = NSAlert()
            alert.messageText = "\(model.runners.keys.sorted().joined(separator: "、")) 还没停下"
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
