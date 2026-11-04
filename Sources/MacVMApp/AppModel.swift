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
    /// 新建后首次开机装 SSH 公钥的任务，键为虚拟机名；虚拟机停下时取消。
    @ObservationIgnored private var sshKeyTasks: [String: Task<Void, Never>] = [:]

    private(set) var runners: [String: any MachineRunner] = [:]
    /// 经本模型改过配置就加一；`config(of:)` 读它，好让展示配置的视图在改动后重绘。
    private var configRevision = 0
    private var servers: [String: ControlServer] = [:]
    private var refreshTask: Task<Void, Never>?
    /// 每次同步 `refresh` 加一；后台轮询读完时它变了，说明结果已比同步刷新的旧，丢弃。
    private var refreshGeneration = 0
    private(set) var library = VMLibrary.default
    private(set) var settings = MacVMSettings.load()

    init() {
        refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let (generation, library) = self.map({ ($0.refreshGeneration, $0.library) }) else { return }
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
        for vm in list where vm.state != .running { clearStopping(vm.name) }
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
    /// VZ 的画面只能在运行它的进程里显示。
    func canDisplay(_ name: String) -> Bool {
        isRunningHere(name) || config(of: name)?.engine == .qemu
    }

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
            if !force { showStopping(name) }
        } catch { report(error) }
        refresh()
    }

    /// 正常关机要等客户机自己关，期间状态显示「正在关机」；停下或等满 `stoppingTimeout` 后撤掉。
    /// 已有进行中的任务（如安装）时不覆盖它的进度。
    private func showStopping(_ name: String) {
        guard activity[name] == nil else { return }
        setActivity(name, Self.stoppingTitle)
        Task { [weak self] in
            try? await Task.sleep(for: Self.stoppingTimeout)
            self?.clearStopping(name)
        }
    }

    private func clearStopping(_ name: String) {
        if isStopping(name) { setActivity(name, nil) }
    }

    private static let stoppingTitle = "正在关机…"
    private static let stoppingTimeout: Duration = .seconds(90)

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
        if let task = sshKeyTasks.removeValue(forKey: name) {
            task.cancel()
            // 进行中的那次 ssh 要等它自己超时才返回，提示先撤掉，免得停下的虚拟机一直显示在配置。
            if activity[name]?.title == Self.sshKeyTitle { setActivity(name, nil) }
        }
        servers[name]?.close()
        servers[name] = nil
        runners[name] = nil
        attachedImages[name] = nil
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

    // MARK: - 新建

    /// 在后台按 `request` 新建；需要用户在窗口里操作时（装 Windows、图形安装）调用 `openMachineWindow`。
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
        setActivity(name, "正在创建…")
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
                if request.os == .macOS { installSSHKeyOnFirstBoot(name, openMachineWindow: openMachineWindow) }
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

    /// 本进程里正在新建的虚拟机的客户机系统。
    func creatingOS(_ name: String) -> GuestOS? { runningCreations[name]?.os }

    /// 新建的 macOS 虚拟机首次开机，等远程登录可用后用密码登录一次装入 macvm 公钥，之后 SSH 都走密钥。
    /// 不会自动开通时不开机：用户要先在窗口里走完设置助理。失败只报告，不影响虚拟机本身。
    private func installSSHKeyOnFirstBoot(_ name: String, openMachineWindow: @escaping @MainActor (String) -> Void) {
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
            guard await start(name) != nil else { return }
            openMachineWindow(name)
            let proxy = SSHConfig.proxyCommand(macvmPath: CLILocation.path, name: name, flags: ["--tcp"])
            do {
                try await GuestSSH.installPublicKey(bundle: bundle, user: user, password: password, proxyCommand: proxy, timeout: 900)
            } catch where !Task.isCancelled {
                report(error)
            } catch {}
        }
    }

    private static let sshKeyTitle = "正在首次开机并配置 SSH…"

    /// 取消正在进行的新建：终止下载与安装，删掉建了一半的包；已下载的部分留在下载目录里，下次新建接着用。
    func cancelCreation(_ name: String) {
        creationTasks[name]?.cancel()
        setActivity(name, "正在取消…")
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
        case (.macOS, _):
            let options = MacOSInstaller.Options(name: name, source: r.file.map { .file($0) } ?? .latest,
                                                 cpuCount: r.cpus, memorySize: memory, diskSize: disk, user: r.user ?? NSUserName(), password: r.password,
                                                 creationToken: token)
            _ = try await MacOSInstaller.install(options, in: library) { [weak self] phase in
                switch phase {
                case .downloading: self?.setActivity(name, "正在下载 macOS…", downloading: true)
                // 安装程序先校验、展开 IPSW，这几分钟进度一直是 0，显示为进度未知。
                case .installing(let f) where f <= 0: self?.setActivity(name, "正在准备安装，需要几分钟…")
                case .installing(let f): self?.setActivity(name, "正在安装 \(Int(f * 100))%", fraction: f)
                }
            }
        case (.windows, _):
            let iso: URL
            if r.source == .windowsLatest {
                setActivity(name, "正在下载 Windows…", downloading: true)
                iso = try await WindowsISO.iso(showProgress: false)
            } else {
                guard let file = r.file else { throw MacVMError.invalidConfig("没有选择 Windows 安装 ISO") }
                iso = file
            }
            setActivity(name, "正在准备 Windows 安装盘…")
            let bundle = try await WindowsInstaller.create(.init(name: name, iso: iso, cpuCount: r.cpus, memorySize: memory, diskSize: disk,
                                                                 user: r.user ?? NSUserName(), password: r.password, productKey: r.productKey,
                                                                 creationToken: token), in: library)
            setActivity(name, "正在安装 Windows…")
            guard await start(name) != nil else { throw MacVMError.engine("无法启动 \(name) 开始安装") }
            openMachineWindow(name)
            let finished = try await WindowsInstaller.completeSetup(bundle, macvmPath: CLILocation.path) {
                setActivity(name, "正在完成安装…")
                await stop(name)
            }
            guard finished else { throw MacVMError.timeout("安装完成后客户机未关机") }
        case (_, .desktop(let id)):
            let desktop = try LinuxDesktop.named(id)
            setActivity(name, "正在下载 \(desktop.title) 安装盘…", downloading: true)
            let options = VMFactory.Options(name: name, os: .linux, cpuCount: r.cpus, memorySize: memory, diskSize: disk,
                                            rosetta: r.rosetta, desktop: desktop, unattended: r.manualInstall != true,
                                            user: r.user ?? NSUserName(), password: r.password, creationToken: token)
            let bundle = try await VMFactory.createEFIGuest(options, in: library)
            guard options.autoinstalls else {
                // 安装程序要在窗口里操作，打开窗口即开机。
                openMachineWindow(name)
                return
            }
            setActivity(name, "正在自动安装 \(desktop.title)…")
            guard await start(name) != nil else { throw MacVMError.engine("无法启动 \(name) 开始安装") }
            openMachineWindow(name)
            try await UbuntuAutoinstall.completeSetup(bundle) {
                guard await start(name) != nil else { throw MacVMError.engine("无法启动 \(name)") }
            }
        case (_, .cloudImage(let id)):
            setActivity(name, "正在下载镜像…", downloading: true)
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
        do { _ = try await VMClone.clone(library.bundle(named: name), as: newName) } catch { report(error) }
        refresh()
    }

    func report(_ error: any Error) {
        lastError = (error as? MacVMError)?.message ?? error.localizedDescription
    }
}
