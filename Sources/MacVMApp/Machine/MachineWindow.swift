import MacVMEngine
import MacVMModel
import SwiftUI

/// 一台虚拟机的窗口：打开即在本进程启动（或接上已在本进程运行的）虚拟机。
/// QEMU 引擎的画面经 VNC 显示，在别的进程里运行的也能接上；VZ 的画面只能在运行它的进程里显示。
struct MachineWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var runner: (any MachineRunner)?
    @State private var failed = false
    @State private var showingShares = false
    /// 改了声音或麦克风后在画面顶部短暂显示的说明。
    @State private var notice: String?

    private var isRunning: Bool { model.summary(name)?.state == .running }
    private var runningElsewhere: Bool { isRunning && !model.isRunningHere(name) }

    var body: some View {
        let bundle = try? model.library.bundle(named: name)
        let config = model.config(of: name)
        Group {
            if let vz = runner as? VZRunner {
                VirtualMachineView(runner: vz)
            } else if let bundle, config?.engine == .qemu, runner != nil || runningElsewhere {
                QEMUMachineView(bundle: bundle)
            } else if runningElsewhere {
                ContentUnavailableView {
                    Label("在后台进程中运行", systemImage: "terminal")
                } description: {
                    Text("这台虚拟机由 macvm start 在另一个进程中运行，VZ 的画面只能在运行它的进程里显示。关机后可在这里重新启动。")
                } actions: {
                    Button("关机") { Task { await model.stop(name) } }
                }
            } else if failed {
                ContentUnavailableView("无法启动", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView("正在启动…")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .overlay(alignment: .top) {
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .shadow(radius: 6, y: 2)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { withAnimation { self.notice = nil } }
            }
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { notice = nil }
        }
        .navigationTitle(name)
        .task(id: name) {
            guard !runningElsewhere else { return }
            runner = await model.start(name)
            failed = runner == nil
        }
        .onChange(of: isRunning) { wasRunning, running in
            // 虚拟机停止（客户机关机、挂起）后窗口没有内容可显示。
            if wasRunning, !running { dismiss() }
        }
        .onChange(of: model.isRunningHere(name)) { _, running in
            if !running { runner = nil }
        }
        .toolbar {
            if runner != nil || runningElsewhere {
                if let config, config.supportsShares {
                    Button { showingShares = true } label: { Label("共享目录", systemImage: "folder") }
                        .help("共享目录")
                }
                if let config, config.supportsMicrophone {
                    Button {
                        let on = !config.microphone
                        if model.setMicrophone(name, on) { announce(on ? "下次开机时接上麦克风" : "下次开机时断开麦克风") }
                    } label: {
                        Label(config.microphone ? "关闭麦克风" : "打开麦克风", systemImage: config.microphone ? "mic.fill" : "mic.slash")
                    }
                    .help(config.microphone ? "麦克风：开（下次开机生效）" : "麦克风：关（下次开机生效）")
                }
                if let config, config.supportsAudio {
                    Button {
                        let on = !config.audio
                        if model.setAudio(name, on) { announce(on ? "下次开机时打开声音" : "下次开机时关闭声音") }
                    } label: {
                        Label(config.audio ? "关闭声音" : "打开声音", systemImage: config.audio ? "speaker.wave.2.fill" : "speaker.slash")
                    }
                    .help(config.audio ? "声音：开（下次开机生效）" : "声音：关（下次开机生效）")
                }
                if config?.supportsSuspend == true {
                    Button { Task { await model.suspend(name) } } label: { Label("挂起", systemImage: "pause.fill") }
                }
                Button { Task { await model.stop(name) } } label: { Label("关机", systemImage: "power") }
            }
        }
        // 用 sheet 而不是 popover：添加时要弹文件选择面板，popover 一失去焦点就关闭。
        .sheet(isPresented: $showingShares) { SharesSheet(name: name) }
    }
}

extension MachineWindow {
    /// 改了声音或麦克风后的提示。与本进程开机时的设置不同时，补一句这次开机不能挂起。
    fileprivate func announce(_ text: String) {
        var text = text
        if let runner, runner.config.supportsSuspend, let saved = model.config(of: name), saved.audioDiffers(from: runner.config) {
            text += "；改回之前这次开机不能挂起"
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
                    Text("运行中只有在本 App 里启动的 macOS 客户机能实时修改共享目录，其他情况请关机后修改。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460)
    }
}
