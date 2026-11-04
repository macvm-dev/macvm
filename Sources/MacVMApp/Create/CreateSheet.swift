import MacVMEngine
import MacVMModel
import SwiftUI
import UniformTypeIdentifiers

struct CreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    typealias Source = CreationRequest.Source

    @State private var os: GuestOS = .linux
    @State private var source: Source = .cloudImage(LinuxImage.catalog[0].id)
    @State private var name = ""
    @State private var cpus = HostInfo.defaultCPUCount()
    @State private var memoryGB = Int(HostInfo.defaultMemorySize() >> 30)
    @State private var diskGB = 64
    @State private var file: URL?
    @State private var choosingFile = false
    @State private var rosetta = false
    @State private var productKey = ""
    /// 点了「从微软下载」的时刻；之后「下载」文件夹里出现的 Windows ISO 自动选上。
    @State private var downloadRequestedAt: Date?
    /// 输入框里的数字无效的 `NumberField`，按标题记。
    @State private var invalidFields: Set<String> = []
    /// 表单打开时探测一次，免得每敲一个字都去找一遍 QEMU。
    @State private var hasQEMU = QEMUInstallation.locate() != nil

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
                    NumberField(title: "CPU", unit: "核", value: $cpus, invalid: invalid("CPU"), range: ResourceRange.cpuCount)
                    NumberField(title: "内存", unit: "GB", value: $memoryGB, invalid: invalid("内存"), range: ResourceRange.memoryGB)
                    NumberField(title: "磁盘", unit: "GB（按实际写入占用）", value: $diskGB, invalid: invalid("磁盘"), range: 16...2048, step: 16)
                    if os == .linux { Toggle("Rosetta（运行 x86_64 程序）", isOn: $rosetta) }
                }
                if os == .windows {
                    TextField("产品密钥", text: $productKey, prompt: Text("可选，装好后联网激活"))
                    Text(!hasQEMU
                         ? "安装 Windows 需要 QEMU：在终端运行 brew install qemu。"
                         : "选择 Windows 11 ARM64 安装 ISO，或点「从微软下载」在浏览器里下载（选好语言后点 Download），下载完成会自动选上。用 QEMU 无人值守部署（约 15 分钟，进度显示在打开的虚拟机窗口里），装好后可在虚拟机的「配置」里改用 VZ 引擎运行。")
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
                ForEach(LinuxDesktop.allCases, id: \.self) { Text("\($0.title)（下载安装盘，在窗口里图形安装）").tag(Source.desktop($0.rawValue)) }
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
                Text(file?.lastPathComponent ?? (downloadRequestedAt != nil ? "下载完成后自动选上…" : "未选择文件"))
                    .foregroundStyle(file == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if os == .windows {
                    Button("从微软下载…") {
                        downloadRequestedAt = .now
                        openURL(WindowsInstaller.downloadPage)
                    }
                }
                Button("选择…") { choosingFile = true }
            }
            .task(id: downloadRequestedAt) { await watchDownloads() }
        }
    }

    /// 等浏览器把 Windows ISO 下载完；用户自己选了文件或换了系统就不再等。
    private func watchDownloads() async {
        guard let since = downloadRequestedAt else { return }
        while !Task.isCancelled, file == nil, os == .windows {
            if let fresh = WindowsInstaller.downloadedISOs(modifiedAfter: since).first {
                file = fresh
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private var needsFile: Bool { source == .iso || source == .ipswFile || os == .windows }
    private var allowedTypes: [UTType] { [UTType(filenameExtension: os == .macOS ? "ipsw" : "iso") ?? .data] }
    private var defaultName: String { os == .macOS ? "macos" : os == .windows ? "windows" : "linux" }
    private var finalName: String { name.isEmpty ? defaultName : name }
    private func invalid(_ field: String) -> Binding<Bool> {
        Binding(get: { invalidFields.contains(field) },
                set: { if $0 { invalidFields.insert(field) } else { invalidFields.remove(field) } })
    }

    private var isValid: Bool {
        invalidFields.isEmpty && model.activity[finalName] == nil && (try? VMLibrary.validate(name: finalName)) != nil && (!needsFile || file != nil)
            && (os != .windows || hasQEMU)
            && (os != .windows || productKey.isEmpty || (try? WindowsInstaller.normalizeProductKey(productKey)) != nil)
    }

    private func resetDefaults(for os: GuestOS) {
        file = nil
        downloadRequestedAt = nil
        memoryGB = Int(HostInfo.defaultMemorySize() >> 30)
        diskGB = Int(HostInfo.defaultDiskSize(for: os) >> 30)
        switch os {
        case .linux: source = .cloudImage(LinuxImage.catalog[0].id)
        case .macOS: source = .ipswLatest
        case .windows: source = .iso
        }
    }

    private func create() {
        let request = CreationRequest(name: finalName, os: os, source: source, cpus: cpus, memoryGB: memoryGB, diskGB: diskGB,
                                      rosetta: rosetta, file: file, productKey: os == .windows && !productKey.isEmpty ? productKey : nil)
        let openWindow = openWindow
        dismiss()
        model.create(request) { openWindow(id: "machine", value: $0) }
    }
}
