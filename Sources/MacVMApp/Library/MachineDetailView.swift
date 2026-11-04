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
    /// 磁盘镜像的容量与实际占用；读文件系统，不放在 body 里每次重绘都算。
    @State private var diskSize: (logical: UInt64, physical: UInt64)?
    @State private var growingDisk = false

    var body: some View {
        let config = model.config(of: vm.name)
        Form {
            Section { header(config) }
            Section {
                if let config, config.os != .macOS {
                    Picker("引擎", selection: Binding(get: { config.engine }, set: { model.setEngine(vm.name, to: $0) })) {
                        Text("VZ（占用低）").tag(Engine.vz)
                        Text("QEMU（声音、挂起）").tag(Engine.qemu)
                    }
                    .disabled(!editable || !config.installMedia.isEmpty)
                    if config.engine == .qemu {
                        Toggle("高分辨率（Retina）", isOn: Binding(get: { config.display.retina }, set: { model.setRetina(vm.name, $0) }))
                            .help("窗口里的分辨率按屏幕像素而不是点数，更清晰；Windows 同时把缩放比例调到相同倍数。运行中切换立即生效。")
                    }
                }
                if let config, editable {
                    NumberField(title: "处理器", unit: "核",
                                value: Binding(get: { config.cpuCount }, set: { model.setCPUCount(vm.name, $0) }),
                                invalid: .constant(false), range: ResourceRange.cpuCount)
                    NumberField(title: "内存", unit: "GB",
                                value: Binding(get: { Int(config.memorySize >> 30) }, set: { model.setMemory(vm.name, gigabytes: $0) }),
                                invalid: .constant(false), range: ResourceRange.memoryGB)
                } else {
                    LabeledContent("处理器", value: "\(vm.cpuCount) 核")
                    LabeledContent("内存", value: DisplaySize.format(vm.memorySize))
                }
                if let config, config.supportsAudio {
                    Toggle("声音", isOn: Binding(get: { config.audio }, set: { model.setAudio(vm.name, $0) }))
                        .disabled(!editable)
                }
                if let config, config.supportsMicrophone {
                    Toggle("麦克风", isOn: Binding(get: { config.microphone }, set: { model.setMicrophone(vm.name, $0) }))
                        .disabled(!editable)
                        .help("把主机麦克风接给客户机，开机时主机会请求麦克风权限")
                }
                if let diskSize {
                    LabeledContent("磁盘") {
                        HStack(spacing: 10) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(DisplaySize.format(diskSize.logical))
                                Text("已占用 \(DisplaySize.format(diskSize.physical))").font(.caption).foregroundStyle(.tertiary)
                            }
                            if editable, config != nil {
                                Button("扩容…") { growingDisk = true }.controlSize(.small)
                            }
                        }
                    }
                }
            } header: {
                Text("硬件")
            } footer: {
                if let lockedReason {
                    Text(lockedReason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("访问") {
                if let ip = vm.ipAddress {
                    CopyableRow(title: "IP 地址", value: ip)
                }
                if config?.guestUser != nil {
                    CopyableRow(title: "SSH", value: "macvm ssh \(vm.name)")
                }
                LabeledContent("位置") {
                    HStack(spacing: 6) {
                        Text((vm.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(vm.path)
                        Button { revealInFinder() } label: { Image(systemName: "arrow.right.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("在 Finder 中显示")
                    }
                }
            }
            if let config, config.supportsShares || !config.shares.isEmpty {
                SharesSection(vmName: vm.name, config: config, editable: editable || model.canEditSharesLive(vm.name))
            }
            SnapshotsSection(vmName: vm.name, state: vm.state)
        }
        .formStyle(.grouped)
        .task(id: vm) { loadDiskSize(config) }
        .sheet(isPresented: $growingDisk, onDismiss: { loadDiskSize(model.config(of: vm.name)) }) {
            if let config, let diskSize { DiskGrowSheet(vmName: vm.name, config: config, currentSize: diskSize.logical) }
        }
        .confirmationDialog("删除「\(vm.name)」？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { model.delete(vm.name) }
        } message: {
            Text("磁盘与快照会一并删除，无法撤销。")
        }
        .alert("克隆为", isPresented: $showingClone) {
            TextField("名称", text: $cloneName)
            Button("克隆") { Task { await model.clone(vm.name, as: cloneName) } }
            Button("取消", role: .cancel) {}
        }
    }

    /// 硬件与共享目录只在关机时可改，挂起或有进行中的任务（创建、安装）时也不行。
    private var editable: Bool { vm.state == .stopped && model.activity[vm.name] == nil }

    private var lockedReason: String? {
        switch vm.state {
        case .running: "关机后可修改处理器、内存、声音、麦克风与磁盘容量。"
        case .suspended: "已挂起：继续运行并关机后才能修改。"
        case .stopped: nil
        }
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
                Button("取消创建", role: .destructive) { model.cancelCreation(vm.name) }
            }
            switch vm.state {
            case .stopped, .suspended:
                Button { openWindow(id: "machine", value: vm.name) } label: {
                    Label(vm.state == .suspended ? "继续" : "启动", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.activity[vm.name] != nil)
            case .running:
                if model.canDisplay(vm.name) {
                    Button { openWindow(id: "machine", value: vm.name) } label: { Label("显示", systemImage: "macwindow") }
                        .buttonStyle(.borderedProminent)
                }
                if config?.supportsSuspend == true {
                    Button { Task { await model.suspend(vm.name) } } label: { Label("挂起", systemImage: "pause.fill") }
                }
                // 点按钮本身正常关机，下拉里才是强制断电。
                Menu {
                    Button("强制断电", role: .destructive) { Task { await model.stop(vm.name, force: true) } }
                } label: {
                    Label("关机", systemImage: "power")
                } primaryAction: {
                    Task { await model.stop(vm.name) }
                }
                .fixedSize()
            }
            Menu {
                Button("克隆…") { cloneName = vm.name + "-copy"; showingClone = true }
                    .disabled(vm.state == .running)
                Button("在 Finder 中显示") { revealInFinder() }
                Divider()
                Button("删除…", role: .destructive) { confirmingDelete = true }
                    .disabled(vm.state == .running)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
        }
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
    let title: String
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
                .help("复制")
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
