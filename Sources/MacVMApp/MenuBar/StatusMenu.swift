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
            separator
            if isEmpty {
                empty
            } else if rowCount > Self.maxVisibleRows {
                ScrollView { sections }
                    .frame(height: CGFloat(Self.maxVisibleRows) * Self.rowHeight + 48)
            } else {
                sections
            }
            separator
            footer
        }
        .frame(width: 400)
        .onAppear { model.refreshSSHIncluded() }
    }

    // MARK: 顶栏与底栏

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("MacVM").font(.system(size: 14, weight: .semibold))
                // 空库时正文的空状态已有同样的说明与新建按钮。
                if !isEmpty {
                    HStack(spacing: 5) {
                        if runningCount > 0 {
                            Circle().fill(.green).frame(width: 6, height: 6)
                        }
                        Text(summary)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isEmpty {
                IconButton(systemImage: "plus", help: "New Virtual Machine") { createMachine() }
            }
            MoreMenu {
                Button("Show Virtual Machines Folder in Finder") {
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
            FooterButton("Open MacVM", systemImage: "macwindow") { showLibrary() }
            FooterButton("Settings…", systemImage: "gearshape") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",")
            Spacer()
            FooterButton("Quit", systemImage: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    /// 分隔线两端内缩，不顶到面板的圆角边。
    private var separator: some View {
        Divider().padding(.horizontal, 12)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("No Virtual Machines").font(.system(size: 14, weight: .semibold))
                Text("Create a macOS, Linux, or Windows virtual machine").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            FilledButton("New Virtual Machine…", systemImage: "plus") { createMachine() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 22)
    }

    private var runningCount: Int { running.count }

    private var summary: String {
        let total = model.machines.count
        let creating = model.pendingCreations.count + model.interruptedCreations.count
        guard total > 0 else { return creating > 0 ? String(l10n: "\(creating) being created") : String(l10n: "No virtual machines yet") }
        return runningCount == 0 ? String(l10n: "\(total) virtual machines · none running") : String(l10n: "\(runningCount) running · \(total) total")
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
                SectionTitle("Creating", count: creating)
                ForEach(model.pendingCreations, id: \.self) { pendingRow($0) }
                ForEach(model.interruptedCreations, id: \.name) { interruptedRow($0) }
            }
            if !running.isEmpty {
                SectionTitle("Running", count: running.count)
                ForEach(running, id: \.name) { machineRow($0) }
            }
            if !notRunning.isEmpty {
                SectionTitle("Not Running", count: notRunning.count)
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
            help: canDisplay ? "Show Display" : "Show in MacVM",
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
                    if model.canSuspend(vm.name) {
                        IconButton(systemImage: "pause.fill", help: "Suspend") {
                            perform(vm.name, String(l10n: "Suspending…")) { await model.suspend(vm.name) }
                        }
                    }
                    if canDisplay {
                        IconButton(systemImage: "macwindow", help: "Show Display") { show(vm.name) }
                    }
                case .stopped, .suspended:
                    IconButton(systemImage: "play.fill", help: vm.state == .suspended ? "Resume" : "Start") { show(vm.name) }
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
                Button("Copy IP Address") { copy(ip) }
            }
            if config?.guestUser != nil {
                Button("Copy SSH Command") { copy(model.sshCommand(vm.name)) }
            }
            if vm.ipAddress != nil || config?.guestUser != nil { Divider() }
            Button("Shut Down") { Task { await model.stop(vm.name) } }
            Button("Force Power Off", role: .destructive) {
                perform(vm.name, String(l10n: "Powering off…")) { await model.stop(vm.name, force: true) }
            }
            Divider()
        }
        if model.isCreating(vm.name) {
            Button("Cancel Creation") { model.cancelCreation(vm.name) }
            Divider()
        }
        Button("Show in MacVM") { reveal(vm.name) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: vm.path)]) }
    }

    /// 没运行时显示硬件与系统；运行中没有可拷贝的连接方式时只显示状态。
    private func subtitle(_ vm: VMSummary) -> String {
        switch vm.state {
        case .running:
            return vm.state.label
        case .stopped, .suspended:
            var parts = [String(l10n: "\(vm.cpuCount) cores"), DisplaySize.format(vm.memorySize), vm.os.label]
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
                        help: "Show in MacVM", open: { reveal(name) }) {
            ProgressTile(os: model.creatingOS(name), activity: activity)
        } trailing: {
            IconButton(systemImage: "xmark", help: "Cancel Creation") { model.cancelCreation(name) }
        }
    }

    private func interruptedRow(_ request: CreationRequest) -> some View {
        PanelRow(title: request.name, subtitle: String(l10n: "Creation was interrupted; you can resume it"), activity: nil, help: nil, open: nil) {
            Tile {
                Image(systemName: request.os.tileSymbol)
                    .font(.system(size: request.os.tileSymbolSize, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .statusBadge(systemImage: "exclamationmark", color: .orange)
        } trailing: {
            IconButton(systemImage: "arrow.clockwise", help: "Resume Creation") {
                NSApp.activate()
                model.resumeCreation(request.name) { openWindow(id: "machine", value: $0) }
            }
            MoreMenu {
                Button("Discard", role: .destructive) { model.discardCreation(request.name) }
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
    let help: LocalizedStringKey?
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

/// 一排可点击拷贝的小标签；第一个总是完整显示，放不下时后面的从中间截断。
private struct ChipLine: View {
    let chips: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.offset) { index, text in
                CopyChip(text: text).layoutPriority(index == 0 ? 1 : 0)
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
                    .overlay { if copied { Text("Copied").fixedSize() } }
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
        .help("Copy “\(text)”")
    }
}

private struct SectionTitle: View {
    let text: LocalizedStringKey
    let count: Int

    init(_ text: LocalizedStringKey, count: Int) {
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
            IconButton(systemImage: "xmark", help: "Close") { dismiss() }
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

/// 像 App 图标的圆角方块：运行中是系统代表色的纯色底与细边；没运行时是浅灰底、灰色图标。
/// 运行中与已挂起在右下角加状态圆点。
private struct OSTile: View {
    let os: GuestOS
    let state: VMSummary.State

    var body: some View {
        if state == .stopped {
            tile
        } else {
            tile.cornerBadge(size: 9, ring: 2, inset: 3.5) { Circle().fill(state.color) }
        }
    }

    private var tile: some View {
        let active = state == .running
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Image(systemName: os.tileSymbol)
            .font(.system(size: os.tileSymbolSize, weight: .medium))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .shadow(color: .black.opacity(active ? 0.18 : 0), radius: 0.5, y: 0.5)
            .frame(width: 38, height: 38)
            .background {
                if active {
                    shape.fill(os.tileColor)
                        .shadow(color: os.tileColor.opacity(0.35), radius: 2, y: 1)
                } else {
                    shape.fill(.primary.opacity(0.06))
                }
            }
            .overlay { shape.strokeBorder(active ? .white.opacity(0.16) : .primary.opacity(0.08), lineWidth: 0.5) }
    }
}

/// 正在创建的虚拟机：灰色的系统图标，右下角标出在下载还是在安装；系统未知时转圈。
private struct ProgressTile: View {
    let os: GuestOS?
    let activity: AppModel.Activity?

    var body: some View {
        if let os {
            Tile {
                Image(systemName: os.tileSymbol)
                    .font(.system(size: os.tileSymbolSize, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .statusBadge(systemImage: activity?.bytesPerSecond != nil ? "arrow.down" : "gearshape.fill", color: .accentColor)
        } else {
            Tile { ProgressView().controlSize(.small) }
        }
    }
}

extension View {
    /// 图标块右下角的小圆标。
    fileprivate func statusBadge(systemImage: String, color: Color) -> some View {
        cornerBadge(size: 15, ring: 1.5, inset: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .background(color, in: .circle)
        }
    }

    /// 在右下角放直径 `size` 的角标，圆心距右下两边各 `inset`；本视图上挖掉角标外宽 `ring` 的一圈，
    /// 透出背后的面板而不是画一圈底色：面板是半透明材质，任何纯色描边都和它对不上。
    fileprivate func cornerBadge<Badge: View>(size: CGFloat, ring: CGFloat, inset: CGFloat,
                                              @ViewBuilder _ badge: () -> Badge) -> some View {
        let hole = size + ring * 2
        return mask {
            // 遮罩向外多留一截，不切掉图标块的阴影。
            Color.clear
                .background { Rectangle().padding(-8) }
                .overlay(alignment: .bottomTrailing) {
                    Circle().frame(width: hole, height: hole)
                        .offset(x: hole / 2 - inset, y: hole / 2 - inset)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
        .overlay(alignment: .bottomTrailing) {
            badge().frame(width: size, height: size)
                .offset(x: size / 2 - inset, y: size / 2 - inset)
        }
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
    let help: LocalizedStringKey
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
        .help("More")
    }
}

/// 带浅灰底的文字按钮，悬停时底色加深；字号与圆角跟面板里其他按钮一致。
private struct FilledButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.primary.opacity(hovering ? 0.12 : 0.07), in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 底栏里带图标、像菜单项的文字按钮。
private struct FooterButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
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

    var tileColor: Color {
        switch self {
        case .macOS: Color(red: 0.27, green: 0.28, blue: 0.31)
        case .linux: Color(red: 0.96, green: 0.58, blue: 0.13)
        case .windows: Color(red: 0.10, green: 0.53, blue: 0.93)
        }
    }
}
