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
    var lastError: ReportedError?
    /// 正在进行的长操作（创建、下载、安装），键为虚拟机名；创建时虚拟机包还不存在，`machines` 里没有它。
    /// 字典只在操作开始、结束时变，进度改在 `Activity` 对象上：进度更新只重绘显示它的视图，不牵动整个窗口。
    private(set) var activity: [String: Activity] = [:]

    @MainActor
    @Observable
    final class Activity {
        var title: String
        /// 如「1.2G / 3G」。
        var detail: String?
        /// 0...1；nil 表示进度未知。
        var fraction: Double?
        /// 下载速度，平滑过的；不在下载时为 nil。
        var bytesPerSecond: Double?
        /// 这一步是下载。
        var downloading: Bool
        @ObservationIgnored private var sampledAt: Date?
        @ObservationIgnored private var sampledBytes: Int64?

        init(title: String, fraction: Double?, downloading: Bool) {
            self.title = title
            self.fraction = fraction
            self.downloading = downloading
        }

        var text: String {
            var parts = [title]
            if let detail { parts.append(detail) }
            if let fraction, detail != nil { parts.append("\(Int(fraction * 100))%") }
            if let bytesPerSecond { parts.append(DisplaySize.format(UInt64(bytesPerSecond)) + "/s") }
            return parts.joined(separator: " ")
        }

        /// 换到新的一步：清掉上一步的下载进度。
        func begin(_ title: String, fraction: Double?, downloading: Bool) {
            self.title = title
            self.fraction = fraction
            self.downloading = downloading
            detail = nil
            bytesPerSecond = nil
            sampledAt = nil
            sampledBytes = nil
        }

        /// 记下一次下载进度，并据与上次的差值更新速度。
        func record(received: Int64, total: Int64?, at now: Date = .now) {
            detail = total.map { "\(DisplaySize.format(UInt64(received))) / \(DisplaySize.format(UInt64($0)))" } ?? DisplaySize.format(UInt64(received))
            fraction = total.map { min(1, Double(received) / Double($0)) }
            if let sampledAt, let sampledBytes, received >= sampledBytes, now.timeIntervalSince(sampledAt) > 0 {
                let instant = Double(received - sampledBytes) / now.timeIntervalSince(sampledAt)
                bytesPerSecond = bytesPerSecond.map { $0 * 0.7 + instant * 0.3 } ?? instant
            } else {
                bytesPerSecond = nil
            }
            sampledAt = now
            sampledBytes = received
        }
    }

    /// 上次 App 退出时没做完的新建请求。
    private(set) var interruptedCreations: [CreationRequest] = CreationStore.load()
    /// 本进程里正在做的新建请求，键为虚拟机名。
    private var runningCreations: [String: CreationRequest] = [:]
    private var creationTasks: [String: Task<Void, Never>] = [:]
    private var resumedAtLaunch = false
    /// 新建后首次开机装 SSH 公钥与客户机代理的任务，键为虚拟机名；虚拟机停下时取消。
    @ObservationIgnored private var sshKeyTasks: [String: Task<Void, Never>] = [:]

    private(set) var runners: [String: any MachineRunner] = [:]
    /// 经本模型改过配置就加一；`config(of:)` 读它，好让展示配置的视图在改动后重绘。
    private var configRevision = 0
    private var servers: [String: ControlServer] = [:]
    private var refreshTask: Task<Void, Never>?
    /// 每次同步 `refresh` 加一；后台轮询读完时它变了，说明结果已比同步刷新的旧，丢弃。
    private var refreshGeneration = 0
    /// 别的进程里运行的虚拟机能否挂起，开机后经控制 socket 问一次，停机后清掉。
    private var remoteSuspend: [String: Bool] = [:]

    enum GuestUpdateState: Equatable {
        case available(GuestUpdate.Pending)
        /// 当前步骤。
        case updating(String)
        /// 更新完了，有的设置要重启客户机才生效。
        case rebootRequired
    }
    /// 运行中、有客户机更新可做或正在做的虚拟机，键为虚拟机名。
    private(set) var guestUpdates: [String: GuestUpdateState] = [:]
    /// 每台运行中虚拟机这次开机的更新核对，不论在哪个进程里运行；停机时取消并清掉。
    @ObservationIgnored private var guestUpdateChecks: [String: Task<Void, Never>] = [:]
    private static let guestUpdateCheckAttempts = 120
    private static let guestUpdateCheckInterval: Duration = .seconds(5)

    /// 经控制 socket 问运行 `machines` 的进程能否挂起；问不到的不记，下一轮再问。
    nonisolated private static func querySuspend(of machines: [VMSummary], in library: VMLibrary) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for vm in machines {
            guard let bundle = try? library.bundle(named: vm.name),
                  let canSuspend = (try? ControlClient.send(.status, to: bundle, timeout: 1))?.canSuspend else { continue }
            result[vm.name] = canSuspend
        }
        return result
    }
    private(set) var library = VMLibrary.default
    private(set) var settings = MacVMSettings.load()
    private(set) var templateLibrary = TemplateLibrary.default
    /// CLI 也会增删模板，不随虚拟机列表轮询；显示模板的界面出现时调 `refreshTemplates`。
    private(set) var templates: [TemplateSummary] = []

    init() {
        refresh()
        refreshTemplates()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let (generation, library) = self.map({ ($0.refreshGeneration, $0.library) }) else { return }
                let list = await Task.detached { VMStatus.summaries(in: library) }.value
                guard let self, generation == refreshGeneration else { continue }
                apply(list)
                // 列表先更新：问挂起能力要连各虚拟机的控制 socket，连不上时每台要等到超时。
                let known = Set(remoteSuspend.keys).union(runners.keys)
                let pending = list.filter { $0.state == .running && !known.contains($0.name) }
                guard !pending.isEmpty else { continue }
                let queried = await Task.detached { Self.querySuspend(of: pending, in: library) }.value
                let running = Set(machines.filter { $0.state == .running }.map(\.name))
                remoteSuspend.merge(queried.filter { running.contains($0.key) }) { $1 }
            }
        }
    }

    func refresh() {
        refreshGeneration += 1
        apply(VMStatus.summaries(in: library))
    }

    private func apply(_ list: [VMSummary]) {
        if list != machines { machines = list }
        let running = Set(list.filter { $0.state == .running }.map(\.name))
        if remoteSuspend.keys.contains(where: { !running.contains($0) }) { remoteSuspend = remoteSuspend.filter { running.contains($0.key) } }
        for vm in list where vm.state != .running { clearStopping(vm.name) }
        for name in guestUpdateChecks.keys where !running.contains(name) {
            guestUpdateChecks.removeValue(forKey: name)?.cancel()
            guestUpdates[name] = nil
        }
        for name in running where guestUpdateChecks[name] == nil { checkGuestUpdate(name) }
    }

    /// 等代理上线后核对一次；客户机代理在登录后才启动，最多等 `guestUpdateCheckAttempts` 轮。
    private func checkGuestUpdate(_ name: String) {
        guard config(of: name)?.guestAgent == true, let bundle = try? library.bundle(named: name) else {
            guestUpdateChecks[name] = Task {}
            return
        }
        guestUpdateChecks[name] = Task { [weak self] in
            for _ in 0..<Self.guestUpdateCheckAttempts {
                let pending = await Task.detached { try? GuestUpdate.pending(bundle) }.value
                guard !Task.isCancelled else { return }
                if let pending {
                    if !pending.isEmpty { self?.guestUpdates[name] = .available(pending) }
                    return
                }
                try? await Task.sleep(for: Self.guestUpdateCheckInterval)
            }
        }
    }

    /// 经运行中的代理把客户机更新到 App 当前的版本。
    func updateGuest(_ name: String) {
        guard case .available(let pending) = guestUpdates[name], let bundle = try? library.bundle(named: name) else { return }
        guestUpdates[name] = .updating(String(l10n: "Preparing…"))
        Task {
            do {
                let result = try await GuestUpdate.apply(bundle) { step in
                    Task { @MainActor in
                        if case .updating = self.guestUpdates[name] { self.guestUpdates[name] = .updating(step) }
                    }
                }
                guard case .updating = guestUpdates[name] else { return }
                guestUpdates[name] = result.rebootRequired ? .rebootRequired : nil
            } catch {
                if case .updating = guestUpdates[name] { guestUpdates[name] = .available(pending) }
                report(error)
            }
        }
    }

    /// 更新后要重启才生效时，请客户机重启。
    func rebootGuest(_ name: String) {
        guard guestUpdates[name] == .rebootRequired, let bundle = try? library.bundle(named: name) else { return }
        guestUpdates[name] = nil
        Task {
            do { try await Task.detached { try GuestUpdate.reboot(bundle) }.value } catch {
                guestUpdates[name] = .rebootRequired
                report(error)
            }
        }
    }

    func summary(_ name: String) -> VMSummary? { machines.first { $0.name == name } }

    func config(of name: String) -> VMConfig? {
        _ = configRevision
        return try? library.bundle(named: name).loadConfig()
    }

    func isRunningHere(_ name: String) -> Bool { runners[name] != nil }

    /// 有创建、下载、安装或取消在进行的虚拟机名；等客户机关机不算。
    var creatingNames: [String] {
        activity.filter { $0.value.title != Self.stoppingTitle }.keys.sorted()
    }

    /// 已请求正常关机、还在等客户机自己关。
    func isStopping(_ name: String) -> Bool { activity[name]?.title == Self.stoppingTitle }

    /// 新建后的首次开机：客户机在建用户目录、自动登录，宿主在装 SSH 公钥与代理。
    func isSettingUpGuest(_ name: String) -> Bool { activity[name]?.title == Self.sshKeyTitle }

    /// 正在创建、还没出现在 `machines` 里的虚拟机名。
    var pendingCreations: [String] {
        activity.keys.filter { name in !machines.contains { $0.name == name } }.sorted()
    }

    func setActivity(_ name: String, _ title: String?, fraction: Double? = nil, downloading: Bool = false) {
        guard let title else {
            activity[name] = nil
            return
        }
        if let current = activity[name] {
            current.begin(title, fraction: fraction, downloading: downloading)
        } else {
            activity[name] = Activity(title: title, fraction: fraction, downloading: downloading)
        }
    }

    var isDownloading: Bool { activity.values.contains { $0.downloading } }

    /// 运行 `body`，其间发生的下载把字节进度写进 `activity[name]`。
    func trackingDownloads<T>(of name: String, _ body: () async throws -> T) async rethrows -> T {
        let handler: DownloadProgress.Handler = { [weak self] received, total in
            // 时间在采样处取：主线程忙时几次回报会挤在一起执行，那时再取时间算出的速度失真。
            let now = Date.now
            Task { @MainActor in
                self?.activity[name]?.record(received: received, total: total, at: now)
            }
        }
        return try await DownloadProgress.$handler.withValue(handler) { try await body() }
    }

    /// 运行中的虚拟机能否在本进程显示画面：QEMU 的画面经 VNC 显示，别的进程运行的也能接上；
    /// VZ 的画面只能在运行它的进程里显示，别的进程运行的要先 `takeOver`。
    func canDisplay(_ name: String) -> Bool {
        isRunningHere(name) || config(of: name)?.engine == .qemu || canTakeOver(name)
    }

    /// 别的进程运行的 VZ 虚拟机能否接到本进程：那边挂起、本进程从挂起状态恢复。还没问到那边能否挂起时先当能，由 `takeOver` 确认。
    /// 开了 `VMConfig.serialConsole` 的不行：后台进程为控制台多接了串口，存下的状态与本进程组装的设备对不上。
    func canTakeOver(_ name: String) -> Bool {
        guard summary(name)?.state == .running, !isRunningHere(name), let config = config(of: name), config.engine == .vz else { return false }
        return remoteSuspend[name] != false && !config.serialConsole
    }

    /// 把别的进程运行的 VZ 虚拟机接到本进程显示：请那边挂起，等它退出后在本进程恢复。
    /// 挂起失败时虚拟机留在原进程照常运行；恢复失败时停在挂起状态。失败时报告错误并返回 nil。
    func takeOver(_ name: String) async -> (any MachineRunner)? {
        setActivity(name, Self.takingOverTitle)
        defer { if activity[name]?.title == Self.takingOverTitle { setActivity(name, nil) } }
        do {
            let bundle = try library.bundle(named: name)
            let canSuspend = try await Task.detached { try ControlClient.send(.status, to: bundle, timeout: 5).canSuspend }.value
            remoteSuspend[name] = canSuspend
            guard canSuspend == true else {
                throw MacVMError.unsupported(String(l10n: "Can't move \(name) into the app because its background process can't suspend it. Shut it down and start it here to see its screen"))
            }
            try await Self.sendControl(.suspend, to: bundle, timeout: 300)
            guard try await VMStatus.waitUntilStopped(bundle, timeout: 30) else {
                throw MacVMError.timeout(String(l10n: "\(name) was suspended, but its background process didn't exit"))
            }
            remoteSuspend[name] = nil
            return try await launch(name)
        } catch {
            report(error)
            refresh()
            return nil
        }
    }

    private static let takingOverTitle = String(l10n: "Moving into the app…")

    /// 是否提供挂起：运行中的以运行它的进程报的为准（别的进程可能用了另一套 QEMU），其余按配置与本机的 QEMU 判断。
    func canSuspend(_ name: String) -> Bool {
        if let runner = runners[name] { return runner.canSuspend }
        if let remote = remoteSuspend[name] { return remote }
        guard let config = config(of: name) else { return false }
        return config.engine == .qemu ? QEMUInstallation.canSuspend(config) : config.supportsSuspend
    }

    // MARK: - 运行

    /// 在本进程启动并返回运行器；已在本进程运行时直接返回。失败时把原因写进 `lastError` 并返回 nil。
    @discardableResult
    func start(_ name: String) async -> (any MachineRunner)? {
        do {
            return try await launch(name)
        } catch {
            report(error)
            return nil
        }
    }

    /// 在本进程启动并返回运行器；已在本进程运行时直接返回。失败时不报告、不打断本虚拟机的其他任务。
    /// 同名的启动还没结束时等它的结果，不另起一次：同一台同时只能有一次启动在登记、撤销运行器与控制 socket。
    private func launch(_ name: String) async throws -> any MachineRunner {
        if let pending = launches[name] { return try await pending.value }
        if let runner = runners[name] { return runner }
        let task = Task { try await self.startRunner(name) }
        launches[name] = task
        defer { launches[name] = nil }
        return try await task.value
    }

    /// 进行中的 `launch`，键为虚拟机名。
    @ObservationIgnored private var launches: [String: Task<any MachineRunner, any Error>] = [:]

    /// 本进程最近一次开机是从挂起状态恢复的虚拟机；恢复失败而冷启动的不在其中。
    @ObservationIgnored private var restoredStarts: Set<String> = []

    func wasRestored(_ name: String) -> Bool { restoredStarts.contains(name) }

    private func startRunner(_ name: String) async throws -> any MachineRunner {
        do {
            let bundle = try library.bundle(named: name)
            let runner = try await RunnerFactory.make(bundle)
            let server = try ControlServer(runner: runner)
            runners[name] = runner
            servers[name] = server
            runner.onStop = { [weak self, weak runner] _ in
                Task { @MainActor in
                    // 这台停下后同名的可能已换了新运行器。
                    guard let self, let runner, self.runners[name] === runner else { return }
                    self.detach(name)
                }
            }
            if case .restored = try await runner.start() { restoredStarts.insert(name) } else { restoredStarts.remove(name) }
            refresh()
            return runner
        } catch {
            release(name)
            throw error
        }
    }

    func stop(_ name: String, force: Bool = false) async {
        do {
            if let runner = runners[name] {
                if force { try await runner.forceStop() } else { try runner.requestStop() }
            } else {
                let bundle = try library.bundle(named: name)
                try await Self.sendControl(.stop(force: force), to: bundle)
            }
            if !force { showStopping(name) }
        } catch { report(error) }
        refresh()
    }

    /// 控制 socket 的往返会阻塞到对方回复（挂起要等内存存完），放到主线程之外。
    private nonisolated static func sendControl(_ request: ControlRequest, to bundle: VMBundle, timeout: Int = 60) async throws {
        try await Task.detached { try ControlClient.perform(request, on: bundle, timeout: timeout) }.value
    }

    /// 正常关机要等客户机自己关，期间状态显示「正在关机」；停下或等满 `stoppingTimeout` 后撤掉。
    /// 已有进行中的任务（如安装）时不覆盖它的进度。
    private func showStopping(_ name: String) {
        guard activity[name] == nil else { return }
        setActivity(name, Self.stoppingTitle)
        stoppingTimers[name]?.cancel()
        stoppingTimers[name] = Task { [weak self] in
            do { try await Task.sleep(for: Self.stoppingTimeout) } catch { return }
            self?.clearStopping(name)
        }
    }

    private func clearStopping(_ name: String) {
        guard isStopping(name) else { return }
        stoppingTimers.removeValue(forKey: name)?.cancel()
        setActivity(name, nil)
    }

    /// 每台虚拟机这一轮「正在关机」的超时任务；状态撤掉时取消，免得到点时撤掉之后新一轮的。
    @ObservationIgnored private var stoppingTimers: [String: Task<Void, Never>] = [:]

    /// 退出前逐台挂起本进程运行的 `names`；挂起失败的留着运行，由随后的关机处理。
    func suspendForQuit(_ names: [String]) async {
        for name in names {
            guard let runner = runners[name] else { continue }
            setActivity(name, String(l10n: "Suspending…"))
            try? await runner.suspend()
            setActivity(name, nil)
        }
    }

    /// 退出时能否转到后台进程接着运行：在本进程挂起，再由后台进程从挂起状态恢复。
    /// 开了 `VMConfig.serialConsole` 的 VZ 虚拟机不行：后台进程为控制台多接一个串口，与本进程存下的状态对不上，只能冷启动。
    func canMoveToBackground(_ name: String) -> Bool {
        guard let runner = runners[name], runner.canSuspend else { return false }
        return !(runner.config.engine == .vz && runner.config.serialConsole)
    }

    /// 退出前逐台挂起本进程运行的 `names`，交给后台进程从挂起状态接着运行。挂起失败的留着运行，由随后的关机处理；
    /// 返回挂起了但没等到后台进程就绪的与原因：后台进程没起来的停在挂起状态，超时的可能稍后自己运行起来。
    func moveToBackgroundForQuit(_ names: [String]) async -> [(name: String, reason: String)] {
        var failed: [(name: String, reason: String)] = []
        for name in names {
            guard let runner = runners[name] else { continue }
            setActivity(name, String(l10n: "Moving to the background…"))
            defer { setActivity(name, nil) }
            guard (try? await runner.suspend()) != nil else { continue }
            do {
                _ = try await DetachedRun.launch(runner.bundle, executable: CLILocation.path, timeout: 120)
            } catch {
                failed.append((name, error.localizedDescription))
            }
        }
        return failed
    }

    /// 让本进程运行的每台虚拟机正常关机；请求不了的（还在开机等）留给 `forceStopAll`。
    func requestStopAll() {
        for (name, runner) in runners where (try? runner.requestStop()) != nil {
            showStopping(name)
        }
    }

    /// 等本进程运行的虚拟机全部停下，返回是否在 `timeout` 内等到。
    func waitUntilAllStopped(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !runners.isEmpty {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    func forceStopAll() async {
        for runner in Array(runners.values) { try? await runner.forceStop() }
    }

    private static let stoppingTitle = String(l10n: "Shutting down…")
    private static let stoppingTimeout: Duration = .seconds(90)

    func suspend(_ name: String) async {
        do {
            if let runner = runners[name] {
                try await runner.suspend()
            } else {
                let bundle = try library.bundle(named: name)
                try await Self.sendControl(.suspend, to: bundle, timeout: 300)
            }
        } catch { report(error) }
        refresh()
    }

    private func detach(_ name: String) {
        if let task = sshKeyTasks.removeValue(forKey: name) {
            task.cancel()
            // 进行中的那次 ssh 要等它自己超时才返回，提示先撤掉，免得停下的虚拟机一直显示在配置。
            if activity[name]?.title == Self.sshKeyTitle { setActivity(name, nil) }
        }
        release(name)
    }

    /// 撤掉本进程里这台的运行器与控制 socket，不动它的其他任务。
    private func release(_ name: String) {
        servers[name]?.close()
        servers[name] = nil
        runners[name] = nil
        attachedImages[name] = nil
        refresh()
    }

    // MARK: - 管理

    func delete(_ name: String) {
        do {
            try requireIdle(name)
            try VMFactory.delete(library.bundle(named: name))
            if selection == name { selection = nil }
        } catch { report(error) }
        refresh()
    }

    func setEngine(_ name: String, to engine: Engine) {
        updateConfig(name, requiresStopped: true) { try $0.switchEngine(to: engine) }
    }

    // MARK: - 声音

    /// 运行中也可改，下次开机生效。返回是否已保存。
    @discardableResult
    func setAudio(_ name: String, _ on: Bool) -> Bool {
        updateConfig(name, requiresStopped: !isRunning(name)) { $0.audio = on }
    }

    /// 运行中也可改，下次开机生效。返回是否已保存。
    @discardableResult
    func setMicrophone(_ name: String, _ on: Bool) -> Bool {
        updateConfig(name, requiresStopped: !isRunning(name)) { $0.microphone = on }
    }

    /// macOS、Windows 客户机运行中改了立即生效；Linux 客户机要关机后改。返回是否已保存。
    @discardableResult
    func setClipboard(_ name: String, _ on: Bool) -> Bool {
        updateConfig(name, requiresStopped: config(of: name)?.clipboardChangeNeedsStop ?? true) { $0.clipboard = on }
    }

    /// 运行中改了随即在后台写进客户机，写不进去时报错，配置照样保存、下次开机再写。返回是否已保存。
    /// 同一台的写入依次进行，每次写时重读配置，连着切换几次后客户机停在最后一次的设置上。
    @discardableResult
    func setScreenLock(_ name: String, _ on: Bool) -> Bool {
        guard updateConfig(name, { $0.screenLock = on }) else { return false }
        guard isRunning(name), let bundle = try? library.bundle(named: name), config(of: name)?.guestAgent == true else { return true }
        let previous = screenLockWrites[name]
        screenLockWrites[name] = Task {
            await previous?.value
            do { try await Task.detached { try GuestScreenLock.apply(bundle, config: bundle.loadConfig()) }.value } catch { report(error) }
        }
        return true
    }

    @ObservationIgnored private var screenLockWrites: [String: Task<Void, Never>] = [:]

    private func isRunning(_ name: String) -> Bool { runners[name] != nil || summary(name)?.state == .running }

    func setCPUCount(_ name: String, _ count: Int) {
        updateConfig(name, requiresStopped: true) { $0.cpuCount = count }
    }

    func setMemory(_ name: String, gigabytes: Int) {
        updateConfig(name, requiresStopped: true) { $0.memorySize = UInt64(gigabytes) << 30 }
    }

    func addShares(_ name: String, _ urls: [URL]) {
        updateShares(name) { config in
            for url in urls { try config.addShare(hostPath: url.standardizedFileURL.path) }
        }
    }

    func removeShare(_ name: String, hostPath: String) {
        updateShares(name) { $0.shares.removeAll { $0.hostPath == hostPath } }
    }

    func setShareReadOnly(_ name: String, hostPath: String, _ readOnly: Bool) {
        updateShares(name) { config in
            for i in config.shares.indices where config.shares[i].hostPath == hostPath { config.shares[i].readOnly = readOnly }
        }
    }

    /// 运行中能实时改共享目录的虚拟机（本进程运行的 macOS 客户机）。
    func canEditSharesLive(_ name: String) -> Bool { runners[name]?.supportsLiveShares == true }

    /// 能实时改的先改运行中的虚拟机，成功了才保存；否则只在关机时可改。
    private func updateShares(_ name: String, _ change: (inout VMConfig) throws -> Void) {
        if let runner = runners[name], runner.supportsLiveShares {
            updateConfig(name) { config in
                try change(&config)
                try runner.updateShares(config.shares)
            }
        } else {
            updateConfig(name, requiresStopped: true, change)
        }
    }

    // MARK: - 磁盘映像

    /// 本进程运行的虚拟机热插的磁盘映像，键为虚拟机名：运行器不可观察，接入、推出后在这里留一份给界面。
    private(set) var attachedImages: [String: [AttachedImage]] = [:]
    /// 正在接入或推出磁盘映像的虚拟机名。
    private(set) var changingImages: Set<String> = []

    func canAttachImages(_ name: String) -> Bool { runners[name]?.supportsImageHotPlug == true }

    func attachImages(_ name: String, _ urls: [URL]) async {
        guard let runner = runners[name] else { return }
        changingImages.insert(name)
        for url in urls {
            do { _ = try await runner.attachImage(url, readOnly: AttachedImage.prefersReadOnly(url)) } catch { report(error) }
        }
        changingImages.remove(name)
        attachedImages[name] = runners[name]?.attachedImages
    }

    func ejectImage(_ name: String, id: UUID) async {
        guard let runner = runners[name] else { return }
        changingImages.insert(name)
        do { try await runner.ejectImage(id) } catch { report(error) }
        changingImages.remove(name)
        attachedImages[name] = runners[name]?.attachedImages
    }

    /// 只扩大系统盘镜像，客户机里的分区要另行扩展。
    func growDisk(_ name: String, gigabytes: Int) {
        defer { refresh() }
        do {
            let bundle = try library.bundle(named: name)
            try requireStopped(bundle)
            try DiskImage.grow(at: bundle.diskURL, to: UInt64(gigabytes) << 30)
        } catch {
            report(error)
        }
    }

    /// `runners` 覆盖本进程刚启动、锁的持有状态还没反映到界面的那一刻。
    private func requireStopped(_ bundle: VMBundle) throws {
        if runners[bundle.name] != nil { throw MacVMError.alreadyRunning(bundle.name) }
        try bundle.requireStopped()
    }

    /// 运行中也可改：只影响画面窗口向客户机请求的分辨率与缩放。
    func setRetina(_ name: String, _ retina: Bool) {
        if updateConfig(name, { $0.display.retina = retina }) { DisplayPreference.didChange(for: name) }
    }

    /// 返回是否已保存；失败时报告错误。
    @discardableResult
    private func updateConfig(_ name: String, requiresStopped: Bool = false, _ change: (inout VMConfig) throws -> Void) -> Bool {
        defer {
            configRevision += 1
            refresh()
        }
        do {
            let bundle = try library.bundle(named: name)
            if requiresStopped { try requireStopped(bundle) }
            var config = try bundle.loadConfig()
            try change(&config)
            try bundle.saveConfig(config)
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: - 位置

    /// 只改查找位置，不搬动已有的虚拟机。运行中的虚拟机的控制 socket 与锁、创建中或中断的虚拟机包都在原目录下，
    /// 这时不能改；`runners` 覆盖已在本进程启动、`machines` 还没刷新到的那一刻。
    var canChangeLibrary: Bool {
        VMLibrary.environmentRoot == nil && runners.isEmpty && activity.isEmpty && interruptedCreations.isEmpty
            && !machines.contains { $0.state == .running }
    }

    /// 下载中改目录会让下载完的镜像落在旧目录、新目录里找不到。
    var canChangeDownloads: Bool { activity.isEmpty }

    /// 存模板、从模板新建都在 `activity` 里，进行中改目录会让模板存到旧目录、或找不到要复制的模板。
    var canChangeTemplates: Bool { activity.isEmpty }

    /// `url` 为 nil 时恢复默认位置。
    func setLibraryPath(_ url: URL?) {
        guard canChangeLibrary, updateSettings({ $0.libraryPath = url?.path }) else { return }
        library = .default
        refresh()
        SSHConfig.refreshIfInstalled(library: library, macvmPath: CLILocation.path)
    }

    /// `url` 为 nil 时恢复默认位置。
    func setDownloadPath(_ url: URL?) {
        guard canChangeDownloads else { return }
        updateSettings { $0.downloadPath = url?.path }
    }

    /// `url` 为 nil 时恢复默认位置。
    func setTemplatePath(_ url: URL?) {
        guard canChangeTemplates, updateSettings({ $0.templatePath = url?.path }) else { return }
        templateLibrary = .default
        refreshTemplates()
    }

    @discardableResult
    private func updateSettings(_ change: (inout MacVMSettings) -> Void) -> Bool {
        var next = settings
        change(&next)
        do {
            try next.save()
            settings = next
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: - 模板

    func refreshTemplates() {
        let list = VMTemplate.summaries(in: templateLibrary)
        if list != templates { templates = list }
    }

    func template(_ name: String) -> TemplateSummary? { templates.first { $0.name == name } }

    /// 跨卷时要整盘复制，期间虚拟机显示进度、不能开机或修改。
    func saveTemplate(_ name: String, as templateName: String) async {
        setActivity(name, String(l10n: "Saving as template…"))
        defer {
            setActivity(name, nil)
            refreshTemplates()
        }
        do {
            let bundle = try library.bundle(named: name)
            try requireStopped(bundle)
            _ = try await VMTemplate.save(bundle, as: templateName, in: templateLibrary)
        } catch { report(error) }
    }

    func deleteTemplate(_ name: String) {
        do { try VMTemplate.delete(named: name, in: templateLibrary) } catch { report(error) }
        refreshTemplates()
    }

    // MARK: - SSH

    /// `~/.ssh/config` 是否 Include 了 `SSHConfig.fileURL`。`macvm ssh-config` 也会改它，显示 SSH 命令的视图出现时调 `refreshSSHIncluded`。
    private(set) var sshIncluded = SSHConfig.isIncluded

    func refreshSSHIncluded() {
        let included = SSHConfig.isIncluded
        if included != sshIncluded { sshIncluded = included }
    }

    func setSSHIncluded(_ include: Bool) {
        do {
            if include {
                _ = try SSHConfig.write(library: library, macvmPath: CLILocation.path)
                try SSHConfig.installInclude()
            } else {
                try SSHConfig.removeInclude()
            }
        } catch { report(error) }
        refreshSSHIncluded()
    }

    /// 连上虚拟机的终端命令：已 Include 时直接 `ssh <名字>`，否则经 `macvm ssh`。
    func sshCommand(_ name: String) -> String { sshIncluded ? "ssh \(name)" : "macvm ssh \(name)" }

    // MARK: - 新建

    /// 在后台按 `request` 新建；需要用户在窗口里操作时（装 Windows、图形安装）和从模板建完时调用 `openMachineWindow`。
    /// `resumed` 的请求失败后回到 `interruptedCreations`，留给用户继续或放弃。
    func create(_ request: CreationRequest, resumed: Bool = false, openMachineWindow: @escaping @MainActor (String) -> Void) {
        let name = request.name
        if let interrupted = interruptedCreations.first(where: { $0.name == name }) {
            // 新请求顶替同名的中断请求，它留下的半成品包会占着名字。
            try? discardPartialBundle(of: interrupted)
            interruptedCreations.removeAll { $0.name == name }
        }
        runningCreations[name] = request
        persistCreations()
        setActivity(name, String(l10n: "Creating…"))
        creationTasks[name] = Task {
            defer {
                runningCreations[name] = nil
                creationTasks[name] = nil
                persistCreations()
                setActivity(name, nil)
                refresh()
            }
            do {
                try await trackingDownloads(of: name) { try await perform(request, openMachineWindow: openMachineWindow) }
                // 先删请求再删标记：两步之间退出时没有请求认领这个包，下次启动既不会删它，也不会再建一遍同名的。
                runningCreations[name] = nil
                persistCreations()
                try? FileManager.default.removeItem(at: VMBundle(url: library.bundleURL(named: name)).creationMarkerURL)
                SSHConfig.refreshIfInstalled(library: library, macvmPath: CLILocation.path)
                selection = name
                if request.source.template != nil {
                    // 模板里的系统已装好，建完直接开机。
                    openMachineWindow(name)
                } else if request.os == .macOS {
                    setUpGuestOnFirstBoot(name, tune: request.tune ?? true, openMachineWindow: openMachineWindow)
                }
            } catch {
                if Task.isCancelled {
                    cleanUpCancelled(request)
                } else {
                    if resumed { interruptedCreations.append(request) }
                    report(error)
                }
            }
        }
    }

    func isCreating(_ name: String) -> Bool { creationTasks[name] != nil }

    /// 本进程里正在新建的虚拟机名；App 中途退出后下次启动会接着做。
    var resumableCreations: [String] { creationTasks.keys.sorted() }

    /// 本进程里正在新建的虚拟机的客户机系统。
    func creatingOS(_ name: String) -> GuestOS? { runningCreations[name]?.os }

    /// 新建的 macOS 虚拟机首次开机，等远程登录可用后用密码登录一次装入 macvm 公钥，之后 SSH 都走密钥；
    /// 再把客户机主机名设为虚拟机名、时区设为宿主时区，App 带着 macOS 版客户机代理时经 SSH 装上代理，
    /// `tune` 时最后执行 `MacOSTuning` 的全部项。
    /// 不会自动开通时不开机：用户要先在窗口里走完设置助理。失败只报告，不影响虚拟机本身。
    private func setUpGuestOnFirstBoot(_ name: String, tune: Bool, openMachineWindow: @escaping @MainActor (String) -> Void) {
        guard let bundle = try? library.bundle(named: name), MacOSProvisioning.willApply(to: bundle),
              let user = try? bundle.loadConfig().guestUser, let password = GuestCredentials.password(for: bundle) else { return }
        sshKeyTasks[name] = Task {
            setActivity(name, Self.sshKeyTitle)
            defer {
                if !Task.isCancelled {
                    sshKeyTasks[name] = nil
                    if activity[name]?.title == Self.sshKeyTitle { setActivity(name, nil) }
                }
            }
            guard await startAfterInstall(name) else { return }
            openMachineWindow(name)
            let proxy = SSHConfig.proxyCommand(macvmPath: CLILocation.path, name: name, flags: ["--tcp"])
            do {
                try await GuestSSH.installPublicKey(bundle: bundle, user: user, password: password, proxyCommand: proxy, timeout: 900)
                // 主机名与时区没设上不影响装代理。
                do {
                    try await MacOSProvisioning.setHostNameAndTimeZone(bundle: bundle, config: bundle.loadConfig(), macvmPath: CLILocation.path)
                } catch where !Task.isCancelled {
                    report(error)
                }
                if AgentInstaller.binary(for: .macOS) != nil {
                    // 代理没装上不影响调优。
                    do {
                        _ = try await AgentInstaller.installAndEnable(bundle: bundle, config: bundle.loadConfig(), macvmPath: CLILocation.path)
                        configRevision += 1
                    } catch where !Task.isCancelled {
                        report(error)
                    }
                }
                if tune {
                    let failed = try await MacOSTuning.run(bundle: bundle, config: bundle.loadConfig(), macvmPath: CLILocation.path).failed
                    if !failed.isEmpty {
                        report(MacVMError.engine(String(l10n: "Couldn't apply these tuning steps in \(name): \(failed.map(\.rawValue).joinedAsList()). Run macvm tune \(name) in Terminal to try again")))
                    }
                }
            } catch where !Task.isCancelled {
                report(error)
            } catch {}
        }
    }

    private static let sshKeyTitle = String(l10n: "Starting for the first time to set up SSH and the guest agent…")

    /// 失败时报告错误并返回 false；任务取消时不报告。已在别的进程里运行（如 `ssh` 经 `macvm proxy` 把它拉了起来）
    /// 也算开了机：装公钥与代理都不必在本进程运行。
    private func startAfterInstall(_ name: String) async -> Bool {
        do {
            try await MacOSInstaller.firstBoot { _ = try await launch(name) }
            return true
        } catch MacVMError.alreadyRunning where !isRunningHere(name) {
            return true
        } catch {
            if !Task.isCancelled { report(error) }
            return false
        }
    }

    /// 取消正在进行的新建：终止下载与安装，删掉建了一半的包；已下载的部分留在下载目录里，下次新建接着用。
    func cancelCreation(_ name: String) {
        creationTasks[name]?.cancel()
        setActivity(name, String(l10n: "Canceling…"))
    }

    /// 已取消的任务里不能再等待，另起任务停机并删包。装 Windows 时虚拟机在运行，停下后锁才释放，删包要重试几次。
    private func cleanUpCancelled(_ request: CreationRequest) {
        Task {
            if let runner = runners[request.name] { try? await runner.forceStop() }
            for _ in 0..<20 {
                do {
                    try discardPartialBundle(of: request)
                    break
                } catch {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            refresh()
        }
    }

    /// 删掉中断时留下的半成品包，从头再做一遍；已下载的镜像在缓存里，下了一半的接着下。
    func resumeCreation(_ name: String, openMachineWindow: @escaping @MainActor (String) -> Void) {
        guard let request = interruptedCreations.first(where: { $0.name == name }) else { return }
        do { try discardPartialBundle(of: request) } catch {
            report(error)
            return
        }
        create(request, resumed: true, openMachineWindow: openMachineWindow)
    }

    /// 启动后接着做上次退出时没做完的新建；每个进程只做一次。继续失败的留在 `interruptedCreations` 里由用户处理。
    func resumeInterruptedCreations(openMachineWindow: @escaping @MainActor (String) -> Void) {
        guard !resumedAtLaunch else { return }
        resumedAtLaunch = true
        for request in interruptedCreations { resumeCreation(request.name, openMachineWindow: openMachineWindow) }
    }

    func discardCreation(_ name: String) {
        if let request = interruptedCreations.first(where: { $0.name == name }) {
            do { try discardPartialBundle(of: request) } catch { report(error) }
        }
        interruptedCreations.removeAll { $0.name == name }
        persistCreations()
        refresh()
    }

    /// 只删带着本请求令牌的同名包；名字被别处（如 CLI）建的虚拟机占着时不动它。
    private func discardPartialBundle(of request: CreationRequest) throws {
        let bundle = VMBundle(url: library.bundleURL(named: request.name))
        guard bundle.creationToken == request.id.uuidString else { return }
        try VMFactory.delete(bundle)
    }

    private func persistCreations() {
        do { try CreationStore.save(interruptedCreations + runningCreations.values.sorted { $0.name < $1.name }) } catch { report(error) }
    }

    private func perform(_ r: CreationRequest, openMachineWindow: @MainActor (String) -> Void) async throws {
        let name = r.name, token = r.id.uuidString
        let memory = UInt64(r.memoryGB) << 30, disk = UInt64(r.diskGB) << 30
        switch (r.os, r.source) {
        case (_, .template(let templateName)):
            setActivity(name, String(l10n: "Creating from template…"))
            let template = try templateLibrary.template(named: templateName)
            // 没调大到超过模板容量的整 GB 数时不扩。
            let currentGB = try ResourceRange.wholeGB(DiskImage.allocatedSize(at: template.diskURL).logical)
            _ = try await VMTemplate.instantiate(template, as: name, in: library, cpuCount: r.cpus, memorySize: memory,
                                                 diskSize: r.diskGB > currentGB ? disk : nil, creationToken: token)
        case (.macOS, _):
            let source: MacOSInstaller.Source
            if r.source == .ipswFile {
                guard let file = r.file else { throw MacVMError.invalidConfig(String(l10n: "No IPSW file selected")) }
                source = .file(file)
            } else {
                source = .latest
            }
            let options = MacOSInstaller.Options(name: name, source: source,
                                                 cpuCount: r.cpus, memorySize: memory, diskSize: disk, user: r.user ?? NSUserName(), password: r.password,
                                                 creationToken: token)
            _ = try await MacOSInstaller.install(options, in: library) { [weak self] phase in
                switch phase {
                case .downloading: self?.setActivity(name, String(l10n: "Downloading macOS…"), downloading: true)
                // 安装程序先校验、展开 IPSW，这几分钟进度一直是 0，显示为进度未知。
                case .installing(let f) where f <= 0: self?.setActivity(name, String(l10n: "Preparing to install. This takes a few minutes…"))
                case .installing(let f): self?.setActivity(name, String(l10n: "Installing \(Int(f * 100))%"), fraction: f)
                }
            }
        case (.windows, _):
            let iso: URL
            if r.source == .windowsLatest {
                setActivity(name, String(l10n: "Downloading Windows…"), downloading: true)
                iso = try await WindowsISO.iso(showProgress: false)
            } else {
                guard let file = r.file else { throw MacVMError.invalidConfig(String(l10n: "No Windows installation ISO selected")) }
                iso = file
            }
            setActivity(name, String(l10n: "Preparing the Windows installation disc…"))
            let bundle = try await WindowsInstaller.create(.init(name: name, iso: iso, cpuCount: r.cpus, memorySize: memory, diskSize: disk,
                                                                 user: r.user ?? NSUserName(), password: r.password, productKey: r.productKey,
                                                                 creationToken: token), in: library)
            setActivity(name, String(l10n: "Installing Windows…"))
            guard await start(name) != nil else { throw MacVMError.engine(String(l10n: "Couldn't start \(name) to begin installation")) }
            openMachineWindow(name)
            let finished = try await WindowsInstaller.completeSetup(bundle, macvmPath: CLILocation.path) {
                setActivity(name, String(l10n: "Finishing installation…"))
                await stop(name)
            } start: {
                guard await start(name) != nil else { throw MacVMError.engine(String(l10n: "Couldn't start \(name)")) }
            }
            guard finished else { throw MacVMError.timeout(String(l10n: "The guest didn't shut down after installing")) }
        case (_, .desktop(let id)):
            let desktop = try LinuxDesktop.named(id)
            setActivity(name, String(l10n: "Downloading the \(desktop.title) installation disc…"), downloading: true)
            let options = VMFactory.Options(name: name, os: .linux, cpuCount: r.cpus, memorySize: memory, diskSize: disk,
                                            rosetta: r.rosetta, desktop: desktop, unattended: r.manualInstall != true,
                                            user: r.user ?? NSUserName(), password: r.password, creationToken: token)
            let bundle = try await VMFactory.createEFIGuest(options, in: library)
            guard options.autoinstalls else {
                // 安装程序要在窗口里操作，打开窗口即开机。
                openMachineWindow(name)
                return
            }
            setActivity(name, String(l10n: "Installing \(desktop.title) automatically…"))
            guard await start(name) != nil else { throw MacVMError.engine(String(l10n: "Couldn't start \(name) to begin installation")) }
            openMachineWindow(name)
            try await UbuntuAutoinstall.completeSetup(bundle) {
                guard await start(name) != nil else { throw MacVMError.engine(String(l10n: "Couldn't start \(name)")) }
            }
        case (_, .cloudImage(let id)):
            setActivity(name, String(l10n: "Downloading image…"), downloading: true)
            let options = VMFactory.Options(name: name, os: .linux, cpuCount: r.cpus, memorySize: memory, diskSize: disk,
                                            rosetta: r.rosetta, image: try LinuxImage.named(id), user: r.user ?? NSUserName(), password: r.password,
                                            creationToken: token)
            _ = try await VMFactory.createEFIGuest(options, in: library)
        default:
            let options = VMFactory.Options(name: name, os: r.os, cpuCount: r.cpus, memorySize: memory, diskSize: disk,
                                            installMedia: r.file.map { [$0.path] } ?? [], rosetta: r.rosetta, creationToken: token)
            _ = try await VMFactory.createEFIGuest(options, in: library)
        }
    }

    func clone(_ name: String, as newName: String) async {
        do {
            try requireIdle(name)
            _ = try await VMClone.clone(library.bundle(named: name), as: newName)
        } catch { report(error) }
        refresh()
    }

    /// 创建、安装、存模板等任务进行中时包还没建完或正被复制，删除、克隆、改快照要等它结束。
    func requireIdle(_ name: String) throws {
        if let current = activity[name] { throw MacVMError.unsupported(String(l10n: "\(name) is busy: \(current.title)")) }
    }

    func report(_ error: any Error) {
        lastError = ReportedError(error)
    }
}

/// 报给用户的错误。
struct ReportedError: Equatable {
    let message: String

    init(_ error: any Error) {
        message = (error as? MacVMError)?.message ?? error.localizedDescription
    }
}
