import Foundation
@testable import MacVMEngine
import MacVMModel
import Testing

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
