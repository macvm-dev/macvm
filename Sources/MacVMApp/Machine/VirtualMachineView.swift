import AppKit
import MacVMEngine
import SwiftUI

struct VirtualMachineView: NSViewRepresentable {
    let runner: VZRunner

    func makeNSView(context: Context) -> NSView { runner.makeDisplayView() }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        VZRunner.detachDisplayView(view)
    }
}
