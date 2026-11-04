import AppKit
import MacVMEngine
import MacVMModel
import SwiftUI

/// 菜单栏图标弹出的面板：按运行状态分组列出虚拟机，每行带常用操作，底部是打开主窗口、设置与退出。
struct StatusMenu: View {
    /// `AppStorage` 键：是否在菜单栏显示图标。
    static let visibleKey = "showsMenuBarExtra"

    /// 超过这么多行时列表改为滚动，面板不至于比屏幕还高。
    private static let maxVisibleRows = 6
    fileprivate static let rowHeight: CGFloat = 56

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
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
                    .frame(height: CGFloat(Self.maxVisibleRows) * Self.rowHeight + 48)
            } else {
                sections
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { model.refreshSSHIncluded() }
    }

    // MARK: 顶栏与底栏

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacVM").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    if runningCount > 0 {
                        Circle().fill(.green).frame(width: 6, height: 6)
                    }
                    Text(summary)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(systemImage: "plus", help: "新建虚拟机") { createMachine() }
            MoreMenu {
                Button("新建虚拟机…") { createMachine() }
                Button("打开 MacVM") { showLibrary() }
                Divider()
                Button("在 Finder 中显示虚拟机目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.library.root])
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton("打开 MacVM", systemImage: "macwindow") { showLibrary() }
            FooterButton("设置…", systemImage: "gearshape") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",")
            Spacer()
            FooterButton("退出", systemImage: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
            VStack(spacing: 3) {
                Text("还没有虚拟机").font(.system(size: 13, weight: .semibold))
                Text("新建一台 macOS、Linux 或 Windows 虚拟机").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button { createMachine() } label: {
                Label("新建虚拟机…", systemImage: "plus")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private var runningCount: Int { running.count }

    private var summary: String {
        let total = model.machines.count
        let creating = model.pendingCreations.count + model.interruptedCreations.count
        guard total > 0 else { return creating > 0 ? "正在创建 \(creating) 台" : "还没有虚拟机" }
        return runningCount == 0 ? "\(total) 台虚拟机 · 都没有运行" : "\(runningCount) 台运行中 · 共 \(total) 台"
    }

    // MARK: 列表

    private var running: [VMSummary] { model.machines.filter { $0.state == .running } }
    private var notRunning: [VMSummary] { model.machines.filter { $0.state != .running } }

    private var isEmpty: Bool { model.machines.isEmpty && model.pendingCreations.isEmpty && model.interruptedCreations.isEmpty }
    private var rowCount: Int { model.machines.count + model.pendingCreations.count + model.interruptedCreations.count }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            let creating = model.pendingCreations.count + model.interruptedCreations.count
            if creating > 0 {
                SectionTitle("正在创建", count: creating)
                ForEach(model.pendingCreations, id: \.self) { pendingRow($0) }
                ForEach(model.interruptedCreations, id: \.name) { interruptedRow($0) }
            }
            if !running.isEmpty {
                SectionTitle("运行中", count: running.count)
                ForEach(running, id: \.name) { machineRow($0) }
            }
            if !notRunning.isEmpty {
                SectionTitle("未运行", count: notRunning.count)
                ForEach(notRunning, id: \.name) { machineRow($0) }
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
            subtitle: pending ?? subtitle(vm),
            chips: pending == nil ? chips(vm, config: config) : [],
            activity: pending == nil ? activity : nil,
            help: canDisplay ? "显示画面" : "在 MacVM 中查看",
            open: { canDisplay ? show(vm.name) : reveal(vm.name) }
        ) {
            OSTile(os: vm.os, state: vm.state)
        } trailing: {
            // 关机等待客户机响应时不挡按钮，客户机不理会时还能挂起或打开画面。
            if pending != nil || (vm.state == .running && model.isCreating(vm.name)) {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                switch vm.state {
                case .running:
                    if config?.supportsSuspend == true {
                        IconButton(systemImage: "pause.fill", help: "挂起") {
                            perform(vm.name, "正在挂起…") { await model.suspend(vm.name) }
                        }
                    }
                    if canDisplay {
                        IconButton(systemImage: "macwindow", help: "显示画面") { show(vm.name) }
                    }
                case .stopped, .suspended:
                    IconButton(systemImage: "play.fill", help: vm.state == .suspended ? "继续运行" : "启动") { show(vm.name) }
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
                Button("拷贝 SSH 命令") { copy(model.sshCommand(vm.name)) }
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

    /// 没运行时显示硬件与系统；运行中没有可拷贝的连接方式时只显示状态。
    private func subtitle(_ vm: VMSummary) -> String {
        switch vm.state {
        case .running:
            return vm.state.label
        case .stopped, .suspended:
            var parts = ["\(vm.cpuCount) 核", DisplaySize.format(vm.memorySize), vm.os.label]
            if vm.state == .suspended { parts.insert(vm.state.label, at: 0) }
            return parts.joined(separator: " · ")
        }
    }

    /// 运行中显示怎么连上它，点一下即拷贝。
    private func chips(_ vm: VMSummary, config: VMConfig?) -> [String] {
        guard vm.state == .running else { return [] }
        var chips: [String] = []
        if let ip = vm.ipAddress { chips.append(ip) }
        if config?.guestUser != nil { chips.append(model.sshCommand(vm.name)) }
        return chips
    }

    private func pendingRow(_ name: String) -> some View {
        let activity = model.activity[name]
        return PanelRow(title: name, subtitle: "", activity: activity,
                        help: "在 MacVM 中查看", open: { reveal(name) }) {
            ProgressTile(os: model.creatingOS(name), activity: activity)
        } trailing: {
            IconButton(systemImage: "xmark", help: "取消创建") { model.cancelCreation(name) }
        }
    }

    private func interruptedRow(_ request: CreationRequest) -> some View {
        PanelRow(title: request.name, subtitle: "创建被中断，可以继续", activity: nil, help: nil, open: nil) {
            Tile {
                Image(systemName: request.os.tileSymbol)
                    .font(.system(size: request.os.tileSymbolSize, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .overlay(alignment: .bottomTrailing) {
                Badge(systemImage: "exclamationmark", color: .orange)
            }
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
/// 说明按优先级取：`activity` 的进度，可拷贝的 `chips`，最后是 `subtitle`。
private struct PanelRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    var chips: [String] = []
    let activity: AppModel.Activity?
    let help: String?
    let open: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // 整行的提示只挂在按钮以外的部分：挂在整行上会盖掉按钮各自的提示。
            HStack(spacing: 11) {
                leading
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let activity {
                        ActivityStatus(activity: activity)
                    } else if !chips.isEmpty {
                        ChipLine(chips: chips)
                    } else {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .help(help ?? "")
            HStack(spacing: 2) { trailing }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(minHeight: StatusMenu.rowHeight)
        .background(.primary.opacity(hovering && open != nil ? 0.06 : 0), in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { open?() }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 进行中任务的说明：步骤名与百分比一行，下面是进度条与传输量、速度。
/// 进度只在这里读，进度更新时只重绘这几行，不牵动整个面板。
private struct ActivityStatus: View {
    let activity: AppModel.Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(activity.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                // 没有传输量的步骤自己在标题里写百分比。
                if let fraction = activity.fraction, activity.detail != nil {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: fraction))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            if let fraction = activity.fraction {
                ProgressBar(fraction: fraction)
            }
            if let transfer {
                Text(transfer)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var transfer: String? {
        let parts = [activity.detail, activity.bytesPerSecond.map { DisplaySize.format(UInt64($0)) + "/s" }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 细的圆头进度条，用强调色。
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(.tint)
                    .frame(width: max(4, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// 一排可点击拷贝的小标签；放不下时先舍弃前面的。
private struct ChipLine: View {
    let chips: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(0..<chips.count, id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(chips[start...], id: \.self) { CopyChip(text: $0) }
                }
            }
        }
    }
}

/// 点一下拷贝文字，随后短暂显示「已拷贝」。
private struct CopyChip: View {
    let text: String

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                // 文字占位不变，换成「已拷贝」时标签不跳动。
                Text(text)
                    .truncationMode(.middle)
                    .opacity(copied ? 0 : 1)
                    .overlay { if copied { Text("已拷贝").fixedSize() } }
            }
            .font(.system(size: 11).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.primary.opacity(hovering ? 0.12 : 0.06), in: .rect(cornerRadius: 5, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help("拷贝「\(text)」")
    }
}

private struct SectionTitle: View {
    let text: String
    let count: Int

    init(_ text: String, count: Int) {
        self.text = text
        self.count = count
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(text).foregroundStyle(.secondary)
            Text("\(count)").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.top, 10)
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
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

/// 像 App 图标的圆角方块：运行中是系统代表色的渐变，带顶部高光与细边；没运行时是浅灰底、灰色图标。
/// 运行中与已挂起在右下角加状态圆点。
private struct OSTile: View {
    let os: GuestOS
    let state: VMSummary.State

    var body: some View {
        let active = state == .running
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
            .overlay(alignment: .bottomTrailing) {
                if state != .stopped {
                    Circle().fill(state.color)
                        .frame(width: 9, height: 9)
                        .padding(2)
                        .background(.background, in: .circle)
                        .offset(x: 3, y: 3)
                }
            }
    }
}

/// 正在创建的虚拟机：灰色的系统图标，右下角标出在下载还是在安装；系统未知时转圈。
private struct ProgressTile: View {
    let os: GuestOS?
    let activity: AppModel.Activity?

    var body: some View {
        Tile {
            if let os {
                Image(systemName: os.tileSymbol)
                    .font(.system(size: os.tileSymbolSize, weight: .medium))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if os != nil {
                Badge(systemImage: activity?.bytesPerSecond != nil ? "arrow.down" : "gearshape.fill", color: .accentColor)
            }
        }
    }
}

/// 图标块右下角的小圆标。
private struct Badge: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(color, in: .circle)
            .padding(1.5)
            .background(.background, in: .circle)
            .offset(x: 4, y: 4)
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
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(hovering && isEnabled ? 0.1 : 0), in: .rect(cornerRadius: 7, style: .continuous))
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
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .background(.primary.opacity(hovering ? 0.1 : 0), in: .rect(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .help("更多")
    }
}

/// 底栏里带图标、像菜单项的文字按钮。
private struct FooterButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(title)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.primary.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 7, style: .continuous))
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
