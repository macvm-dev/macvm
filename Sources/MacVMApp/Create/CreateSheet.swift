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
    @State private var tune = true
    /// 点了「从微软下载」的时刻；之后「下载」文件夹里出现的 Windows ISO 自动选上。
    @State private var downloadRequestedAt: Date?
    /// 输入框里的数字无效的 `NumberField`，按标题记。
    @State private var invalidFields: Set<String> = []
    /// 表单打开时探测一次，免得每敲一个字都去找一遍 QEMU。
    @State private var hasQEMU = QEMUInstallation.locate() != nil

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Operating System", selection: $os) {
                    ForEach(GuestOS.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(os == .windows && !WindowsSupport.isAvailable)

                TextField("Name", text: $name, prompt: Text(defaultName))
                if nameTaken {
                    Text("A virtual machine named “\(finalName)” already exists. Choose a different name.").font(.caption).foregroundStyle(.red)
                }

                Section("Source") { sourcePicker }

                Section("Resources") {
                    NumberField(title: "CPU", unit: cpus == 1 ? "core" : "cores", value: $cpus, invalid: invalid("cpu"), range: ResourceRange.cpuCount)
                    NumberField(title: "Memory", unit: "GB", value: $memoryGB, invalid: invalid("memory"), range: ResourceRange.memoryGB)
                    NumberField(title: "Disk", unit: "GB (uses space only as needed)", value: $diskGB, invalid: invalid("disk"), range: diskRange, step: 16)
                    if os == .linux, template == nil { Toggle("Rosetta (run x86_64 programs)", isOn: $rosetta) }
                    if tunesGuest {
                        Toggle("Reduce Idle Resource Usage", isOn: $tune)
                        Text("Turns off Spotlight indexing, system sleep, the screen saver, automatic updates, and window animations, and turns on Reduce Transparency and Reduce Motion in the guest. To undo this later, run macvm tune \(finalName) --revert in Terminal.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if setsPassword {
                    Section {
                        TextField("User Name", text: $user, prompt: Text(NSUserName()))
                        LabeledContent("Password") {
                            HStack(spacing: 6) {
                                let prompt = Text(source.isCloudImage ? "Optional. Without one, you can only sign in over SSH" : "Optional. Leave empty to generate one")
                                if revealsPassword {
                                    TextField("Password", text: $password, prompt: prompt)
                                } else {
                                    SecureField("Password", text: $password, prompt: prompt)
                                }
                                Button { revealsPassword.toggle() } label: {
                                    Image(systemName: revealsPassword ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help(revealsPassword ? "Hide Password" : "Show Password")
                            }
                            .labelsHidden()
                        }
                    } header: {
                        Text("Account")
                    } footer: {
                        let problem = accountProblem
                        Text(problem ?? String(l10n: "The password is saved to guest-password in the virtual machine bundle, which only you can read."))
                            .font(.caption).foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                }
                if os == .windows, template == nil {
                    TextField("Product Key", text: $productKey, prompt: Text("Optional. You can also activate online after installation"))
                    Text(!hasQEMU
                         ? "Installing Windows requires QEMU. To install it, run brew install qemu in Terminal."
                         : "Windows downloads in your preferred system language. If Microsoft blocks the download, which often happens after several downloads from the same network in a short time or over a VPN or proxy, try again in a few hours. You can also choose a local ISO and click Download from Microsoft… to download it in your browser (choose a language, then click Download); MacVM selects it when the download finishes. Windows then installs unattended with QEMU in about 15 minutes, with progress shown in the virtual machine window. Afterward, you can switch to the VZ engine in the virtual machine's settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520)
        .onChange(of: os) { _, os in resetDefaults(for: os) }
        .onChange(of: source) { _, _ in applyTemplateResources() }
        .onAppear { model.refreshTemplates() }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: allowedTypes) { result in
            file = try? result.get()
        }
    }

    @ViewBuilder private var sourcePicker: some View {
        switch os {
        case .linux:
            Picker("", selection: $source) {
                ForEach(LinuxImage.catalog, id: \.id) { Text("\($0.title) (cloud image, no install needed)").tag(Source.cloudImage($0.id)) }
                ForEach(LinuxDesktop.allCases, id: \.self) { Text("\($0.title) (download installer)").tag(Source.desktop($0.rawValue)) }
                Text("Installer ISO…").tag(Source.iso)
                templateOptions
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let desktop {
                if desktop.supportsUnattended {
                    Picker("Installation", selection: $manualInstall) {
                        Text("Automatic").tag(false)
                        Text("Manual").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Text(desktop.supportsUnattended && !manualInstall
                     ? "Installs offline and unattended in about 10 minutes, with the account below, your SSH public key, and the guest agent. The system language is English, and updates released after the installer aren't included."
                     : "After the virtual machine starts, use the graphical installer in its window to set up the account, language, and other options.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .macOS:
            Picker("", selection: $source) {
                Text("Download the latest version supported by this Mac").tag(Source.ipswLatest)
                Text("Local IPSW File…").tag(Source.ipswFile)
                templateOptions
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        case .windows:
            Picker("", selection: $source) {
                Text("Download Windows 11 ARM64 from Microsoft").tag(Source.windowsLatest)
                Text("Local ISO File…").tag(Source.iso)
                templateOptions
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        if template != nil {
            Text("Copies the template's disk, settings, and accounts. The new virtual machine gets a new machine identifier and MAC address. The disk can't be smaller than the template's.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if needsFile {
            HStack {
                Text(file?.lastPathComponent ?? (downloadRequestedAt != nil ? String(l10n: "Selected automatically when the download finishes…") : String(l10n: "No file selected")))
                    .foregroundStyle(file == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if os == .windows {
                    Button("Download from Microsoft…") {
                        downloadRequestedAt = .now
                        openURL(WindowsInstaller.downloadPage)
                    }
                }
                Button("Choose…") { choosingFile = true }
            }
            .task(id: downloadRequestedAt) { await watchDownloads() }
        }
    }

    @ViewBuilder private var templateOptions: some View {
        ForEach(model.templates.filter { $0.os == os }, id: \.name) { Text("Template: \($0.name)").tag(Source.template($0.name)) }
    }

    /// 选中的模板。
    private var template: TemplateSummary? { source.template.flatMap(model.template) }

    private var templateDiskGB: Int? { template?.diskSize.map(ResourceRange.wholeGB) }

    /// 模板磁盘可能已扩容到超过默认上限，这时上限跟着模板走。
    private var diskRange: ClosedRange<Int> {
        let lower = templateDiskGB.map { max(16, $0) } ?? 16
        return lower...max(lower, 2048)
    }

    /// 选了模板就把资源换成模板的配置。
    private func applyTemplateResources() {
        guard let template else { return }
        cpus = min(template.cpuCount, ResourceRange.cpuCount.upperBound)
        memoryGB = min(max(1, Int(template.memorySize >> 30)), ResourceRange.memoryGB.upperBound)
        if let templateDiskGB { diskGB = max(templateDiskGB, diskRange.lowerBound) }
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
        case .template: false
        case .cloudImage: os == .linux
        case .desktop: desktop?.supportsUnattended == true && !manualInstall
        default: os == .macOS || os == .windows
        }
    }
    /// 新装的 macOS 首次开机能自动开通时才连得上 SSH 去调优。
    private var tunesGuest: Bool { os == .macOS && template == nil && MacOSProvisioning.isSupported }
    /// 用户名留空时用主机用户名，它也要合规；密码留空时按系统默认处理，不另做检查。
    private var accountProblem: String? {
        if user.isEmpty, (try? GuestAccount.validate(user: NSUserName())) == nil {
            return String(l10n: "Your Mac user name, \(NSUserName()), can't be used in the guest. Enter a different user name")
        }
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
    /// 被中断的同名新建留下的半成品包不算占用：新请求会顶替它。
    private var nameTaken: Bool {
        model.summary(finalName) != nil && !model.interruptedCreations.contains { $0.name == finalName }
    }
    private func invalid(_ field: String) -> Binding<Bool> {
        Binding(get: { invalidFields.contains(field) },
                set: { if $0 { invalidFields.insert(field) } else { invalidFields.remove(field) } })
    }

    private var isValid: Bool {
        invalidFields.isEmpty && model.activity[finalName] == nil && !nameTaken
            && (try? VMLibrary.validate(name: finalName)) != nil && (!needsFile || file != nil)
            && (os != .windows || hasQEMU || template != nil)
            && (source.template == nil || template != nil)
            && (!setsPassword || accountProblem == nil)
            && (os != .windows || template != nil || productKey.isEmpty || (try? WindowsInstaller.normalizeProductKey(productKey)) != nil)
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
                                      rosetta: template == nil && rosetta, file: needsFile ? file : nil,
                                      productKey: os == .windows && template == nil && !productKey.isEmpty ? productKey : nil,
                                      user: setsPassword && !user.isEmpty ? user : nil,
                                      password: setsPassword && !password.isEmpty ? password : nil,
                                      manualInstall: desktop?.supportsUnattended == true && manualInstall ? true : nil,
                                      tune: tunesGuest && !tune ? false : nil)
        let openWindow = openWindow
        dismiss()
        model.create(request) { openWindow(id: "machine", value: $0) }
    }
}
