import MacVMEngine
import MacVMModel
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.machines, id: \.name, selection: $model.selection) { vm in
                MachineRow(vm: vm, activity: model.activity[vm.name])
                    .tag(vm.name)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .overlay {
                if model.machines.isEmpty {
                    ContentUnavailableView("没有虚拟机", systemImage: "desktopcomputer", description: Text("点工具栏的 + 新建"))
                }
            }
        } detail: {
            if let name = model.selection, let vm = model.summary(name) {
                MachineDetailView(vm: vm)
            } else {
                ContentUnavailableView("选择一台虚拟机", systemImage: "sidebar.left")
            }
        }
        .toolbar {
            Button { model.showingCreate = true } label: { Label("新建", systemImage: "plus") }
        }
        .sheet(isPresented: $model.showingCreate) { CreateSheet() }
        .alert("操作失败", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("好") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct MachineRow: View {
    let vm: VMSummary
    let activity: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: vm.os.symbol)
                .font(.title2)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name).font(.headline)
                Text(activity ?? vm.state.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(vm.state.color).frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }
}

extension GuestOS {
    var symbol: String {
        switch self {
        case .macOS: "apple.logo"
        case .linux: "terminal"
        case .windows: "pc"
        }
    }

    var label: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .windows: "Windows"
        }
    }
}

extension VMSummary.State {
    var label: String {
        switch self {
        case .running: "运行中"
        case .stopped: "已停止"
        case .suspended: "已挂起"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .stopped: .secondary.opacity(0.4)
        case .suspended: .orange
        }
    }
}
