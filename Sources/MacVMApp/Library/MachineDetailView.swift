import AppKit
import MacVMEngine
import MacVMModel
import SwiftUI

struct MachineDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let vm: VMSummary
    @State private var confirmingDelete = false
    @State private var cloneName = ""
    @State private var showingClone = false
    @State private var templateName = ""
    @State private var showingSaveTemplate = false
    /// 磁盘镜像的容量与实际占用；读文件系统，不放在 body 里每次重绘都算。
    @State private var diskSize: (logical: UInt64, physical: UInt64)?
    @State private var growingDisk = false
    @State private var editingIPv4 = false
    /// 查系统网络配置，不放在 `@State` 的初始值里：视图结构体每次重建都会再算一遍初始值。
    @State private var bridgeInterfaces: [NetworkAttachments.BridgeInterface] = []

    @ViewBuilder
    private func guestUpdateRow(_ update: AppModel.GuestUpdateState) -> some View {
        switch update {
        case .available(let pending):
            LabeledContent("Guest") {
                HStack(spacing: 8) {
                    Text("Update available").foregroundStyle(.secondary)
                    Button("Update") { model.updateGuest(vm.name) }.controlSize(.small)
                }
            }
            .help(([String(l10n: "Doesn't match the version included with MacVM. Updating goes through the guest agent and includes:")] + (pending.agent ? [String(l10n: "· Guest agent (restarts once)")] : [])
                   + pending.changes.map { "· \($0)" }).joined(separator: "\n"))
        case .updating(let step):
            LabeledContent("Guest") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        case .rebootRequired:
            LabeledContent("Guest") {
                HStack(spacing: 8) {
                    Text("Restart to apply").foregroundStyle(.secondary)
                    Button("Restart") { model.rebootGuest(vm.name) }.controlSize(.small)
                }
            }
        }
    }

    var body: some View {
        let config = model.config(of: vm.name)
        Form {
            Section {
                header(config).background(OverlayScrollers())
            }
            Section {
                if let config, config.os != .macOS {
                    Picker("Engine", selection: Binding(get: { config.engine }, set: { model.setEngine(vm.name, to: $0) })) {
                        Text("VZ (lower overhead)").tag(Engine.vz)
                        Text("QEMU (sound, suspend)").tag(Engine.qemu)
                    }
                    .disabled(!editable || !config.installMedia.isEmpty)
                    if config.engine == .qemu || config.os == .linux {
                        Toggle("High Resolution (Retina)", isOn: Binding(get: { config.display.retina }, set: { model.setRetina(vm.name, $0) }))
                            .help(config.os == .windows
                                  ? "Uses screen pixels instead of points for the window resolution, for a sharper image. Windows adjusts its scaling to match. Takes effect right away, even while running."
                                  : config.guestAgent
                                  ? "Uses screen pixels instead of points for the window resolution, for a sharper image. The guest agent adjusts GNOME scaling to match. Takes effect right away, even while running."
                                  : "Uses screen pixels instead of points for the window resolution, for a sharper image. On a Retina display, everything looks half as big, so set scaling to 200% in the guest. Takes effect right away, even while running.")
                    }
                }
                if let config, editable {
                    NumberField(title: "Processors", unit: config.cpuCount == 1 ? "core" : "cores",
                                value: Binding(get: { config.cpuCount }, set: { model.setCPUCount(vm.name, $0) }),
                                invalid: .constant(false), range: ResourceRange.cpuCount)
                    NumberField(title: "Memory", unit: "GB",
                                value: Binding(get: { Int(config.memorySize >> 30) }, set: { model.setMemory(vm.name, gigabytes: $0) }),
                                invalid: .constant(false), range: ResourceRange.memoryGB)
                } else {
                    LabeledContent("Processors", value: String(l10n: "\(vm.cpuCount) cores"))
                    LabeledContent("Memory", value: DisplaySize.format(vm.memorySize))
                }
                if let config, let net = config.networks.first {
                    networkPicker(config, net)
                }
                if let config, config.supportsAudio {
                    Toggle("Sound", isOn: Binding(get: { config.audio }, set: { model.setAudio(vm.name, $0) }))
                        .disabled(!editable)
                }
                if let config, config.supportsMicrophone {
                    Toggle("Microphone", isOn: Binding(get: { config.microphone }, set: { model.setMicrophone(vm.name, $0) }))
                        .disabled(!editable)
                        .help("Connects your Mac's microphone to the guest. macOS asks for microphone permission when the virtual machine starts")
                }
                if let config {
                    Toggle("Sync Clipboard", isOn: Binding(get: { config.clipboard }, set: { model.setClipboard(vm.name, $0) }))
                        .disabled(config.clipboardChangeNeedsStop && !editable)
                        .help(config.os == .linux
                              ? "Shares copied text between the host and guest. Requires spice-vdagent in the guest and can only be changed while shut down. Any app in the guest can read what you copy on the host"
                              : "Shares copied text between the host and guest. The host clipboard goes to the guest when you click in the virtual machine window, and the guest clipboard comes back when you leave it. Any app in the guest can read what you copy on the host")
                }
                if let config {
                    Toggle("Lock Screen When Idle", isOn: Binding(get: { config.screenLock }, set: { model.setScreenLock(vm.name, $0) }))
                        .disabled(!config.guestAgent)
                        .help(config.guestAgent
                              ? "Locks the guest screen when it's idle and the display sleeps, so a password is needed to get back in. When off, the guest never locks. Takes effect right away, even while running"
                              : "Requires the guest agent")
                }
                if let diskSize {
                    LabeledContent("Disk") {
                        HStack(spacing: 10) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(DisplaySize.format(diskSize.logical))
                                Text("\(DisplaySize.format(diskSize.physical)) used").font(.caption).foregroundStyle(.tertiary)
                            }
                            if editable, config != nil {
                                Button("Resize…") { growingDisk = true }.controlSize(.small)
                            }
                        }
                    }
                }
            } header: {
                Text("Hardware")
            } footer: {
                if let lockedReason {
                    Text(lockedReason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Access") {
                if let ip = vm.ipAddress {
                    CopyableRow(title: "IP Address", value: ip)
                }
                if config?.guestUser != nil {
                    CopyableRow(title: "SSH", value: model.sshCommand(vm.name))
                }
                if let update = model.guestUpdates[vm.name] {
                    guestUpdateRow(update)
                }
                LabeledContent("Location") {
                    HStack(spacing: 6) {
                        Text((vm.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(vm.path)
                        Button { revealInFinder() } label: { Image(systemName: "arrow.right.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Show in Finder")
                    }
                }
            }
            if let config, config.supportsShares || !config.shares.isEmpty {
                SharesSection(vmName: vm.name, config: config, editable: editable || model.canEditSharesLive(vm.name))
            }
            if let config {
                ForwardsSection(vmName: vm.name, config: config)
            }
            SnapshotsSection(vmName: vm.name, state: vm.state, busy: busy)
        }
        .formStyle(.grouped)
        .acceptsShareDrops(vmName: vm.name, editable: config?.supportsShares == true && (editable || model.canEditSharesLive(vm.name)))
        .task(id: vm) { loadDiskSize(config) }
        .task { bridgeInterfaces = NetworkAttachments.bridgeInterfaces }
        .onAppear { model.refreshSSHIncluded() }
        .sheet(isPresented: $growingDisk, onDismiss: { loadDiskSize(model.config(of: vm.name)) }) {
            if let config, let diskSize { DiskGrowSheet(vmName: vm.name, config: config, currentSize: diskSize.logical) }
        }
        .sheet(isPresented: $editingIPv4) {
            if let config, let net = config.networks.first { StaticIPv4Sheet(vmName: vm.name, os: config.os, current: net.staticIPv4) }
        }
        .confirmationDialog("Delete “\(vm.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.delete(vm.name) }
        } message: {
            Text("Its disks and snapshots will also be deleted. This can't be undone.")
        }
        .alert("Clone As", isPresented: $showingClone) {
            TextField("Name", text: $cloneName)
            Button("Clone") { Task { await model.clone(vm.name, as: cloneName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Save as Template", isPresented: $showingSaveTemplate) {
            TextField("Template Name", text: $templateName)
            Button("Save as Template") { Task { await model.saveTemplate(vm.name, as: templateName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Snapshots aren't included in the template. You can create new virtual machines from it.")
        }
    }

    /// 硬件与共享目录只在关机时可改，挂起或有进行中的任务（创建、安装）时也不行。
    private var editable: Bool { vm.state == .stopped && !busy }

    /// 有进行中的任务（创建、安装、存模板）。
    private var busy: Bool { model.activity[vm.name] != nil }

    private var lockedReason: String? {
        switch vm.state {
        case .running: String(l10n: "Shut down to change processors, memory, network mode, sound, microphone, and disk size.")
        case .suspended: String(l10n: "Suspended. To make changes, resume it and then shut it down.")
        case .stopped: nil
        }
    }

    /// 只改第一块网卡。选项按本机当前可桥接的网卡列出；配置里的网卡不在其中（如拔掉的扩展坞网口）时也列出，免得选择变成空白。
    /// 不能桥接时只列 NAT 与当前的桥接项，当前是桥接时仍可操作，好切回 NAT。
    private func networkPicker(_ config: VMConfig, _ net: NetworkConfig) -> some View {
        let current = net.mode == .bridged ? NetworkChoice.bridged(net.interface ?? "") : .nat
        let reason = bridgeUnavailableReason(config)
        var interfaces = reason == nil ? bridgeInterfaces.map(\.identifier) : []
        if case .bridged(let id) = current, !interfaces.contains(id) { interfaces.append(id) }
        var notes: [String] = []
        if case .bridged(let id) = current {
            if !config.guestAgent {
                notes.append(String(l10n: "Without the guest agent, MacVM can't find the guest's IP address on a bridged network, so SSH and port forwarding won't work."))
            }
            if bridgeInterfaces.first(where: { $0.identifier == id })?.isWiFi == true {
                notes.append(String(l10n: "On Wi-Fi, this Mac and the guest may not be able to reach each other directly. Features that go through the guest agent still work. Use a wired connection if you can."))
            }
            if net.staticIPv4 != nil {
                notes.append(String(l10n: "If you switch to NAT, the guest goes back to DHCP the next time it starts."))
            }
        }
        return Group {
            Picker("Network", selection: Binding(get: { current }, set: { choice in
                switch choice {
                case .nat: model.setNetwork(vm.name, .nat, interface: nil)
                case .bridged(let id): model.setNetwork(vm.name, .bridged, interface: id)
                }
            })) {
                Text("NAT").tag(NetworkChoice.nat)
                ForEach(interfaces, id: \.self) { Text(bridgeLabel($0)).tag(NetworkChoice.bridged($0)) }
            }
            .disabled(!editable || (reason != nil && current == .nat))
            .help(reason ?? String(l10n: "Bridged networking puts the guest directly on your Mac's local network, where it gets its own address from the router. You can also give it a fixed address."))
            if case .bridged = current {
                // 运行中也可改，不受 `editable` 限制。
                LabeledContent("Configure IPv4") {
                    HStack(spacing: 10) {
                        if let fixed = net.staticIPv4 { Text(verbatim: fixed.cidr) } else { Text("DHCP") }
                        Button("Edit…") { editingIPv4 = true }
                            .controlSize(.small)
                            .disabled(!config.guestAgent || busy)
                    }
                }
                .help(config.guestAgent ? "Use an address from the router (DHCP) or a fixed address. Takes effect right away, even while running" : "Requires the guest agent")
            }
            if !notes.isEmpty {
                Text(notes.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 不能选桥接的原因，按优先级取第一条；能桥接时为 nil。
    private func bridgeUnavailableReason(_ config: VMConfig) -> String? {
        if config.engine == .qemu { return String(l10n: "The QEMU engine doesn't support bridged networking") }
        if config.os == .windows { return String(l10n: "Windows guests don't support bridged networking") }
        if !NetworkAttachments.canBridge { return String(l10n: "This build of MacVM isn't signed for bridged networking") }
        if bridgeInterfaces.isEmpty { return String(l10n: "This Mac has no bridgeable network interface") }
        return nil
    }

    private func bridgeLabel(_ identifier: String) -> String {
        if let interface = bridgeInterfaces.first(where: { $0.identifier == identifier }) {
            String(l10n: "Bridged: \(interface.name) (\(interface.identifier))")
        } else {
            String(l10n: "Bridged: \(identifier)")
        }
    }

    private enum NetworkChoice: Hashable {
        case nat
        case bridged(String)
    }

    private func header(_ config: VMConfig?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: vm.os.symbol)
                .font(.system(size: 26, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.name).font(.title2.weight(.semibold)).lineLimit(1)
                StatusLine(state: vm.state, os: vm.os, activity: model.activity[vm.name])
                    .font(.callout)
            }
            Spacer(minLength: 12)
            controls(config)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func controls(_ config: VMConfig?) -> some View {
        HStack(spacing: 8) {
            if model.isCreating(vm.name) {
                Button("Cancel Creation", role: .destructive) { model.cancelCreation(vm.name) }
            }
            switch vm.state {
            case .stopped, .suspended:
                Button { openWindow(id: "machine", value: vm.name) } label: {
                    Label(vm.state == .suspended ? "Resume" : "Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.activity[vm.name] != nil)
            case .running:
                // 显示不了画面时按钮照样在：窗口里说明虚拟机在别的进程运行、关机后才能在这里打开。
                Button { openWindow(id: "machine", value: vm.name) } label: { Label("Show", systemImage: "macwindow") }
                    .buttonStyle(.borderedProminent)
                    .help(model.canDisplay(vm.name) ? "Show Display" : "Running in a background process. Only that process can show a VZ virtual machine's screen; shut it down and start it here to see it")
                if model.canSuspend(vm.name) {
                    Button { Task { await model.suspend(vm.name) } } label: { Label("Suspend", systemImage: "pause.fill") }
                }
                // 点按钮本身正常关机，下拉里才是强制断电。
                Menu {
                    Button("Force Power Off", role: .destructive) { Task { await model.stop(vm.name, force: true) } }
                } label: {
                    Label("Shut Down", systemImage: "power")
                } primaryAction: {
                    Task { await model.stop(vm.name) }
                }
                .fixedSize()
            }
            Menu {
                Button("Clone…") { cloneName = vm.name + "-copy"; showingClone = true }
                    .disabled(vm.state == .running || busy)
                Button("Save as Template…") { templateName = vm.name; showingSaveTemplate = true }
                    .disabled(!editable)
                Button("Show in Finder") { revealInFinder() }
                Divider()
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(vm.state == .running || busy)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Actions")
        }
        // 按钮按理想宽度排，空间不够时由左侧的名字截断。
        .fixedSize()
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: vm.path)])
    }

    private func loadDiskSize(_ config: VMConfig?) {
        diskSize = config?.disks.first.flatMap { disk in
            try? DiskImage.allocatedSize(at: model.library.bundleURL(named: vm.name).appending(path: disk.path))
        }.map { ($0.logical, $0.physical) }
    }
}

/// 状态圆点、状态文字，后接进行中任务的进度，没有任务时接系统名。
/// 进度只在这里读，进度更新时不重算整个详情页。
struct StatusLine: View {
    let state: VMSummary.State
    let os: GuestOS
    let activity: AppModel.Activity?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text(state.label).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text(activity?.text ?? os.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// 等宽显示、可选中，悬停时出现复制按钮。
struct CopyableRow: View {
    let title: LocalizedStringKey
    let value: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value).font(.body.monospaced()).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering || copied ? 1 : 0)
                .help("Copy")
            }
        }
        .onHover { hovering = $0 }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
