import MacVMEngine
import MacVMModel
import SwiftUI
import UniformTypeIdentifiers

/// 一台虚拟机的窗口：打开即在本进程启动（或接上已在本进程运行的）虚拟机。
/// QEMU 引擎的画面经 VNC 显示，在别的进程里运行的也能接上；VZ 的画面只能在运行它的进程里显示，
/// 别的进程运行的能挂起就接到本进程（`AppModel.takeOver`），不能的只说明原因。
struct MachineWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlActiveState) private var activeState
    let name: String
    @State private var runner: (any MachineRunner)?
    @State private var failed = false
    /// 启动失败的原因，就地显示：只开着本窗口时也看得到。
    @State private var failure: ReportedError?
    @State private var showingShares = false
    @State private var showingImages = false
    @State private var showingForwards = false
    @State private var choosingImage = false
    /// 改了声音或麦克风后在画面顶部短暂显示的说明。
    @State private var notice: String?
    /// 从本窗口发起、还没返回的挂起；期间挂起按钮换成转圈，关机按钮不可点。
    @State private var suspending = false
    /// 本窗口启动了虚拟机、VZ 画面还没收到第一帧；在那之前画面是黑的，盖上启动提示。
    @State private var awaitingFirstFrame = false
    /// 正在把别的进程运行的虚拟机接到本进程，期间它短暂停在挂起状态，窗口不因此关闭。
    @State private var takingOver = false
    /// 启动提示的文字，挂起的虚拟机是从存档恢复。
    @State private var startingTitle = String(l10n: "Starting…")
    /// 本窗口的开机是从挂起状态恢复的（含接管别的进程运行的）：客户机已在运行，显示器休眠时不出新帧，不必久等第一帧。
    @State private var restoring = false
    /// 窗口显示客户机画面期间经代理同步剪贴板；没有画面或客户机不经代理同步时为 nil。
    @State private var clipboard: ClipboardSync?
    /// 进行中的文件复制（拖放、剪贴板里的文件），在画面顶部显示进度。
    @State private var transfers: [GuestTransferActivity] = []

    private var isRunning: Bool { model.summary(name)?.state == .running }
    private var runningElsewhere: Bool { isRunning && !model.isRunningHere(name) }
    /// 窗口里显示着客户机画面：VZ 的画面只在本进程运行时有，QEMU 的在别的进程运行时也能接上。
    private var showsDisplay: Bool {
        runner is VZRunner || (model.config(of: name)?.engine == .qemu && (runner != nil || runningElsewhere))
    }
    /// 等客户机自己关机期间关机按钮换成转圈；挂起仍可点，客户机不理会关机时还能挂起。
    private var stopping: Bool { model.isStopping(name) }
    /// 进行中的挂起、关机或首次开机配置，在画面顶部一直显示到结束。
    /// 首次登录建用户目录期间客户机画面是黑的，靠这条提示说明不是卡住了。
    private var progress: String? {
        if suspending { return String(l10n: "Suspending…") }
        if stopping { return model.activity[name]?.text ?? String(l10n: "Shutting down…") }
        if model.isSettingUpGuest(name) { return String(l10n: "Setting up for the first time: signing in and installing the guest agent. The screen may stay black for a while…") }
        return nil
    }

    var body: some View {
        let bundle = try? model.library.bundle(named: name)
        let config = model.config(of: name)
        Group {
            if let vz = runner as? VZRunner {
                VirtualMachineView(runner: vz, firstFrameTimeout: restoring ? Self.restoredFrameTimeout : VZRunner.firstFrameTimeout,
                                   onFirstFrame: awaitingFirstFrame ? { arrived in
                                       withAnimation { awaitingFirstFrame = false }
                                       if !arrived, restoring { announce(String(l10n: "The guest display is asleep. Move the mouse or press any key to wake it")) }
                                   } : nil)
                    .overlay {
                        if awaitingFirstFrame { startingView.transition(.opacity) }
                    }
            } else if let bundle, config?.engine == .qemu, runner != nil || runningElsewhere {
                QEMUMachineView(bundle: bundle)
            } else if runningElsewhere, failed || !model.canTakeOver(name) {
                ContentUnavailableView {
                    Label("Running in a Background Process", systemImage: "terminal")
                } description: {
                    if let failure {
                        Text(failure.message).textSelection(.enabled)
                    } else {
                        Text("This virtual machine was started with macvm start and is running in another process. Only the process running a VZ virtual machine can show its screen, and this one can't be suspended to move it here. Shut it down, then start it again here.")
                    }
                } actions: {
                    Button("Shut Down") { Task { await model.stop(name) } }
                }
            } else if failed {
                ContentUnavailableView {
                    Label("Couldn't Start", systemImage: "exclamationmark.triangle")
                } description: {
                    if let failure { Text(failure.message).textSelection(.enabled) }
                }
            } else {
                startingView
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                if let progress {
                    banner {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(progress)
                        }
                    }
                } else if let notice {
                    banner { Label(notice, systemImage: "info.circle") }
                        .onTapGesture { withAnimation { self.notice = nil } }
                }
                ForEach(transfers, id: \.self) { transfer in
                    banner { transferRow(transfer) }
                }
            }
        }
        .animation(.default, value: progress)
        .animation(.default, value: transfers)
        .onReceive(NotificationCenter.default.publisher(for: GuestTransferActivity.began)) { note in
            guard let activity = note.object as? GuestTransferActivity, activity.vmName == name else { return }
            transfers.append(activity)
        }
        .onReceive(NotificationCenter.default.publisher(for: GuestTransferActivity.ended)) { note in
            guard let activity = note.object as? GuestTransferActivity, activity.vmName == name else { return }
            transfers.removeAll { $0 === activity }
            if let failure = activity.failure { withAnimation { notice = failure } }
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { notice = nil }
        }
        .navigationTitle(name)
        .reportsErrors()
        .task(id: name) {
            if runningElsewhere {
                guard model.canTakeOver(name) else { return }
                startingTitle = String(l10n: "Moving into the app…")
                awaitingFirstFrame = true
                takingOver = true
                let taken = await model.takeOver(name)
                restoring = model.wasRestored(name)
                runner = taken
                takingOver = false
                recordFailure()
                return
            }
            if model.summary(name)?.state == .suspended { startingTitle = String(l10n: "Resuming…") }
            awaitingFirstFrame = !model.isRunningHere(name)
            let started = await model.start(name)
            restoring = model.wasRestored(name)
            runner = started
            recordFailure()
            if !(runner is VZRunner) { awaitingFirstFrame = false }
        }
        .onChange(of: isRunning) { wasRunning, running in
            // 虚拟机停止（客户机关机、挂起）后窗口没有内容可显示。
            if wasRunning, !running, !takingOver { dismiss() }
        }
        .onChange(of: model.isRunningHere(name)) { _, running in
            if !running { runner = nil }
        }
        .onChange(of: showsDisplay && config.map(GuestClipboard.enabled) == true, initial: true) { _, syncing in
            if syncing, let bundle {
                clipboard = ClipboardSync(bundle: bundle)
                if activeState == .key { clipboard?.push() }
            } else {
                clipboard = nil
            }
        }
        .onChange(of: activeState) { old, new in
            if new == .key { clipboard?.push() } else if old == .key { clipboard?.pull() }
        }
        // 窗口在主窗口状态下关掉时 activeState 不再变化；虚拟机可能仍在后台运行，照样取回客户机剪贴板。
        .onDisappear {
            if activeState == .key { clipboard?.pull() }
        }
        // 工具栏从窗口打开起就在，虚拟机跑起来之前按钮不可点：按钮晚出现会把标题栏撑高，画面跟着往下跳。
        .toolbar {
            Group {
                Button { showingImages = true } label: { Label("Disk Images", systemImage: "opticaldisc") }
                    .help(model.canAttachImages(name) ? "Discs and Disk Images" : "Disk images can only be attached to virtual machines started in this app that have a USB controller")
                    .disabled(!model.canAttachImages(name))
                    .popover(isPresented: $showingImages, arrowEdge: .bottom) {
                        // 文件选择面板一弹出 popover 就会关闭，所以先关 popover，由窗口弹面板。
                        ImagesPopover(name: name) {
                            showingImages = false
                            choosingImage = true
                        }
                    }
                if let config, config.supportsShares {
                    Button { showingShares = true } label: { Label("Shared Folders", systemImage: "folder") }
                        .help("Shared Folders")
                }
                Button { showingForwards = true } label: { Label("Port Forwarding", systemImage: "arrow.right.arrow.left") }
                    .help("Port Forwarding")
                if let config, config.supportsMicrophone {
                    Button {
                        let on = !config.microphone
                        if model.setMicrophone(name, on) { announce(on ? String(l10n: "The microphone will be connected at the next startup") : String(l10n: "The microphone will be disconnected at the next startup")) }
                    } label: {
                        Label(config.microphone ? "Turn Off Microphone" : "Turn On Microphone", systemImage: config.microphone ? "mic.fill" : "mic.slash")
                    }
                    .help(config.microphone ? "Microphone: On (takes effect at next startup)" : "Microphone: Off (takes effect at next startup)")
                }
                if let config, config.supportsAudio {
                    Button {
                        let on = !config.audio
                        if model.setAudio(name, on) { announce(on ? String(l10n: "Sound will be turned on at the next startup") : String(l10n: "Sound will be turned off at the next startup")) }
                    } label: {
                        Label(config.audio ? "Turn Off Sound" : "Turn On Sound", systemImage: config.audio ? "speaker.wave.2.fill" : "speaker.slash")
                    }
                    .help(config.audio ? "Sound: On (takes effect at next startup)" : "Sound: Off (takes effect at next startup)")
                }
                if model.canSuspend(name) {
                    if suspending {
                        busyItem("Suspending…")
                    } else {
                        Button {
                            suspending = true
                            Task {
                                await model.suspend(name)
                                suspending = false
                            }
                        } label: { Label("Suspend", systemImage: "pause.fill") }
                        .help("Suspend")
                    }
                }
                if stopping {
                    busyItem("Shutting down…")
                } else {
                    Button { Task { await model.stop(name) } } label: { Label("Shut Down", systemImage: "power") }
                        .help("Shut Down")
                        .disabled(suspending)
                }
            }
            .disabled(runner == nil && !runningElsewhere)
        }
        // 用 sheet 而不是 popover：添加时要弹文件选择面板，popover 一失去焦点就关闭。
        .sheet(isPresented: $showingShares) { SharesSheet(name: name) }
        .sheet(isPresented: $showingForwards) { ForwardsSheet(name: name) }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: ImagesPopover.imageTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task {
                await model.attachImages(name, urls)
                showingImages = true
            }
        }
    }
}

extension MachineWindow {
    /// 启动到出画面之前的占位，与客户机画面同为黑底，出画面时不闪一下。
    fileprivate var startingView: some View {
        ZStack {
            Color.black
            ProgressView(startingTitle)
        }
        .environment(\.colorScheme, .dark)
    }

    /// 画面顶部浮着的胶囊提示。
    fileprivate func banner(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
            .shadow(radius: 6, y: 2)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 一次文件复制的进度与取消按钮。
    fileprivate func transferRow(_ transfer: GuestTransferActivity) -> some View {
        HStack(spacing: 10) {
            ProgressView(transfer.progress)
                .frame(width: 300)
            Button { transfer.progress.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Cancel Copy")
                .accessibilityLabel("Cancel Copy")
        }
    }

    /// 工具栏里代替按钮的转圈，占着按钮的位置，其他按钮不跟着挪。
    fileprivate func busyItem(_ text: LocalizedStringKey) -> some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 28, height: 28)
            .help(text)
            .accessibilityLabel(text)
    }

    /// 开机失败的原因由窗口正中显示，从 `lastError` 取走，免得再弹一次错误弹窗。
    /// 必须紧跟在 `start` / `takeOver` 返回之后、中间不能有挂起点，弹窗才来不及出现。
    fileprivate func recordFailure() {
        failed = runner == nil
        failure = failed ? model.lastError : nil
        if failed { model.lastError = nil }
    }

    /// 从挂起状态恢复后等第一帧的时长：客户机显示器醒着时恢复后很快就有画面。
    fileprivate static let restoredFrameTimeout: Duration = .seconds(3)

    /// 画面顶部的短暂提示。改了声音或麦克风且与本进程开机时的设置不同时，补一句这次开机不能挂起。
    fileprivate func announce(_ text: String) {
        var text = text
        if let runner, runner.canSuspend, let saved = model.config(of: name), saved.audioDiffers(from: runner.config) {
            text = String(l10n: "\(text). Until you change it back, this session can't be suspended")
        }
        withAnimation { notice = text }
    }
}

/// 窗口工具栏里的共享目录。本进程运行的 macOS 客户机可实时增删，其他情况关机后才能改。
private struct SharesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String

    var body: some View {
        let editable = model.canEditSharesLive(name)
        VStack(spacing: 0) {
            Form {
                if let config = model.config(of: name) {
                    SharesSection(vmName: name, config: config, editable: editable)
                }
                if !editable {
                    Text("While running, only macOS guests started in this app can change shared folders. For other virtual machines, shut down first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460)
        .acceptsShareDrops(vmName: name, editable: editable)
        .reportsErrors()
    }
}

private struct ForwardsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let config = model.config(of: name) {
                    ForwardsSection(vmName: name, config: config)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460)
        .reportsErrors()
    }
}

/// 窗口工具栏里的光盘与磁盘映像：列出这次开机热插的映像，可接入、推出。
private struct ImagesPopover: View {
    @Environment(AppModel.self) private var model
    let name: String
    let onAttach: () -> Void

    /// VZ 只认原始格式与 ASIF；DMG 只有未压缩的读写格式能接入，其余在接入时报错。
    static let imageTypes: [UTType] = [.diskImage] + ["iso", "img", "raw", "asif", "cdr", "dmg"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        let images = model.attachedImages[name] ?? []
        let busy = model.changingImages.contains(name)
        VStack(alignment: .leading, spacing: 12) {
            Text("Discs and Disk Images").font(.headline)
            if images.isEmpty {
                Text("No discs or disk images attached.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(images) { image in row(image, busy: busy) }
                }
            }
            HStack(spacing: 8) {
                Button(action: onAttach) { Label("Attach Disk Image…", systemImage: "plus") }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
            Text("Images appear as USB drives in the guest. Eject them in the guest before ejecting them here, or data the guest hasn't finished writing may be lost.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 320)
    }

    private func row(_ image: AttachedImage, busy: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(image.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(image.readOnly ? "Read-Only" : "Read-Write").font(.caption).foregroundStyle(.secondary)
            }
            .help(image.url.path)
            Spacer()
            Button { Task { await model.ejectImage(name, id: image.id) } } label: { Image(systemName: "eject.fill") }
                .buttonStyle(.borderless)
                .help("Eject")
                .accessibilityLabel("Eject \(image.url.lastPathComponent)")
                .disabled(busy)
        }
    }
}
