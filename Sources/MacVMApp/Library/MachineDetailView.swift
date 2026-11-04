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

    var body: some View {
        let config = model.config(of: vm.name)
        Form {
            Section { header(config) }
            Section("硬件") {
                if let config, config.os != .macOS {
                    Picker("引擎", selection: Binding(get: { config.engine }, set: { model.setEngine(vm.name, to: $0) })) {
                        Text("VZ（占用低）").tag(Engine.vz)
                        Text("QEMU（声音、挂起）").tag(Engine.qemu)
                    }
                    .disabled(vm.state != .stopped || !config.installMedia.isEmpty)
                    if config.engine == .qemu {
                        Toggle("高分辨率（Retina）", isOn: Binding(get: { config.display.retina }, set: { model.setRetina(vm.name, $0) }))
                            .help("窗口里的分辨率按屏幕像素而不是点数，更清晰；Windows 同时把缩放比例调到相同倍数。运行中切换立即生效。")
                    }
                }
                LabeledContent("处理器", value: "\(vm.cpuCount) 核")
                LabeledContent("内存", value: DisplaySize.format(vm.memorySize))
                if let diskSize {
                    LabeledContent("磁盘") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(DisplaySize.format(diskSize.logical))
                            Text("已占用 \(DisplaySize.format(diskSize.physical))").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
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
            SnapshotsSection(vmName: vm.name, state: vm.state)
        }
        .formStyle(.grouped)
        .task(id: vm) { loadDiskSize(config) }
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
                HStack(spacing: 6) {
                    StateBadge(state: vm.state)
                    Text("·").foregroundStyle(.tertiary)
                    Text(model.activity[vm.name]?.text ?? vm.os.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

/// 状态圆点加文字；停止时圆点为灰色。
struct StateBadge: View {
    let state: VMSummary.State

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text(state.label).foregroundStyle(.secondary)
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
