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
        #expect(joined.contains("virtio-ramfb-gl,id=gpu,blob=true,hostmem=2147483648,xres=1920,yres=1200,neptune=true"))
        #expect(joined.contains("-spice unix=on,addr=\(QEMUCommand.spiceSocket(bundle).path),disable-ticketing=on,gl=on"))
        #expect(!args.contains("-vnc") && args.starts(with: ["-L", "/q/share"]))
        #expect(joined.contains("-bios /code.fd -drive if=pflash,unit=1,"))
        #expect(joined.contains("-accel hvf,ipa-granule-size=4096"))
        #expect(bundled.environment["RENDER_SERVER_EXEC_PATH"] == "/q/bin/virgl_render_server")
        config.os = .linux
        #expect(!(try QEMUCommand(bundle: bundle, config: config, qemu: bundled).arguments().joined().contains("neptune")))
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
        #expect(shapes.count == 2)
        let image = try #require(Data(base64Encoded: shapes[0].bgra).flatMap { cursorImage(bgra: $0, width: shapes[0].width, height: shapes[0].height) })
        #expect(image.width == 2 && image.height == 1 && shapes[0].hot_x == 1)
        #expect(shapes[1].hidden && cursorImage(bgra: Data(), width: 0, height: 0) == nil)
    }
}
