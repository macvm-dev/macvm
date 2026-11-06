import AppKit
import MacVMEngine
import MacVMModel
import SwiftUI

struct VirtualMachineView: NSViewRepresentable {
    let runner: VZRunner
    /// 最多等第一帧多久。
    var firstFrameTimeout = VZRunner.firstFrameTimeout
    /// 视图收到客户机的第一帧（参数为 true），或等满 `firstFrameTimeout` 放弃（false）时调用。
    var onFirstFrame: ((Bool) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = runner.makeDisplayView()
        if let onFirstFrame {
            let timeout = firstFrameTimeout
            Task {
                onFirstFrame(await VZRunner.waitForFirstFrame(in: view, timeout: timeout))
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        VZRunner.detachDisplayView(view)
    }
}

/// QEMU 引擎的画面，经 VNC 连到虚拟机，不要求虚拟机在本进程运行。
struct QEMUMachineView: NSViewRepresentable {
    let bundle: VMBundle

    func makeNSView(context: Context) -> QEMUDisplayView { QEMUDisplayView(bundle: bundle) }

    func updateNSView(_ view: QEMUDisplayView, context: Context) {}

    static func dismantleNSView(_ view: QEMUDisplayView, coordinator: ()) {
        view.disconnect()
    }
}
