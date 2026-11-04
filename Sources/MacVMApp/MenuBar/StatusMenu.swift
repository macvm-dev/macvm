import AppKit
import MacVMEngine
import MacVMModel
import SwiftUI

/// 菜单栏图标弹出的面板：按运行状态分组列出虚拟机，每行带常用操作，底部是设置与退出。
struct StatusMenu: View {
    /// `AppStorage` 键：是否在菜单栏显示图标。
    static let visibleKey = "showsMenuBarExtra"

    /// 超过这么多行时列表改为滚动，面板不至于比屏幕还高。
    private static let maxVisibleRows = 7
    fileprivate static let rowHeight: CGFloat = 54

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// 读的是 `~/.ssh/config`，下载进度刷新面板时不重复读文件，只在面板出现时读一次。
    @State private var sshIncluded = false
    /// 从面板发起、还没返回的挂起与强制断电，值是行里显示的进行中文字；期间该行的操作按钮换成转圈。
    @State private var busy: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.lastError {
                ErrorBanner(message: error) { model.lastError = nil }
            }
            Divider()
            if isEmpty {
                empty
            } else if rowCount > Self.maxVisibleRows {
                ScrollView { sections }
                    .frame(height: CGFloat(Self.maxVisibleRows) * Self.rowHeight + 40)
            } else {
                sections
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { sshIncluded = SSHConfig.isIncluded }
    }

    // MARK: 顶栏与底栏

    private var header: some View {
        HStack(alignment: .center, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MacVM").font(.system(size: 15, weight: .semibold))
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(systemImage: "plus", help: "新建虚拟机") { createMachine() }
            MoreMenu {
                Button("打开 MacVM") { showLibrary() }
                Button("在 Finder 中显示虚拟机目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.library.root])
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            TextButton("设置…") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",")
            Spacer()
            TextButton("退出 MacVM") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有虚拟机").font(.callout).foregroundStyle(.secondary)
            Button("新建虚拟机…") { createMachine() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var summary: String {
        let total = model.machines.count
        guard total > 0 else { return model.pendingCreations.isEmpty ? "还没有虚拟机" : "正在创建" }
        let running = model.machines.count { $0.state == .running }
        return running == 0 ? "共 \(total) 台，都没有运行" : "\(running) 台运行中 · 共 \(total) 台"
    }

    // MARK: 列表

    private var running: [VMSummary] { model.machines.filter { $0.state == .running } }
    private var notRunning: [VMSummary] { model.machines.filter { $0.state != .running } }

    private var isEmpty: Bool { model.machines.isEmpty && model.pendingCreations.isEmpty && model.interruptedCreations.isEmpty }
    private var rowCount: Int { model.machines.count + model.pendingCreations.count + model.interruptedCreations.count }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !running.isEmpty {
                SectionTitle("运行中")
                ForEach(running, id: \.name) { machineRow($0) }
            }
            if !notRunning.isEmpty {
                SectionTitle("未运行")
                ForEach(notRunning, id: \.name) { machineRow($0) }
            }
            if !model.pendingCreations.isEmpty || !model.interruptedCreations.isEmpty {
                SectionTitle("正在创建")
                ForEach(model.pendingCreations, id: \.self) { pendingRow($0) }
                ForEach(model.interruptedCreations, id: \.name) { interruptedRow($0) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private func machineRow(_ vm: VMSummary) -> some View {
        let activity = model.activity[vm.name]
        let config = model.config(of: vm.name)
        let pending = busy[vm.name]
        let canDisplay = vm.state == .running && model.canDisplay(vm.name)
        return PanelRow(
            title: vm.name,
            subtitle: pending ?? subtitle(vm, config: config),
            activity: pending == nil ? activity : nil,
            help: canDisplay ? "显示画面" : "在 MacVM 中查看",
            open: { canDisplay ? show(vm.name) : reveal(vm.name) }
        ) {
            OSTile(os: vm.os, active: vm.state == .running)
        } trailing: {
            // 关机等待客户机响应时不挡按钮，客户机不理会时还能挂起或打开画面。
            if pending != nil || (vm.state == .running && model.isCreating(vm.name)) {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                switch vm.state {
                case .running:
                    if config?.supportsSuspend == true {
                        IconButton(systemImage: "pause", help: "挂起") {
                            perform(vm.name, "正在挂起…") { await model.suspend(vm.name) }
                        }
                    }
                    if canDisplay {
                        IconButton(systemImage: "macwindow", help: "显示画面") { show(vm.name) }
                    }
                case .stopped, .suspended:
                    IconButton(systemImage: "play", help: vm.state == .suspended ? "继续运行" : "启动") { show(vm.name) }
                        .disabled(activity != nil)
                }
            }
            MoreMenu { machineMenu(vm, config: config) }
        }
        .contextMenu { machineMenu(vm, config: config) }
    }

    @ViewBuilder private func machineMenu(_ vm: VMSummary, config: VMConfig?) -> some View {
        if vm.state == .running {
            if let ip = vm.ipAddress {
                Button("拷贝 IP 地址") { copy(ip) }
            }
            if config?.guestUser != nil {
                Button("拷贝 SSH 命令") { copy(sshCommand(vm.name)) }
            }
            if vm.ipAddress != nil || config?.guestUser != nil { Divider() }
            Button("关机") { Task { await model.stop(vm.name) } }
            Button("强制断电", role: .destructive) {
                perform(vm.name, "正在断电…") { await model.stop(vm.name, force: true) }
            }
            Divider()
        }
        if model.isCreating(vm.name) {
            Button("取消创建") { model.cancelCreation(vm.name) }
            Divider()
        }
        Button("在 MacVM 中查看") { reveal(vm.name) }
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: vm.path)]) }
    }

    /// 运行中显示怎么连上它；没运行时显示硬件与系统。
    private func subtitle(_ vm: VMSummary, config: VMConfig?) -> String {
        switch vm.state {
        case .running:
            var parts: [String] = []
            if let ip = vm.ipAddress { parts.append(ip) }
            if config?.guestUser != nil { parts.append(sshCommand(vm.name)) }
            return parts.isEmpty ? vm.state.label : parts.joined(separator: " · ")
        case .stopped, .suspended:
            var parts = ["\(vm.cpuCount) 核", DisplaySize.format(vm.memorySize), vm.os.label]
            if vm.state == .suspended { parts.insert(vm.state.label, at: 0) }
            return parts.joined(separator: " · ")
        }
    }

    private func sshCommand(_ name: String) -> String { sshIncluded ? "ssh \(name)" : "macvm ssh \(name)" }

    private func pendingRow(_ name: String) -> some View {
        let activity = model.activity[name]
        return PanelRow(title: name, subtitle: "", activity: activity,
                        help: "在 MacVM 中查看", open: { reveal(name) }) {
            Tile { ProgressView().controlSize(.small) }
        } trailing: {
            IconButton(systemImage: "xmark", help: "取消创建") { model.cancelCreation(name) }
        }
    }

    private func interruptedRow(_ request: CreationRequest) -> some View {
        PanelRow(title: request.name, subtitle: "创建被中断", activity: nil, help: nil, open: nil) {
            Tile { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        } trailing: {
            IconButton(systemImage: "arrow.clockwise", help: "继续创建") {
                NSApp.activate()
                model.resumeCreation(request.name) { openWindow(id: "machine", value: $0) }
            }
            MoreMenu {
                Button("放弃", role: .destructive) { model.discardCreation(request.name) }
            }
        }
    }

    // MARK: 操作

    private func perform(_ name: String, _ text: String, _ operation: @escaping @MainActor () async -> Void) {
        busy[name] = text
        Task {
            await operation()
            busy[name] = nil
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 菜单栏的面板不会激活 App，新开的窗口会落在别的 App 后面。
    private func show(_ name: String) {
        NSApp.activate()
        openWindow(id: "machine", value: name)
    }

    private func reveal(_ name: String) {
        model.selection = name
        showLibrary()
    }

    private func createMachine() {
        showLibrary()
        model.showingCreate = true
    }

    private func showLibrary() {
        NSApp.activate()
        openWindow(id: "library")
    }
}

// MARK: - 部件

/// 一行：左侧图标块，中间名称与说明，右侧操作按钮；悬停时整行高亮，点空白处执行 `open`。
/// 有 `activity` 时说明换成它的进度。进度只在这里读，进度更新时只重绘这一行，不牵动整个面板。
private struct PanelRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    let activity: AppModel.Activity?
    let help: String?
    let open: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            // 整行的提示只挂在按钮以外的部分：挂在整行上会盖掉按钮各自的提示。
            HStack(spacing: 11) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(activity?.text ?? subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .contentTransition(.opacity)
                    if let fraction = activity?.fraction {
                        ProgressView(value: fraction).controlSize(.mini).padding(.top, 2)
                    }
                }
                Spacer(minLength: 6)
            }
            .contentShape(.rect)
            .help(help ?? "")
            HStack(spacing: 0) { trailing }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: StatusMenu.rowHeight)
        .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 9))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { open?() }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }
}

/// 面板里的操作失败时就地提示；主窗口不一定开着，弹窗看不到。
private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton(systemImage: "xmark", help: "关闭") { dismiss() }
                .padding(.top, -5)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 9))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

/// 像 App 图标的圆角方块：运行中是系统代表色的渐变，带顶部高光与细边；没运行时是浅灰底、灰色图标。
private struct OSTile: View {
    let os: GuestOS
    let active: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Image(systemName: os.tileSymbol)
            .font(.system(size: os.tileSymbolSize, weight: .medium))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .shadow(color: .black.opacity(active ? 0.18 : 0), radius: 0.5, y: 0.5)
            .frame(width: 38, height: 38)
            .background {
                if active {
                    shape.fill(LinearGradient(colors: [os.tileTop, os.tileBottom], startPoint: .top, endPoint: .bottom))
                        .overlay {
                            shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
                        }
                        .shadow(color: os.tileBottom.opacity(0.35), radius: 2, y: 1)
                } else {
                    shape.fill(.primary.opacity(0.06))
                }
            }
            .overlay { shape.strokeBorder(active ? .white.opacity(0.16) : .primary.opacity(0.08), lineWidth: 0.5) }
    }
}

private struct Tile<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .frame(width: 38, height: 38)
            .background(.primary.opacity(0.06), in: shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
    }
}

/// 只有图标的按钮，悬停时加底色。
private struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(hovering && isEnabled ? 0.1 : 0), in: .rect(cornerRadius: 7))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .secondary : .tertiary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 「更多」菜单：只留省略号，悬停时加底色。
private struct MoreMenu<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var hovering = false

    var body: some View {
        Menu { content } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .background(.primary.opacity(hovering ? 0.1 : 0), in: .rect(cornerRadius: 7))
        .onHover { hovering = $0 }
        .help("更多")
    }
}

/// 底栏里像菜单项的文字按钮。
private struct TextButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.primary.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private extension GuestOS {
    /// 面板里用更接近各系统标志的图形；Windows 用四格方块。
    var tileSymbol: String {
        switch self {
        case .macOS: "apple.logo"
        case .linux: "terminal.fill"
        case .windows: "square.grid.2x2.fill"
        }
    }

    var tileSymbolSize: CGFloat {
        switch self {
        case .macOS: 19
        case .linux: 15
        case .windows: 16
        }
    }

    var tileTop: Color {
        switch self {
        case .macOS: Color(red: 0.42, green: 0.44, blue: 0.48)
        case .linux: Color(red: 1.00, green: 0.73, blue: 0.24)
        case .windows: Color(red: 0.24, green: 0.66, blue: 1.00)
        }
    }

    var tileBottom: Color {
        switch self {
        case .macOS: Color(red: 0.13, green: 0.14, blue: 0.16)
        case .linux: Color(red: 0.93, green: 0.47, blue: 0.05)
        case .windows: Color(red: 0.00, green: 0.42, blue: 0.86)
        }
    }
}
