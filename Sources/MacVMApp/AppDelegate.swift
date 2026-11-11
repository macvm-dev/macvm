import AppKit
import MacVMEngine
import MacVMModel

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
        SkillInstaller.updateInstalled()
        NetworkHelperRegistration.reconcile()
        // 直接运行可执行文件（不经 LaunchServices）启动时系统不会激活 App，窗口压在启动它的终端后面。
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        ChildProcesses.terminateAll()
        AppLanguage.reopenAfterExit()
    }

    /// 本进程运行的虚拟机要交出去或停下才能退出：问用户转到后台、挂起还是关机，全部处理完才退出。
    /// 新建以外的任务（存模板、首次开机配置 SSH）中断后不会续做，一并在这里提醒。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 停机途中再次退出时由进行中的那一轮答复，这一次不另起。
        guard !shuttingDown else { return .terminateCancel }
        let running = model.runners.keys.sorted()
        let background = running.filter { model.canMoveToBackground($0) }
        let suspendable = running.filter { model.canSuspend($0) }
        let creating = model.resumableCreations
        let other = model.creatingNames.filter { !creating.contains($0) }
        var notes: [String] = []
        if !creating.isEmpty {
            notes.append(String(l10n: "Quitting interrupts creating \(creating.formatted(.list(type: .and))). Creation resumes the next time you open MacVM, and anything already downloaded won't be downloaded again."))
        }
        if !other.isEmpty {
            notes.append(String(l10n: "Quitting interrupts tasks in progress for \(other.formatted(.list(type: .and))). They won't resume automatically."))
        }
        guard !running.isEmpty || !notes.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        var actions: [QuitAction] = []
        if running.isEmpty {
            alert.messageText = String(l10n: "Quit MacVM?")
            alert.addButton(withTitle: String(l10n: "Quit"))
            actions.append(.shutDown)
        } else {
            alert.messageText = running.count == 1 ? String(l10n: "“\(running[0])” is still running") : String(l10n: "\(running.count) virtual machines are still running")
            var stopNotes: [String] = []
            if !background.isEmpty {
                stopNotes.append(backgroundNote(running: running, background: background, suspendable: suspendable))
                alert.addButton(withTitle: String(l10n: "Move to Background and Quit"))
                actions.append(.background)
            }
            stopNotes.append(Self.stopNote(running: running, suspendable: suspendable))
            notes.insert(contentsOf: stopNotes, at: 0)
            if !suspendable.isEmpty {
                alert.addButton(withTitle: String(l10n: "Suspend and Quit"))
                actions.append(.suspend)
            }
            alert.addButton(withTitle: suspendable.isEmpty ? String(l10n: "Shut Down and Quit") : String(l10n: "Shut Down All and Quit"))
            actions.append(.shutDown)
        }
        alert.informativeText = notes.joined(separator: "\n\n")
        alert.addButton(withTitle: String(l10n: "Cancel")).keyEquivalent = "\u{1b}"
        NSApp.activate()
        let choice = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard actions.indices.contains(choice) else {
            AppLanguage.restartRequested = false
            return .terminateCancel
        }
        guard !running.isEmpty else { return .terminateNow }
        shuttingDown = true
        switch actions[choice] {
        case .background:
            // 转不到后台的照样能挂起的挂起。
            let rest = suspendable.filter { !background.contains($0) }
            Task { await stopThenTerminate(background: background, suspending: rest) }
        case .suspend:
            Task { await stopThenTerminate(suspending: suspendable) }
        case .shutDown:
            Task { await stopThenTerminate(suspending: []) }
        }
        return .terminateLater
    }

    private enum QuitAction { case background, suspend, shutDown }

    /// 提示里说明转到后台时各台虚拟机会怎样。
    private func backgroundNote(running: [String], background: [String], suspendable: [String]) -> String {
        let subject = background.count == running.count ? String(l10n: "the virtual machines") : background.formatted(.list(type: .and))
        var note = String(l10n: "Moving to the background suspends \(subject) for a few seconds while a background process takes over. That process keeps running after MacVM quits.")
        if background.contains(where: { model.config(of: $0)?.engine == .vz }) {
            note += String(l10n: " Only the process running a VZ virtual machine can show its screen, so to see it again, shut it down and start it in MacVM.")
        }
        let rest = running.filter { !background.contains($0) }
        let restSuspended = rest.filter { suspendable.contains($0) }
        let restStopped = rest.filter { !suspendable.contains($0) }
        if !restSuspended.isEmpty { note += String(l10n: " \(restSuspended.formatted(.list(type: .and))) can't move to the background and will be suspended.") }
        if !restStopped.isEmpty { note += String(l10n: " \(restStopped.formatted(.list(type: .and))) can't move to the background and will shut down normally.") }
        return note
    }

    /// 提示里说明挂起或关机时各台虚拟机会怎样。
    private static func stopNote(running: [String], suspendable: [String]) -> String {
        let others = running.filter { !suspendable.contains($0) }
        if others.isEmpty {
            return String(l10n: "Suspending saves the current state so the next start picks up where it left off. Shutting down waits for the guest to shut down on its own.")
        }
        if suspendable.isEmpty {
            return String(l10n: "\(others.formatted(.list(type: .and))) can't be suspended. MacVM waits for the guest to shut down before quitting.")
        }
        return String(l10n: "Suspending saves the current state of \(suspendable.formatted(.list(type: .and))) so the next start picks up where it left off. \(others.formatted(.list(type: .and))) can't be suspended and will shut down normally.")
    }

    /// 先把 `background` 里的虚拟机转到后台、挂起 `suspending` 里的（挂起失败的改为关机），再让其余的正常关机。
    /// 客户机可能停在「是否保存」之类的对话框上迟迟不关机，每等满 `shutdownWait` 问一次是继续等、断电还是不退出了。
    private func stopThenTerminate(background: [String] = [], suspending: [String]) async {
        defer { shuttingDown = false }
        let failed = await model.moveToBackgroundForQuit(background)
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(l10n: "Couldn't move \(failed.map(\.name).formatted(.list(type: .and))) to the background")
            alert.informativeText = failed.map { String(l10n: "\($0.name): \($0.reason)") }.joined(separator: "\n")
                + "\n\n" + String(l10n: "The suspended state is saved, so any that didn't start in the background will resume at the next start.")
            alert.addButton(withTitle: String(l10n: "OK"))
            NSApp.activate()
            alert.runModal()
        }
        await model.suspendForQuit(suspending)
        model.requestStopAll()
        while !(await model.waitUntilAllStopped(timeout: Self.shutdownWait)) {
            let alert = NSAlert()
            alert.messageText = String(l10n: "Still waiting for \(model.runners.keys.sorted().formatted(.list(type: .and))) to shut down")
            alert.informativeText = String(l10n: "The guest may be waiting for you to save a document or confirm the shutdown. You can handle it in the virtual machine's window and keep waiting. Powering off loses any unsaved work in the guest.")
            alert.addButton(withTitle: String(l10n: "Keep Waiting"))
            alert.addButton(withTitle: String(l10n: "Power Off and Quit"))
            alert.addButton(withTitle: String(l10n: "Don't Quit"))
            NSApp.activate()
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                continue
            case .alertSecondButtonReturn:
                await model.forceStopAll()
            default:
                AppLanguage.restartRequested = false
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
