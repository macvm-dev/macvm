import Foundation
import MacVMEngine
import MacVMModel
import Observation

/// 应用的全部状态：虚拟机列表，以及本进程内运行的虚拟机。
///
/// 别的进程（`macvm start`）运行的虚拟机只能经控制 socket 操作，画面无法在本进程显示。
@MainActor
@Observable
final class AppModel {
    var machines: [VMSummary] = []
    var selection: String?
    var showingCreate = false
    var lastError: String?
    /// 正在进行的长操作（安装、下载），键为虚拟机名。
    var activity: [String: String] = [:]

    private(set) var runners: [String: any MachineRunner] = [:]
    private var servers: [String: ControlServer] = [:]
    private var refreshTask: Task<Void, Never>?
    let library = VMLibrary.default

    init() {
        refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    func refresh() {
        let list = (try? library.all().compactMap { try? VMStatus.summary(of: $0) }) ?? []
        if list != machines { machines = list }
    }

    func summary(_ name: String) -> VMSummary? { machines.first { $0.name == name } }

    func isRunningHere(_ name: String) -> Bool { runners[name] != nil }

    // MARK: - 运行

    /// 在本进程启动并返回运行器；已在本进程运行时直接返回。
    @discardableResult
    func start(_ name: String) async -> (any MachineRunner)? {
        if let runner = runners[name] { return runner }
        do {
            let bundle = try library.bundle(named: name)
            try await RunnerFactory.prepare(bundle)
            let runner = try RunnerFactory.make(bundle)
            let server = try ControlServer(runner: runner)
            runners[name] = runner
            servers[name] = server
            runner.onStop = { [weak self] _ in
                Task { @MainActor in self?.detach(name) }
            }
            try await runner.start()
            refresh()
            return runner
        } catch {
            detach(name)
            report(error)
            return nil
        }
    }

    func stop(_ name: String, force: Bool = false) async {
        do {
            if let runner = runners[name] {
                if force { try await runner.forceStop() } else { try runner.requestStop() }
            } else {
                let bundle = try library.bundle(named: name)
                _ = try ControlClient.check(ControlClient.send(.stop(force: force), to: bundle), bundle: bundle)
            }
        } catch { report(error) }
        refresh()
    }

    func suspend(_ name: String) async {
        do {
            if let runner = runners[name] {
                try await runner.suspend()
            } else {
                let bundle = try library.bundle(named: name)
                _ = try ControlClient.check(ControlClient.send(.suspend, to: bundle, timeout: 300), bundle: bundle)
            }
        } catch { report(error) }
        refresh()
    }

    private func detach(_ name: String) {
        servers[name]?.close()
        servers[name] = nil
        runners[name] = nil
        refresh()
    }

    // MARK: - 管理

    func delete(_ name: String) {
        do {
            try VMFactory.delete(library.bundle(named: name))
            if selection == name { selection = nil }
        } catch { report(error) }
        refresh()
    }

    func setEngine(_ name: String, to engine: Engine) {
        do {
            let bundle = try library.bundle(named: name)
            var config = try bundle.loadConfig()
            try config.switchEngine(to: engine)
            try bundle.saveConfig(config)
        } catch { report(error) }
        refresh()
    }

    func clone(_ name: String, as newName: String) async {
        do { _ = try await VMClone.clone(library.bundle(named: name), as: newName) } catch { report(error) }
        refresh()
    }

    func report(_ error: any Error) {
        lastError = (error as? MacVMError)?.message ?? error.localizedDescription
    }
}
