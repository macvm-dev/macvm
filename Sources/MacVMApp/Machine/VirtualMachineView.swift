import AppKit
import MacVMEngine
import MacVMModel
import SwiftUI

struct VirtualMachineView: NSViewRepresentable {
    let runner: VZRunner

    func makeNSView(context: Context) -> NSView { runner.makeDisplayView() }

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
