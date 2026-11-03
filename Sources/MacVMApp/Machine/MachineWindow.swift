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

    private var bundle: VMBundle? { try? model.library.bundle(named: name) }
    private var config: VMConfig? { try? bundle?.loadConfig() }
    private var isRunning: Bool { model.summary(name)?.state == .running }
    private var runningElsewhere: Bool { isRunning && !model.isRunningHere(name) }

    var body: some View {
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
                if config?.supportsSuspend == true {
                    Button { Task { await model.suspend(name) } } label: { Label("挂起", systemImage: "pause.fill") }
                }
                Button { Task { await model.stop(name) } } label: { Label("关机", systemImage: "power") }
            }
        }
    }
}
