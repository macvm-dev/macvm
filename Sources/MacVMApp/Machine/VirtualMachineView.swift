import AppKit
import MacVMEngine
import SwiftUI

struct VirtualMachineView: NSViewRepresentable {
    let runner: VMRunner

    func makeNSView(context: Context) -> NSView { runner.makeDisplayView() }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        VMRunner.detachDisplayView(view)
    }
}
