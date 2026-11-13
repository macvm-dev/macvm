import Foundation
@testable import MacVMEngine
import MacVMModel
import Testing

struct ControlProtocolTests {
    @Test(arguments: [
        ControlRequest.status, .stop(force: true), .stop(force: false), .suspend, .pause, .resume,
        .connect(port: 6100), .screenshot(path: "/tmp/a.png"), .display(width: 2560, height: 1600), .applyForwards,
    ])
    func roundTrip(request: ControlRequest) throws {
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func stopDefaultsToGraceful() throws {
        #expect(try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"op":"stop"}"#.utf8)) == .stop(force: false))
    }

    @Test(arguments: [
        MacVMError.notRunning("vm"), .alreadyRunning("vm"), .io("写入失败"), .timeout("超时"), .invalidConfig("坏配置"), .engine("出错"),
    ])
    func failureKeepsErrorCode(error: MacVMError) {
        #expect(ControlResponse(failure: error).failure == error)
    }

    @Test func unknownFailureCodeIsEngine() {
        #expect(ControlResponse(ok: false, errorCode: "bad_request", message: "坏请求").failure == .engine("坏请求"))
        #expect(ControlResponse(ok: true).failure == nil)
    }
}

struct UnixSocketTests {
    @Test func exactReadLineLeavesFollowingBytesInDescriptor() throws {
        var ends: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        let reader = UnixSocket(fd: ends[0]), writer = UnixSocket(fd: ends[1])
        try writer.writeAll(Data("{\"ok\":true}\nrest".utf8))
        #expect(try reader.readLine(exact: true) == Data("{\"ok\":true}".utf8))
        #expect(reader.takeBuffered().isEmpty)
        var rest = [UInt8](repeating: 0, count: 4)
        #expect(read(reader.fd, &rest, rest.count) == 4)
        #expect(rest == Array("rest".utf8))
    }

    @Test func acceptReturnsBlockingConnectionAndStopsWhenCancelled() throws {
        let path = "/tmp/macvm-test-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocket.listen(at: path)
        defer { unlink(path) }
        var wake: [Int32] = [-1, -1]
        #expect(pipe(&wake) == 0)
        defer { for end in wake { close(end) } }
        let client = try UnixSocket.connect(to: path)
        let accepted = try #require(listener.accept(cancel: wake[0]))
        #expect(fcntl(accepted.fd, F_GETFL) & O_NONBLOCK == 0)
        var byte: UInt8 = 0
        #expect(write(wake[1], &byte, 1) == 1)
        #expect(listener.accept(cancel: wake[0]) == nil)
        withExtendedLifetime(client) {}
    }
}

struct AttachedImageTests {
    @Test func discImagesAttachReadOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.iso", "b.ISO", "c.dmg", "d.img"] {
            try Data().write(to: dir.appending(path: name))
        }
        #expect(AttachedImage.prefersReadOnly(dir.appending(path: "a.iso")))
        #expect(AttachedImage.prefersReadOnly(dir.appending(path: "b.ISO")))
        #expect(AttachedImage.prefersReadOnly(dir.appending(path: "c.dmg")))
        #expect(!AttachedImage.prefersReadOnly(dir.appending(path: "d.img")))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dir.appending(path: "d.img").path)
        #expect(AttachedImage.prefersReadOnly(dir.appending(path: "d.img")))
    }
}

@MainActor
struct StopLatchTests {
    @Test(arguments: [(MachineStopReason.guestShutdown, true), (.forced, true), (.suspended, false), (.error("崩溃"), false)])
    func poweredOffMarkerFollowsStopReason(reason: MachineStopReason, marked: Bool) throws {
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appending(path: "macvm-latch-\(UUID().uuidString).macvm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        FileManager.default.createFile(atPath: bundle.poweredOffMarkerURL.path, contents: nil)

        let latch = StopLatch(bundle: bundle, lock: try BundleLock.acquire(bundle))
        latch.started()
        #expect(!bundle.wasPoweredOff)
        latch.fire(reason)
        #expect(bundle.wasPoweredOff == marked)
    }
}

struct DetachedRunTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "macvm-detached-\(UUID().uuidString)")

    private func bundle(_ mode: NetworkConfig.Mode) throws -> VMBundle {
        let bundle = VMBundle(url: VMLibrary(root: root.appending(path: "vms")).bundleURL(named: "vm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        try bundle.saveConfig(VMConfig(name: "vm", os: .linux, cpuCount: 1, memorySize: 1 << 30, disks: [],
                                       networks: [NetworkConfig(mode: mode, interface: mode == .bridged ? "en0" : nil)]))
        return bundle
    }

    /// 最小的 App 包：属性列表、主程序与 `Contents/Resources/bin/macvm`。
    private func app() throws -> (cli: URL, executable: URL) {
        let fm = FileManager.default
        let contents = root.appending(path: "Test.app/Contents")
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Resources/bin"), withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleExecutable": "Test", "CFBundleIdentifier": "test.macvm.\(UUID().uuidString)"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        let executable = contents.appending(path: "MacOS/Test"), cli = contents.appending(path: "Resources/bin/macvm")
        for file in [executable, cli] { fm.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o755]) }
        return (cli, executable)
    }

    @Test func natRunsTheCLI() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try DetachedRun.command(for: bundle(.nat), cli: "/usr/local/bin/macvm") { _, _ in
            Issue.record("NAT 不该查签名")
            return false
        }
        #expect(command.executable == "/usr/local/bin/macvm")
        #expect(command.arguments == ["run", "vm", "--detached"])
    }

    @Test func bridgedRunsTheAppExecutableThroughSymlink() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (cli, executable) = try app()
        let link = root.appending(path: "bin/macvm")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)

        var checked: [String] = []
        let command = try DetachedRun.command(for: bundle(.bridged), cli: link.path) { key, url in
            checked.append(key)
            return url.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath()
        }
        #expect(checked == ["com.apple.vm.networking"])
        #expect(URL(filePath: command.executable).resolvingSymlinksInPath() == executable.resolvingSymlinksInPath())
        #expect(command.arguments == ["--run-detached", "vm"])
    }

    @Test func bridgedWithoutEntitlementFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (cli, _) = try app()
        let bundle = try bundle(.bridged)
        let error = #expect(throws: MacVMError.self) {
            try DetachedRun.command(for: bundle, cli: cli.path) { _, _ in false }
        }
        #expect(error?.code == "entitlement_missing")
    }

    @Test func bridgedOutsideAppFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try bundle(.bridged)
        let error = #expect(throws: MacVMError.self) {
            try DetachedRun.command(for: bundle, cli: "/usr/local/bin/macvm") { _, _ in true }
        }
        #expect(error?.code == "entitlement_missing")
    }

    @Test func appRunTarget() {
        #expect(DetachedRun.appRunTarget(["/Applications/MacVM.app/Contents/MacOS/MacVM", "--run-detached", "vm"]) == "vm")
        #expect(DetachedRun.appRunTarget(["/Applications/MacVM.app/Contents/MacOS/MacVM"]) == nil)
        #expect(DetachedRun.appRunTarget(["/Applications/MacVM.app/Contents/MacOS/MacVM", "--run-detached"]) == nil)
    }
}
