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
    @State private var user = ""
    @State private var password = ""
    @State private var revealsPassword = false
    @State private var manualInstall = false
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
                if setsPassword {
                    Section {
                        TextField("用户名", text: $user, prompt: Text(NSUserName()))
                        LabeledContent("密码") {
                            HStack(spacing: 6) {
                                let prompt = Text(source.isCloudImage ? "可选，留空则只能用 SSH 登录" : "可选，留空则随机生成")
                                if revealsPassword {
                                    TextField("密码", text: $password, prompt: prompt)
                                } else {
                                    SecureField("密码", text: $password, prompt: prompt)
                                }
                                Button { revealsPassword.toggle() } label: {
                                    Image(systemName: revealsPassword ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help(revealsPassword ? "隐藏密码" : "显示密码")
                            }
                            .labelsHidden()
                        }
                    } header: {
                        Text("账户")
                    } footer: {
                        let problem = accountProblem
                        Text(problem ?? "密码保存在虚拟机包内的 guest-password，只有你能读。")
                            .font(.caption).foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                }
                if os == .windows {
                    TextField("产品密钥", text: $productKey, prompt: Text("可选，装好后联网激活"))
                    Text(!hasQEMU
                         ? "安装 Windows 需要 QEMU：在终端运行 brew install qemu。"
                         : "自动下载时语言随系统首选语言。微软拒绝下载时（同一网络短时间内下载多次，或开着 VPN、代理时常见）可过几个小时再试，或改选本地 ISO，点「从微软下载…」在浏览器里下载（选好语言后点 Download），下载完成会自动选上。用 QEMU 无人值守部署（约 15 分钟，进度显示在打开的虚拟机窗口里），装好后可在虚拟机的「配置」里改用 VZ 引擎运行。")
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
                ForEach(LinuxDesktop.allCases, id: \.self) { Text("\($0.title)（下载安装盘）").tag(Source.desktop($0.rawValue)) }
                Text("安装 ISO…").tag(Source.iso)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let desktop {
                if desktop.supportsUnattended {
                    Picker("安装方式", selection: $manualInstall) {
                        Text("自动安装").tag(false)
                        Text("手动安装").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Text(desktop.supportsUnattended && !manualInstall
                     ? "离线无人值守安装，约 10 分钟；装好即带下方的账户、SSH 公钥与客户机代理，系统语言为英文，不含安装盘之后的更新。"
                     : "开机后在虚拟机窗口里走一遍图形安装程序，账户、语言等在安装程序里设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .macOS:
            Picker("", selection: $source) {
                Text("下载本机支持的最新版本").tag(Source.ipswLatest)
                Text("本地 IPSW 文件…").tag(Source.ipswFile)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        case .windows:
            Picker("", selection: $source) {
                Text("从微软下载 Windows 11 ARM64").tag(Source.windowsLatest)
                Text("本地 ISO 文件…").tag(Source.iso)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
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
        while !Task.isCancelled, file == nil, os == .windows, source == .iso {
            if let fresh = WindowsInstaller.downloadedISOs(modifiedAfter: since).first {
                file = fresh
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// 图形安装（Fedora 桌面版、ISO）的账户由安装程序设置。
    private var setsPassword: Bool {
        switch source {
        case .cloudImage: os == .linux
        case .desktop: desktop?.supportsUnattended == true && !manualInstall
        default: os == .macOS || os == .windows
        }
    }
    /// 用户名留空时用主机用户名，密码留空时按系统默认处理，都不另做检查。
    private var accountProblem: String? {
        do {
            if !user.isEmpty { try GuestAccount.validate(user: user) }
            if !password.isEmpty { try GuestAccount.validate(password: password) }
        } catch {
            return (error as? MacVMError)?.message ?? error.localizedDescription
        }
        return nil
    }
    /// 选中的桌面版。
    private var desktop: LinuxDesktop? {
        if os == .linux, case .desktop(let id) = source { try? LinuxDesktop.named(id) } else { nil }
    }
    private var needsFile: Bool { source == .iso || source == .ipswFile }
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
            && (!setsPassword || accountProblem == nil)
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
        case .windows: source = .windowsLatest
        }
    }

    private func create() {
        let request = CreationRequest(name: finalName, os: os, source: source, cpus: cpus, memoryGB: memoryGB, diskGB: diskGB,
                                      rosetta: rosetta, file: file, productKey: os == .windows && !productKey.isEmpty ? productKey : nil,
                                      user: setsPassword && !user.isEmpty ? user : nil,
                                      password: setsPassword && !password.isEmpty ? password : nil,
                                      manualInstall: desktop?.supportsUnattended == true && manualInstall ? true : nil)
        let openWindow = openWindow
        dismiss()
        model.create(request) { openWindow(id: "machine", value: $0) }
    }
}
