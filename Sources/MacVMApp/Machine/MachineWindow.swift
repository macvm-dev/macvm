import MacVMEngine
import MacVMModel
import SwiftUI

/// 一台虚拟机的窗口：打开即在本进程启动（或接上已在本进程运行的）虚拟机。
struct MachineWindow: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var runner: VMRunner?
    @State private var failed = false

    var body: some View {
        Group {
            if let runner {
                VirtualMachineView(runner: runner)
            } else if model.summary(name)?.state == .running, !model.isRunningHere(name) {
                ContentUnavailableView {
                    Label("在后台进程中运行", systemImage: "terminal")
                } description: {
                    Text("这台虚拟机由 macvm start 在另一个进程中运行，画面只能在运行它的进程里显示。关机后可在这里重新启动。")
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
            guard model.summary(name)?.state != .running || model.isRunningHere(name) else { return }
            runner = await model.start(name)
            failed = runner == nil
        }
        .onChange(of: model.isRunningHere(name)) { _, running in
            if !running { runner = nil }
        }
        .toolbar {
            if runner != nil {
                if (try? model.library.bundle(named: name).loadConfig().supportsSuspend) == true {
                    Button { Task { await model.suspend(name) } } label: { Label("挂起", systemImage: "pause.fill") }
                }
                Button { Task { await model.stop(name) } } label: { Label("关机", systemImage: "power") }
            }
        }
    }
}
