import AppKit
@testable import MacVMEngine
import MacVMModel
import Testing

@MainActor
final class RecordingBackend: DisplayBackend {
    var keys: [(qnum: UInt32, down: Bool)] = []
    func sendPointer(buttons: UInt8, x: UInt16, y: UInt16) {}
    func scroll(up: Bool, buttons: UInt8, x: UInt16, y: UInt16) {}
    func sendKey(qnum: UInt32, down: Bool) { keys.append((qnum, down)) }
    func close() {}
}

@MainActor
struct DisplayKeyTests {
    /// 左 Command 的 macOS 键码、设备相关修饰位与映射到的 Windows 键扫描码。
    let command: (code: UInt16, mask: UInt, qnum: UInt32) = (0x37, 0x08, 0xdb)

    func flags(code: UInt16, raw: UInt) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw), timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    func key(_ type: NSEvent.EventType, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: code)!
    }

    func makeView() -> (QEMUDisplayView, RecordingBackend, NSWindow) {
        let view = QEMUDisplayView(bundle: VMBundle(url: URL(filePath: "/vms/win.macvm")))
        let backend = RecordingBackend()
        view.backend = backend
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        return (view, backend, window)
    }

    @Test func leavingTheWindowReleasesHeldKeys() {
        let (view, backend, window) = makeView()
        view.flagsChanged(with: flags(code: command.code, raw: NSEvent.ModifierFlags.command.rawValue | command.mask))
        view.keyDown(with: key(.keyDown, code: 0x04))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        let released = backend.keys.filter { !$0.down }.map(\.qnum)
        #expect(Set(released) == [command.qnum, 0x23])
        // 回到窗口后再松开的键已经放开过，不再发送。
        backend.keys.removeAll()
        view.flagsChanged(with: flags(code: command.code, raw: 0))
        view.keyUp(with: key(.keyUp, code: 0x04))
        #expect(backend.keys.isEmpty)
    }

    @Test func closingTheWindowReleasesHeldKeys() {
        let (view, backend, window) = makeView()
        view.flagsChanged(with: flags(code: command.code, raw: NSEvent.ModifierFlags.command.rawValue | command.mask))
        window.contentView = nil
        #expect(backend.keys.last.map { [$0.qnum: $0.down] } == [command.qnum: false])
    }
}
