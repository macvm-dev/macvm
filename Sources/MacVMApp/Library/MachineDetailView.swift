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

    private var config: VMConfig? { try? model.library.bundle(named: vm.name).loadConfig() }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: vm.os.symbol).font(.system(size: 36)).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(vm.name).font(.title2.bold())
                        Text("\(vm.os.label) · \(vm.state.label)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    controls
                }
            }
            Section("配置") {
                LabeledContent("CPU", value: "\(vm.cpuCount) 核")
                LabeledContent("内存", value: ByteSize.format(vm.memorySize))
                if let disk = config?.disks.first, let size = try? DiskImage.allocatedSize(at: model.library.bundleURL(named: vm.name).appending(path: disk.path)) {
                    LabeledContent("磁盘", value: "\(ByteSize.format(size.logical))（占用 \(ByteSize.format(size.physical))）")
                }
                if let ip = vm.ipAddress { LabeledContent("IP", value: ip).textSelection(.enabled) }
                if config?.guestUser != nil {
                    LabeledContent("SSH", value: "macvm ssh \(vm.name)").textSelection(.enabled)
                }
                LabeledContent("位置", value: vm.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            SnapshotsSection(vmName: vm.name, state: vm.state)
        }
        .formStyle(.grouped)
        .confirmationDialog("删除 \(vm.name)？磁盘与快照会一并删除。", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { model.delete(vm.name) }
        }
        .alert("克隆为", isPresented: $showingClone) {
            TextField("名称", text: $cloneName)
            Button("克隆") { Task { await model.clone(vm.name, as: cloneName) } }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder private var controls: some View {
        switch vm.state {
        case .stopped, .suspended:
            Button { openWindow(id: "machine", value: vm.name) } label: { Label(vm.state == .suspended ? "继续" : "启动", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(model.activity[vm.name] != nil)
            Menu {
                Button("克隆…") { cloneName = vm.name + "-copy"; showingClone = true }
                Divider()
                Button("删除…", role: .destructive) { confirmingDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        case .running:
            if model.isRunningHere(vm.name) {
                Button { openWindow(id: "machine", value: vm.name) } label: { Label("显示", systemImage: "macwindow") }
            }
            if config?.supportsSuspend == true {
                Button { Task { await model.suspend(vm.name) } } label: { Label("挂起", systemImage: "pause.fill") }
            }
            Menu {
                Button("关机") { Task { await model.stop(vm.name) } }
                Button("强制断电", role: .destructive) { Task { await model.stop(vm.name, force: true) } }
            } label: { Label("关机", systemImage: "power") }
                .fixedSize()
        }
    }
}
