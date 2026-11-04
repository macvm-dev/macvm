import Foundation
@testable import MacVMEngine
import MacVMModel
import Testing
import Virtualization

struct DHCPLeasesTests {
    let sample = """
    {
    	name=old
    	ip_address=192.168.64.2
    	hw_address=1,2:0:0:a:b:c
    	lease=0x60000000
    }
    {
    	name=new
    	ip_address=192.168.64.9
    	hw_address=1,2:0:0:a:b:c
    	lease=0x70000000
    }
    {
    	name=other
    	ip_address=192.168.64.3
    	hw_address=1,2:0:0:a:b:d
    	lease=0x70000000
    }
    """

    @Test func picksNewestLeaseForPaddedMAC() {
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0c", in: sample) == "192.168.64.9")
    }

    @Test func fallsBackToHostnameForDUIDClients() {
        let duid = sample + """

        {
        	name=deb
        	ip_address=192.168.64.20
        	hw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11
        	lease=0x70000000
        }
        """
        let beforeExpiry = Date(timeIntervalSince1970: 0x6FFF_FFFF)
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0f", hostname: "deb", in: duid, now: beforeExpiry) == "192.168.64.20")
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0f", hostname: "deb", in: duid, now: Date(timeIntervalSince1970: 0x7000_0001)) == nil)
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0f", in: duid) == nil)
    }

    @Test func unknownMAC() {
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0e", in: sample) == nil)
    }
}

struct ControlProtocolTests {
    @Test(arguments: [ControlRequest.status, .stop(force: true), .stop(force: false), .suspend, .pause, .resume])
    func roundTrip(request: ControlRequest) throws {
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func stopDefaultsToGraceful() throws {
        #expect(try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"op":"stop"}"#.utf8)) == .stop(force: false))
    }
}

struct ConfigBuilderTests {
    @Test func windowsDropsAudio() async throws {
        let library = VMLibrary(root: FileManager.default.temporaryDirectory.appending(path: "macvm-tests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: library.root) }
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("MACVM_GUEST_DIR", repo.appending(path: "guest/firmware/dist").path, 1)
        let bundle = try await VMFactory.createEFIGuest(.init(name: "w", os: .windows, cpuCount: 2, memorySize: 2 << 30, diskSize: 1 << 30), in: library)
        try await RunnerFactory.prepare(bundle)
        let vz = try ConfigBuilder(bundle: bundle, config: bundle.loadConfig()).build(validate: false)
        #expect(vz.audioDevices.isEmpty)
        let first = vz.storageDevices.first?.attachment as? VZDiskImageStorageDeviceAttachment
        #expect(first?.url.lastPathComponent == WindowsSupport.bootImageName)
        #expect(vz.keyboards.count == 1)
    }

    @Test func linuxConfigurationValidates() async throws {
        let library = VMLibrary(root: FileManager.default.temporaryDirectory.appending(path: "macvm-tests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: library.root) }
        let bundle = try await VMFactory.createEFIGuest(.init(name: "t", os: .linux, cpuCount: 2, memorySize: 1 << 30, diskSize: 1 << 30), in: library)
        let config = try bundle.loadConfig()
        #expect(config.networks.first?.macAddress != nil)
        let vz = try ConfigBuilder(bundle: bundle, config: config).build(validate: Entitlements.has(Entitlements.virtualization))
        #expect(vz.cpuCount == 2)
        #expect(vz.storageDevices.count == 1)
        #expect(vz.audioDevices.count == 1)
        #expect(try DiskImage.allocatedSize(at: bundle.diskURL).physical < 1 << 20)
    }
}

struct QEMUCommandTests {
    let qemu = QEMUInstallation(binary: URL(filePath: "/q"), firmwareCode: URL(filePath: "/code.fd"), firmwareVarsTemplate: URL(filePath: "/vars.fd"))

    @Test func windowsInstallArguments() throws {
        let bundle = VMBundle(url: URL(filePath: "/vms/win.macvm"))
        let config = VMConfig(name: "win", os: .windows, engine: .qemu, cpuCount: 4, memorySize: 8 << 30,
                              disks: [DiskConfig(path: "disk.img", bus: .nvme), DiskConfig(path: "data.img", bus: .nvme)],
                              networks: [NetworkConfig(macAddress: "02:00:00:00:00:01")],
                              installMedia: ["/isos/win.iso", "setup.img"])
        let args = try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments().joined(separator: " ")
        #expect(args.contains("-m 8192M"))
        #expect(args.contains("nvme,drive=disk0,serial=macvm0,bootindex=1"))
        #expect(args.contains("nvme,drive=disk1,serial=macvm1 "))
        #expect(args.contains("file=/isos/win.iso,media=cdrom"))
        #expect(args.contains("drive=media0,removable=on,bootindex=0"))
        #expect(args.contains("file=/vms/win.macvm/setup.img"))
        #expect(args.contains("hostfwd=unix:"))
        #expect(args.contains("mac=02:00:00:00:00:01"))
    }

    @Test func installedWindowsUsesVirtioGPU() throws {
        let bundle = VMBundle(url: URL(filePath: "/vms/win.macvm"))
        var config = VMConfig(name: "win", os: .windows, engine: .qemu, cpuCount: 2, memorySize: 4 << 30,
                              disks: [DiskConfig(path: "disk.img", bus: .nvme)], installMedia: ["/isos/win.iso"])
        #expect(try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments().contains("ramfb"))
        config.installMedia = []
        let args = try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments()
        #expect(args.contains("virtio-gpu-pci") && !args.contains("ramfb"))
        #expect(args.contains("unix:" + QEMUCommand.vncSocket(bundle).path))
    }

    @Test func bundledQEMUUsesSpiceGL() throws {
        var bundled = qemu
        bundled.dataDirectory = URL(filePath: "/q/share")
        bundled.displayLibrary = URL(filePath: "/q/lib/libMacVMDisplay.dylib")
        bundled.direct3D = true
        bundled.bundleRoot = URL(filePath: "/q")
        let bundle = VMBundle(url: URL(filePath: "/vms/win.macvm"))
        var config = VMConfig(name: "win", os: .windows, engine: .qemu, cpuCount: 2, memorySize: 4 << 30,
                              disks: [DiskConfig(path: "disk.img", bus: .nvme)], installMedia: ["/isos/win.iso"])
        let args = try QEMUCommand(bundle: bundle, config: config, qemu: bundled).arguments()
        let joined = args.joined(separator: " ")
        // 安装期与装好后是同一个设备，Windows 不会因换设备重新识别显卡。
        let device = try #require(args.first { $0.hasPrefix("virtio-ramfb-gl,id=gpu,blob=true,hostmem=2147483648,") })
        #expect(device.hasSuffix(",neptune=true"))
        // 初始尺寸不小于配置，本机有更大的屏幕时取屏幕的。
        let xres = try #require(device.split(separator: ",").first { $0.hasPrefix("xres=") }.flatMap { Int($0.dropFirst(5)) })
        #expect(xres >= config.display.width)
        #expect(joined.contains("-spice unix=on,addr=\(QEMUCommand.spiceSocket(bundle).path),disable-ticketing=on,gl=on"))
        #expect(!args.contains("-vnc") && args.starts(with: ["-L", "/q/share"]))
        #expect(joined.contains("-bios /code.fd -drive if=pflash,unit=1,"))
        #expect(joined.contains("-accel hvf,ipa-granule-size=4096"))
        #expect(bundled.environment["RENDER_SERVER_EXEC_PATH"] == "/q/bin/virgl_render_server")
        config.os = .linux
        #expect(!(try QEMUCommand(bundle: bundle, config: config, qemu: bundled).arguments().joined().contains("neptune")))
    }

    @Test func guestSizeFitsEDID() {
        #expect(QEMUCommand.fittingEDID((2560, 1600)) == (2560, 1600))
        let (w, h) = QEMUCommand.fittingEDID((5120, 2880))
        #expect(w * h <= QEMUCommand.maximumGuestPixels && w % 2 == 0 && h % 2 == 0)
        #expect(abs(Double(w) / Double(h) - 16.0 / 9.0) < 0.01)
    }

    @Test func rejectsDirectorySharing() {
        let bundle = VMBundle(url: URL(filePath: "/vms/a.macvm"))
        let config = VMConfig(name: "a", os: .linux, engine: .qemu, cpuCount: 2, memorySize: 1 << 30, disks: [],
                              shares: [ShareConfig(hostPath: "/tmp", tag: "tmp")])
        #expect(throws: MacVMError.self) { _ = try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments() }
    }
}

struct WindowsUnattendTests {
    let options = WindowsUnattend.Options(computerName: "win", user: "a<b", password: "p&w", locale: "zh-CN", sshPublicKey: "ssh-ed25519 AAA macvm")

    @Test func installScriptIsASCIIWithCRLF() {
        let script = WindowsUnattend.installScript()
        let ascii = script.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(ascii)
        #expect(!script.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(script.contains("MACVMDATA") && script.contains("MACVMSETUP"))
    }

    @Test func setupScriptInstallsAgentOnlyWhenBundled() {
        var o = options
        #expect(!WindowsUnattend.setupScript(o).contains("Register-ScheduledTask"))
        o.installAgent = true
        let script = WindowsUnattend.setupScript(o)
        #expect(script.contains("Register-ScheduledTask") && script.contains("-UserId 'a<b'"))
        #expect(script.contains("-LocalPort \(AgentProtocol.port)"))
    }

    @Test func setupScriptPlacesGPUDriverBeforeAgentStarts() throws {
        var o = options
        o.installAgent = true
        #expect(!WindowsUnattend.setupScript(o).contains(WindowsGPUDriver.guestDirectory))
        o.installGPUDriver = true
        let script = WindowsUnattend.setupScript(o)
        let copy = try #require(script.range(of: "-Destination '\(WindowsGPUDriver.guestDirectory)'"))
        let agent = try #require(script.range(of: "Start-ScheduledTask"))
        #expect(copy.lowerBound < agent.lowerBound)
    }

    @Test func productKeyIsActivatedAtFirstLogon() throws {
        #expect(try WindowsInstaller.normalizeProductKey("abcde fghij-klmno-pqrst-uvwxy") == "ABCDE-FGHIJ-KLMNO-PQRST-UVWXY")
        #expect(throws: MacVMError.self) { try WindowsInstaller.normalizeProductKey("ABCDE-FGHIJ") }
        var o = options
        #expect(!WindowsUnattend.setupScript(o).contains("slmgr"))
        o.productKey = "ABCDE-FGHIJ-KLMNO-PQRST-UVWXY"
        let script = WindowsUnattend.setupScript(o)
        #expect(script.contains(#"slmgr.vbs /ipk ABCDE-FGHIJ-KLMNO-PQRST-UVWXY"#) && script.contains("slmgr.vbs /ato"))
        // 部署阶段仍用通用密钥，用户的密钥不进应答文件。
        #expect(!WindowsUnattend.unattend(o).contains("ABCDE"))
    }

    @Test func systemUUIDFollowsMachineIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "macvm-uuid-\(UUID().uuidString).macvm")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        #expect(QEMUCommand.systemUUID(bundle) == nil)
        try Data([1, 2, 3]).write(to: bundle.machineIdentifierURL)
        let first = try #require(QEMUCommand.systemUUID(bundle))
        #expect(QEMUCommand.systemUUID(bundle) == first && UUID(uuidString: first) != nil && first != "00000000-0000-0000-0000-000000000000")
        try Data([4, 5, 6]).write(to: bundle.machineIdentifierURL)
        #expect(QEMUCommand.systemUUID(bundle) != first)
    }

    @Test func acceleratedWindowsCannotSwitchToVZ() throws {
        var config = VMConfig(name: "win", os: .windows, engine: .qemu, cpuCount: 2, memorySize: 4 << 30, disks: [])
        // 旧配置文件没有这个字段。
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        json["graphicsAcceleration"] = nil
        let old = try JSONDecoder().decode(VMConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.graphicsAcceleration)
        config.graphicsAcceleration = true
        #expect(throws: MacVMError.self) { try config.switchEngine(to: .vz) }
        #expect(config.engine == .qemu)
    }

    @Test func encodedPowerShellIsUTF16LEBase64() throws {
        let script = "Write-Output '你好'\nexit 3"
        let command = AgentInstaller.encodedPowerShell(script)
        let encoded = try #require(command.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        #expect(String(data: data, encoding: .utf16LittleEndian) == script)
    }

    @Test func unattendEscapesXML() throws {
        let xml = WindowsUnattend.unattend(options)
        #expect(xml.contains("<Name>a&lt;b</Name>"))
        #expect(xml.contains("<Value>p&amp;w</Value>"))
        _ = try XMLDocument(xmlString: xml)
        _ = try XMLDocument(xmlString: WindowsUnattend.autounattend())
    }
}

struct MoreControlProtocolTests {
    @Test(arguments: [ControlRequest.connect(port: 6100), .screenshot(path: "/tmp/a.png"), .display(width: 2560, height: 1600)])
    func roundTrip(request: ControlRequest) throws {
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    }
}

struct CursorShapeTests {
    @Test func decodesFixtures() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../protocol/fixtures/cursors.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let shapes = try lines.map { try JSONDecoder().decode(AgentProtocol.CursorShape.self, from: Data($0.utf8)) }
        #expect(shapes.count == 3)
        let image = try #require(Data(base64Encoded: shapes[0].bgra).flatMap { cursorImage(bgra: $0, width: shapes[0].width, height: shapes[0].height) })
        #expect(image.width == 2 && image.height == 1 && shapes[0].hot_x == 1)
        #expect(shapes[1].hidden && cursorImage(bgra: Data(), width: 0, height: 0) == nil)
        #expect(shapes[2].system == "ibeam" && !shapes[2].hidden)
    }
}

struct LinuxDesktopTests {
    @Test func ubuntuPicksLatestPointReleaseOfDesktopArm64() throws {
        let sums = """
        c2afd538 *ubuntu-26.04-desktop-arm64.iso
        c8b5d454 *ubuntu-26.04-preinstalled-desktop-arm64+raspi.img.xz
        C54D1964 *ubuntu-26.04.1-desktop-arm64.iso
        a7110f6c *ubuntu-26.04.1-desktop-riscv64.iso
        601e30fb *ubuntu-26.04.1-desktop-amd64.iso
        """
        let release = try #require(LinuxDesktop.ubuntuRelease(sha256sums: sums, series: "26.04", base: URL(string: "https://example.com/r/")!))
        #expect(release.fileName == "ubuntu-26.04.1-desktop-arm64.iso")
        #expect(release.url.absoluteString == "https://example.com/r/ubuntu-26.04.1-desktop-arm64.iso")
        #expect(release.sha256 == "c54d1964")
    }

    @Test func ubuntuWithoutArm64DesktopIsNil() {
        #expect(LinuxDesktop.ubuntuRelease(sha256sums: "aa *ubuntu-26.04-desktop-amd64.iso", series: "26.04", base: URL(string: "https://e/")!) == nil)
    }

    @Test func fedoraPicksNewestFinalWorkstationAarch64() throws {
        let json = """
        [
          {"version":"45 Beta","arch":"aarch64","variant":"Workstation","link":"https://f/test/45_Beta/W.aarch64.iso","sha256":"bb"},
          {"version":"44","arch":"aarch64","variant":"Workstation","link":"https://f/44/Fedora-Workstation-Live-44-1.7.aarch64.iso","sha256":"CC"},
          {"version":"44","arch":"x86_64","variant":"Workstation","link":"https://f/44/x.iso","sha256":"dd"},
          {"version":"44","arch":"aarch64","variant":"KDE","link":"https://f/44/k.iso","sha256":"ee"},
          {"version":"43","arch":"aarch64","variant":"Workstation","link":"https://f/43/old.aarch64.iso","sha256":"ff"},
          {"version":"44","arch":"aarch64","variant":"Workstation","link":"https://f/44/raw.xz"}
        ]
        """
        let release = try #require(LinuxDesktop.fedoraRelease(releasesJSON: Data(json.utf8)))
        #expect(release.fileName == "Fedora-Workstation-Live-44-1.7.aarch64.iso")
        #expect(release.sha256 == "cc")
    }
}

struct SSHConfigIncludeTests {
    @Test func removingIncludeUndoesInstall() {
        let existing = "Host work\n  HostName example.com\n"
        let installed = SSHConfig.includeLine + "\n\n" + existing
        #expect(SSHConfig.removingInclude(from: installed) == existing)
        #expect(SSHConfig.removingInclude(from: existing) == existing)
    }
}

struct DownloadTests {
    private func expectContiguous(_ ranges: [ClosedRange<Int64>], length: Int64) {
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == length - 1)
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(b.lowerBound == a.upperBound + 1) }
    }

    @Test func chunksCoverRange() {
        let parts = Download.chunks(0...999, size: 300)
        #expect(parts == [0...299, 300...599, 600...899, 900...999])
        #expect(Download.chunks(5...5, size: 300) == [5...5])
    }

    @Test func plannedRangesKeepExistingPrefixAsFirstChunk() {
        let ranges = Download.plannedRanges(length: 1000, prefix: 600, chunk: 100)
        #expect(ranges.first == 0...599)
        #expect(ranges.count == 5)
        expectContiguous(ranges, length: 1000)
        expectContiguous(Download.plannedRanges(length: 1000, prefix: 0, chunk: 100), length: 1000)
    }

    @Test func refineSplitsLargeUnfinishedRanges() {
        let refined = Download.refine([0...999, 1000...1099], chunk: 100) { $0.lowerBound == 0 ? 150 : 0 }
        #expect(refined.first == 0...249)
        #expect(refined.contains(1000...1099))
        expectContiguous(refined, length: 1100)
        #expect(Download.refine([0...999], chunk: 100) { _ in 900 } == [0...999])
    }

    @Test func probeReadsFinalResponseAfterRedirects() throws {
        let output = """
        HTTP/1.1 302 Found\r
        Location: https://mirror.example/f.iso\r
        Content-Length: 0\r
        \r
        HTTP/2 200\r
        content-length: 4154798080\r
        accept-ranges: bytes\r
        \r
        https://mirror.example/f.iso
        """
        let probe = try #require(Download.parseProbe(output))
        #expect(probe.url.absoluteString == "https://mirror.example/f.iso")
        #expect(probe.length == 4154798080)
    }

    @Test func probeWithoutLength() throws {
        let probe = try #require(Download.parseProbe("HTTP/1.1 200 OK\r\nContent-Type: x\r\n\r\nhttps://e.example/a"))
        #expect(probe.length == nil)
    }

    @Test func probeRejectsErrorStatus() {
        #expect(Download.parseProbe("HTTP/1.1 302 Found\r\n\r\nHTTP/2 404\r\ncontent-length: 9\r\n\r\nhttps://e.example/a") == nil)
    }
}

struct SubprocessCancellationTests {
    @Test func cancellingTerminatesChildProcess() async throws {
        let started = Date()
        let task = Task { try await Subprocess.run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

struct SubprocessOutputTests {
    @Test func outputLargerThanPipeBufferDoesNotHang() async throws {
        let output = try await Subprocess.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a; head -c 300000 /dev/zero >&2"])
        #expect(output.utf8.count == 300000)
    }
}

struct DownloadLockTests {
    @Test func secondHolderIsRefusedUntilRelease() throws {
        let target = FileManager.default.temporaryDirectory.appending(path: "macvm-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target.appendingPathExtension("lock")) }
        let first = try #require(try DownloadLock(trying: target))
        #expect(try DownloadLock(trying: target) == nil)
        first.release()
        try #require(try DownloadLock(trying: target)).release()
    }

    @Test func acquireWaitsForRelease() async throws {
        let target = FileManager.default.temporaryDirectory.appending(path: "macvm-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target.appendingPathExtension("lock")) }
        let first = try #require(try DownloadLock(trying: target))
        let waiter = Task { try await DownloadLock.acquire(target) }
        try await Task.sleep(for: .milliseconds(700))
        first.release()
        try await waiter.value.release()
    }
}

struct MacOSTuningTests {
    @Test func scriptRunsEachStepAndReports() throws {
        let script = MacOSTuning.script([.spotlight, .screensaver], revert: false)
        #expect(script.contains("mdutil -a -i off"))
        #expect(script.contains("echo 'ok screensaver'"))
        #expect(MacOSTuning.script([.screensaver], revert: true).contains("defaults -currentHost delete com.apple.screensaver idleTime"))

        let report = MacOSTuning.parse("ok spotlight\nfail screensaver\n", steps: [.spotlight, .screensaver, .updates], revert: false)
        #expect(report.applied == [.spotlight])
        #expect(report.failed == [.screensaver, .updates])
    }

    @Test func scriptRunsUnderShell() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "macvm-tune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 用不存在的命令代替真实设置，只验证 sh 能解析脚本、每项各出一行结果。
        let script = MacOSTuning.script(MacOSTuning.Step.allCases, revert: false)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-n", "-c", script]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(script.split(separator: "\n").count == MacOSTuning.Step.allCases.count + 1)
    }
}

struct CreationMarkerTests {
    @Test func newBundleCarriesCreationToken() async throws {
        let library = VMLibrary(root: FileManager.default.temporaryDirectory.appending(path: "macvm-tests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: library.root) }
        let marked = try await VMFactory.withNewBundle(named: "marked", in: library, creationToken: "token") { $0 }
        #expect(marked.creationToken == "token")
        let plain = try await VMFactory.withNewBundle(named: "plain", in: library) { $0 }
        #expect(plain.creationToken == nil)
    }
}

struct ISOCacheTests {
    @Test func cachedAndStaleFilesAreScopedToDesktop() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "macvm-iso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = [
            "ubuntu-26.04-desktop-arm64.iso", "ubuntu-26.04.1-desktop-arm64.iso",
            "ubuntu-26.04-desktop-arm64.iso.part.seg-0", "ubuntu-26.04-desktop-arm64.iso.part.segments",
            "ubuntu-26.04-desktop-arm64.iso.part.lock",
            "ubuntu-26.04.2-desktop-arm64.iso.part", "Fedora-Workstation-Live-44-1.7.aarch64.iso.part",
        ]
        for name in names { FileManager.default.createFile(atPath: root.appending(path: name).path, contents: nil) }

        #expect(ISOCache.cachedISOs(of: .ubuntu, in: root).map(\.lastPathComponent)
                == ["ubuntu-26.04-desktop-arm64.iso", "ubuntu-26.04.1-desktop-arm64.iso"])
        ISOCache.removeStalePartials(of: .ubuntu, keeping: "ubuntu-26.04.2-desktop-arm64.iso", in: root)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(left == ["ubuntu-26.04-desktop-arm64.iso", "ubuntu-26.04.1-desktop-arm64.iso", "ubuntu-26.04-desktop-arm64.iso.part.lock",
                         "ubuntu-26.04.2-desktop-arm64.iso.part", "Fedora-Workstation-Live-44-1.7.aarch64.iso.part"])
    }
}
