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
    /// 经本模型改过配置就加一；`config(of:)` 读它，好让展示配置的视图在改动后重绘。
    private var configRevision = 0
    private var servers: [String: ControlServer] = [:]
    private var refreshTask: Task<Void, Never>?
    /// 每次同步 `refresh` 加一；后台轮询读完时它变了，说明结果已比同步刷新的旧，丢弃。
    private var refreshGeneration = 0
    let library = VMLibrary.default

    init() {
        refresh()
        refreshTask = Task { [weak self, library] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let generation = self?.refreshGeneration else { return }
                let list = await Task.detached { VMStatus.summaries(in: library) }.value
                guard let self, generation == refreshGeneration else { continue }
                apply(list)
            }
        }
    }

    func refresh() {
        refreshGeneration += 1
        apply(VMStatus.summaries(in: library))
    }

    private func apply(_ list: [VMSummary]) {
        if list != machines { machines = list }
    }

    func summary(_ name: String) -> VMSummary? { machines.first { $0.name == name } }

    func config(of name: String) -> VMConfig? {
        _ = configRevision
        return try? library.bundle(named: name).loadConfig()
    }

    func isRunningHere(_ name: String) -> Bool { runners[name] != nil }

    // MARK: - 运行

    /// 在本进程启动并返回运行器；已在本进程运行时直接返回。
    @discardableResult
    func start(_ name: String) async -> (any MachineRunner)? {
        if let runner = runners[name] { return runner }
        do {
            let bundle = try library.bundle(named: name)
            let runner = try await RunnerFactory.make(bundle)
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
                try ControlClient.perform(.stop(force: force), on: bundle)
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
                try ControlClient.perform(.suspend, on: bundle, timeout: 300)
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
        updateConfig(name) { try $0.switchEngine(to: engine) }
    }

    /// 运行中也可改：只影响画面窗口向客户机请求的分辨率与缩放。
    func setRetina(_ name: String, _ retina: Bool) {
        if updateConfig(name, { $0.display.retina = retina }) { QEMUDisplayView.displayPreferenceChanged(name) }
    }

    /// 返回是否已保存；失败时报告错误。
    @discardableResult
    private func updateConfig(_ name: String, _ change: (inout VMConfig) throws -> Void) -> Bool {
        defer {
            configRevision += 1
            refresh()
        }
        do {
            let bundle = try library.bundle(named: name)
            var config = try bundle.loadConfig()
            try change(&config)
            try bundle.saveConfig(config)
            return true
        } catch {
            report(error)
            return false
        }
    }

    func clone(_ name: String, as newName: String) async {
        do { _ = try await VMClone.clone(library.bundle(named: name), as: newName) } catch { report(error) }
        refresh()
    }

    func report(_ error: any Error) {
        lastError = (error as? MacVMError)?.message ?? error.localizedDescription
    }
}
