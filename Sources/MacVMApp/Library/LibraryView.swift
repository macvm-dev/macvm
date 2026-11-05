import AppKit
import MacVMEngine
import MacVMModel
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        // 没有虚拟机时不用分栏，引导页占满窗口；侧栏的展开收起完全交给系统，不用代码控制。
        Group {
            if isEmpty { emptyLibrary } else { library }
        }
        .navigationSubtitle(subtitle)
        .task { model.resumeInterruptedCreations { openWindow(id: "machine", value: $0) } }
        // 列表增删后选中项可能已不存在，落到第一行，免得详情区空着。
        .onChange(of: selectableNames, initial: true) { _, names in
            if model.selection.map({ !names.contains($0) }) ?? true { model.selection = names.first }
        }
        .toolbar {
            // 空库时引导页正中已有新建按钮。
            if !isEmpty {
                Button { model.showingCreate = true } label: { Label("新建", systemImage: "plus") }
                    .help("新建虚拟机")
            }
        }
        .sheet(isPresented: $model.showingCreate) { CreateSheet() }
        .alert("操作失败", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("好") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private static let sidebarIdealWidth: CGFloat = 240
    private static let detailMinWidth: CGFloat = 520

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("还没有虚拟机", systemImage: "desktopcomputer")
        } description: {
            Text("新建一台 macOS、Linux 或 Windows 虚拟机")
        } actions: {
            Button { model.showingCreate = true } label: { Label("新建虚拟机…", systemImage: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(minWidth: Self.sidebarIdealWidth + Self.detailMinWidth)
    }

    private var library: some View {
        @Bindable var model = model
        return NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.machines, id: \.name) { vm in
                    MachineRow(vm: vm, activity: model.activity[vm.name])
                        .tag(vm.name)
                }
                ForEach(model.pendingCreations, id: \.self) { name in
                    if let activity = model.activity[name] {
                        PendingRow(name: name, activity: activity) { model.cancelCreation(name) }.tag(name)
                    }
                }
                ForEach(model.interruptedCreations, id: \.name) { request in
                    let row = InterruptedRow(request: request) { resume(request.name) }
                    // 半成品包有配置时同名的虚拟机行已在上面，这一行不参与选中，免得两行共用一个标签。
                    if model.summary(request.name) == nil {
                        row.tag(request.name)
                    } else {
                        row.selectionDisabled().contextMenu {
                            Button("继续创建") { resume(request.name) }
                            Button("放弃", role: .destructive) { model.discardCreation(request.name) }
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { names in
                if let name = names.first { rowMenu(name) }
            } primaryAction: { names in
                if let name = names.first, let vm = model.summary(name) { open(vm) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: Self.sidebarIdealWidth)
        } detail: {
            // 最小宽度只能加在详情列上：加在整个分栏视图外面时，展开侧栏的动画走到一半会直接跳到终点。
            detail.frame(minWidth: Self.detailMinWidth)
        }
    }

    @ViewBuilder private var detail: some View {
        if let name = model.selection, let vm = model.summary(name) {
            MachineDetailView(vm: vm)
        } else if let name = model.selection, let activity = model.activity[name] {
            CreatingView(name: name, activity: activity) { model.cancelCreation(name) }
        } else if let name = model.selection, let request = model.interruptedCreations.first(where: { $0.name == name }) {
            ContentUnavailableView {
                Label("\(request.name) 的创建被中断", systemImage: "exclamationmark.triangle")
            } description: {
                Text("自动继续没有成功。继续会从头再建，已下载的部分不用重下。")
            } actions: {
                Button("继续创建") { resume(request.name) }.buttonStyle(.borderedProminent)
                Button("放弃") { model.discardCreation(request.name) }
            }
        } else {
            ContentUnavailableView("选择一台虚拟机", systemImage: "desktopcomputer")
        }
    }

    @ViewBuilder private func rowMenu(_ name: String) -> some View {
        if let vm = model.summary(name) {
            machineMenu(vm)
        } else if model.activity[name] != nil {
            Button("取消创建") { model.cancelCreation(name) }
        } else if model.interruptedCreations.contains(where: { $0.name == name }) {
            Button("继续创建") { resume(name) }
            Button("放弃", role: .destructive) { model.discardCreation(name) }
        }
    }

    @ViewBuilder private func machineMenu(_ vm: VMSummary) -> some View {
        switch vm.state {
        case .stopped, .suspended:
            Button(vm.state == .suspended ? "继续" : "启动") { open(vm) }.disabled(model.activity[vm.name] != nil)
        case .running:
            Button("显示") { open(vm) }.disabled(!model.canDisplay(vm.name))
            Button("关机") { Task { await model.stop(vm.name) } }
        }
        Divider()
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: vm.path)]) }
    }

    /// 双击行：停着的启动，运行中且能显示画面的打开窗口。
    private func open(_ vm: VMSummary) {
        let canOpen = vm.state == .running ? model.canDisplay(vm.name) : model.activity[vm.name] == nil
        if canOpen { openWindow(id: "machine", value: vm.name) }
    }

    /// 侧栏各行的名字，按显示顺序。
    private var selectableNames: [String] {
        model.machines.map(\.name) + model.pendingCreations + model.interruptedCreations.map(\.name)
    }

    /// 既没有虚拟机，也没有正在创建或中断的。
    private var isEmpty: Bool { model.machines.isEmpty && model.pendingCreations.isEmpty && model.interruptedCreations.isEmpty }

    private func resume(_ name: String) {
        let openWindow = openWindow
        model.resumeCreation(name) { openWindow(id: "machine", value: $0) }
    }

    private var subtitle: String {
        guard !model.machines.isEmpty else { return "" }
        let running = model.machines.count { $0.state == .running }
        return running == 0 ? "\(model.machines.count) 台" : "\(model.machines.count) 台 · \(running) 台运行中"
    }
}

struct MachineRow: View {
    let vm: VMSummary
    let activity: AppModel.Activity?

    /// 选中行的底是强调色，这时圆点加白边，否则绿点落在蓝底上看不清。
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: vm.os.symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name).font(.headline).lineLimit(1)
                Text(activity?.text ?? vm.state.label).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                if let activity { ActivityBar(activity: activity) }
            }
            Spacer(minLength: 4)
            // 停止是常态，不画圆点，只有运行中和挂起才提示。
            if vm.state != .stopped {
                Circle().fill(vm.state.color)
                    .frame(width: 8, height: 8)
                    .padding(1.5)
                    .background(.white.opacity(prominence == .increased ? 1 : 0), in: .circle)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 选中还在创建的虚拟机时的详情区。进度只在这里读，更新时不重算整个窗口。
struct CreatingView: View {
    let name: String
    let activity: AppModel.Activity
    let cancel: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("正在创建 \(name)", systemImage: "desktopcomputer")
        } description: {
            Text(activity.text)
        } actions: {
            // actions 默认横排并把按钮拉宽，进度条和按钮竖排。
            VStack(spacing: 16) {
                if let fraction = activity.fraction {
                    ProgressView(value: fraction).frame(width: 280)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("取消", action: cancel).fixedSize()
            }
        }
    }
}

/// 正在创建、还没有虚拟机包的一行。
struct PendingRow: View {
    let name: String
    let activity: AppModel.Activity
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(activity.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ActivityBar(activity: activity)
            }
            Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("取消创建")
        }
        .padding(.vertical, 4)
    }
}

/// 上次 App 退出时没建完的一行。
struct InterruptedRow: View {
    let request: CreationRequest
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title2).frame(width: 28).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.name).font(.headline)
                Text("创建被中断").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("继续", action: resume).controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

/// 有进度时画进度条，进度未知时不画（文字已说明在做什么）。
struct ActivityBar: View {
    let activity: AppModel.Activity
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let fraction = activity.fraction {
            // 选中行的底色就是强调色，默认的进度填充会融进去。
            ProgressView(value: fraction).controlSize(.small)
                .tint(prominence == .increased ? .white : nil)
        }
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
