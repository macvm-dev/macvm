import MacVMEngine
import MacVMModel
import SwiftUI
import UniformTypeIdentifiers

struct CreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Source: Hashable { case cloudImage(String), iso, ipswLatest, ipswFile }

    @State private var os: GuestOS = .linux
    @State private var source: Source = .cloudImage(LinuxImage.catalog[0].id)
    @State private var name = ""
    @State private var cpus = HostInfo.defaultCPUCount()
    @State private var memoryGB = 4
    @State private var diskGB = 64
    @State private var file: URL?
    @State private var choosingFile = false
    @State private var rosetta = false

    private let maxMemoryGB = Int(HostInfo.physicalMemory >> 30)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("系统", selection: $os) {
                    ForEach(GuestOS.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(os == .windows && !WindowsSupport.isAvailable)

                TextField("名称", text: $name, prompt: Text(defaultName))

                Section("来源") { sourcePicker }

                Section("资源") {
                    Stepper("CPU：\(cpus) 核", value: $cpus, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                    Stepper("内存：\(memoryGB) GB", value: $memoryGB, in: 1...max(1, maxMemoryGB / 2 * 2))
                    Stepper("磁盘：\(diskGB) GB（按实际写入占用）", value: $diskGB, in: 16...2048, step: 16)
                    if os == .linux { Toggle("Rosetta（运行 x86_64 程序）", isOn: $rosetta) }
                }
                if os == .windows {
                    Text(QEMUInstallation.locate() == nil
                         ? "安装 Windows 需要 QEMU：在终端运行 brew install qemu。"
                         : "选择 Windows 11 ARM64 安装 ISO。用 QEMU 无人值守部署（约 15 分钟，会弹出 QEMU 窗口显示进度），装好后可在虚拟机的「配置」里改用 VZ 引擎运行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("创建") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520)
        .onChange(of: os) { _, os in resetDefaults(for: os) }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: allowedTypes) { result in
            file = try? result.get()
        }
    }

    @ViewBuilder private var sourcePicker: some View {
        switch os {
        case .linux:
            Picker("", selection: $source) {
                ForEach(LinuxImage.catalog, id: \.id) { Text("\($0.title)（云镜像，免安装）").tag(Source.cloudImage($0.id)) }
                Text("安装 ISO…").tag(Source.iso)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        case .macOS:
            Picker("", selection: $source) {
                Text("下载本机支持的最新版本").tag(Source.ipswLatest)
                Text("本地 IPSW 文件…").tag(Source.ipswFile)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        case .windows:
            EmptyView()
        }
        if needsFile {
            HStack {
                Text(file?.lastPathComponent ?? "未选择文件").foregroundStyle(file == nil ? .secondary : .primary)
                Spacer()
                Button("选择…") { choosingFile = true }
            }
        }
    }

    private var needsFile: Bool { source == .iso || source == .ipswFile || os == .windows }
    private var allowedTypes: [UTType] { [UTType(filenameExtension: os == .macOS ? "ipsw" : "iso") ?? .data] }
    private var defaultName: String { os == .macOS ? "macos" : os == .windows ? "windows" : "linux" }
    private var finalName: String { name.isEmpty ? defaultName : name }
    private var isValid: Bool {
        (try? VMLibrary.validate(name: finalName)) != nil && (!needsFile || file != nil)
            && (os != .windows || QEMUInstallation.locate() != nil)
    }

    private func resetDefaults(for os: GuestOS) {
        file = nil
        memoryGB = Int(HostInfo.defaultMemorySize(for: os) >> 30)
        diskGB = Int(HostInfo.defaultDiskSize(for: os) >> 30)
        switch os {
        case .linux: source = .cloudImage(LinuxImage.catalog[0].id)
        case .macOS: source = .ipswLatest
        case .windows: source = .iso
        }
    }

    private func create() {
        let name = finalName
        let os = os, source = source, file = file
        let cpus = cpus, memory = UInt64(memoryGB) << 30, disk = UInt64(diskGB) << 30, rosetta = rosetta
        dismiss()
        Task { @MainActor in
            model.activity[name] = "正在创建…"
            defer { model.activity[name] = nil; model.refresh() }
            do {
                switch (os, source) {
                case (.macOS, _):
                    let options = MacOSInstaller.Options(name: name, source: file.map { .file($0) } ?? .latest,
                                                         cpuCount: cpus, memorySize: memory, diskSize: disk)
                    _ = try await MacOSInstaller.install(options, in: model.library) { phase in
                        switch phase {
                        case .downloading: model.activity[name] = "正在下载 macOS…"
                        case .installing(let f): model.activity[name] = "正在安装 \(Int(f * 100))%"
                        }
                    }
                case (.windows, _):
                    guard let iso = file else { return }
                    model.activity[name] = "正在准备 Windows 安装盘…"
                    let bundle = try await WindowsInstaller.create(.init(name: name, iso: iso, cpuCount: cpus, memorySize: memory, diskSize: disk),
                                                                   in: model.library)
                    model.activity[name] = "正在安装 Windows…"
                    guard await model.start(name) != nil else { return }
                    try await WindowsInstaller.waitUntilSetupComplete(bundle, proxyCommand: "\"\(CLILocation.path)\" proxy \(name) --timeout 10")
                    model.activity[name] = "正在完成安装…"
                    await model.stop(name)
                    _ = try await VMStatus.poll(timeout: 180) { BundleLock.holder(of: bundle) == nil }
                    try WindowsInstaller.finishSetup(bundle)
                case (_, .cloudImage(let id)):
                    model.activity[name] = "正在下载镜像…"
                    let options = VMFactory.Options(name: name, os: .linux, cpuCount: cpus, memorySize: memory, diskSize: disk,
                                                    rosetta: rosetta, image: try LinuxImage.named(id))
                    _ = try await VMFactory.createEFIGuest(options, in: model.library)
                default:
                    let options = VMFactory.Options(name: name, os: os, cpuCount: cpus, memorySize: memory, diskSize: disk,
                                                    installMedia: file.map { [$0.path] } ?? [], rosetta: rosetta)
                    _ = try await VMFactory.createEFIGuest(options, in: model.library)
                }
                SSHConfig.refreshIfInstalled(library: model.library, macvmPath: CLILocation.path)
                model.selection = name
            } catch {
                model.report(error)
            }
        }
    }
}
