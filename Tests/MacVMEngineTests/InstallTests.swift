import CryptoKit
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

struct FirstBootTests {
    @MainActor
    @Test func doesNotRetryWhenAlreadyRunning() async {
        var attempts = 0
        await #expect(throws: MacVMError.self) {
            try await MacOSInstaller.firstBoot {
                attempts += 1
                throw MacVMError.alreadyRunning("vm")
            }
        }
        #expect(attempts == 1)
    }
}

struct CreationMarkerStartTests {
    @Test func bundleWithMarkerRefusesToStart() throws {
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appending(path: "macvm-creating-\(UUID().uuidString).macvm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try bundle.requireNotCreating()
        try Data("token".utf8).write(to: bundle.creationMarkerURL)
        #expect(throws: MacVMError.self) { try bundle.requireNotCreating() }
    }
}

struct GuestScreenLockTests {
    @Test(arguments: [true, false])
    func linuxScriptParsesUnderShell(locks: Bool) throws {
        let script = GuestScreenLock.linuxScript(locks: locks)
        #expect(script.contains("lock-enabled=\(locks)"))
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-n", "-c", script]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func macOSPasswordGoesThroughStandardInput() throws {
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appending(path: "macvm-lock-\(UUID().uuidString).macvm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(throws: MacVMError.self) { try GuestScreenLock.command(locks: false, os: .macOS, bundle: bundle) }
        try GuestCredentials.storePassword("p'w d", in: bundle)
        let (request, input) = try GuestScreenLock.command(locks: false, os: .macOS, bundle: bundle)
        #expect(String(decoding: input, as: UTF8.self) == "p'w d\n")
        #expect(!request.argv.joined().contains("p'w d"))
        #expect(request.argv.last?.contains("-screenLock off") == true)
    }
}

struct GuestStaticIPv4Tests {
    private func parses(_ script: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-n", "-c", script]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test func scriptsParseUnderShell() throws {
        #expect(try parses(GuestStaticIPv4.linuxScript()))
        #expect(try parses(GuestStaticIPv4.macOSScript()))
    }

    @Test func linuxPassesSettingsAsArgumentsAndRunsAsRoot() throws {
        let bundle = VMBundle(url: URL(filePath: "/vms/static-ip-test.macvm"))
        let value = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "192.168.1.1", dns: ["1.1.1.1", "9.9.9.9"])
        let (request, input) = try GuestStaticIPv4.command(value, mac: "02:AB:00:00:00:01", os: .linux, bundle: bundle)
        #expect(request.user == "root")
        #expect(input.isEmpty)
        #expect(Array(request.argv.prefix(3)) == ["/bin/sh", "-c", GuestStaticIPv4.linuxScript()])
        #expect(Array(request.argv.dropFirst(3)) == ["sh", "02:ab:00:00:00:01", "192.168.1.10/24", "192.168.1.1", "1.1.1.1", "9.9.9.9"])
        #expect(!request.argv[2].contains("192.168.1.10"))

        let dhcp = try GuestStaticIPv4.command(nil, mac: "02:ab:00:00:00:01", os: .linux, bundle: bundle).0
        #expect(Array(dhcp.argv.dropFirst(3)) == ["sh", "02:ab:00:00:00:01"])
    }

    @Test func macOSPasswordGoesThroughStandardInputOnly() throws {
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appending(path: "macvm-static-ip-\(UUID().uuidString).macvm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let value = try StaticIPv4(cidr: "10.0.0.5/16", gateway: "10.0.0.1")

        // 没有保存的密码也能生成命令，由脚本在真要改动时才报错。
        let (unsaved, empty) = try GuestStaticIPv4.command(nil, mac: "02:00:00:00:00:01", os: .macOS, bundle: bundle)
        #expect(String(decoding: empty, as: UTF8.self) == "\n")
        let script = ["/bin/sh", "-c", GuestStaticIPv4.macOSLocked, GuestStaticIPv4.macOSScript()]
        #expect(Array(unsaved.argv.prefix(script.count)) == script)
        #expect(Array(unsaved.argv.dropFirst(script.count)) == ["02:00:00:00:00:01"])

        try GuestCredentials.storePassword("p'w d", in: bundle)
        let (request, input) = try GuestStaticIPv4.command(value, mac: "02:00:00:00:00:01", os: .macOS, bundle: bundle)
        #expect(String(decoding: input, as: UTF8.self) == "p'w d\n")
        #expect(!request.argv.joined().contains("p'w d"))
        #expect(request.user == nil)
        #expect(Array(request.argv.dropFirst(script.count)) == ["02:00:00:00:00:01", "10.0.0.5", "255.255.0.0", "10.0.0.1", "10.0.0.1"])
    }

    @Test func macOSStaticAddressNeedsSavedPassword() throws {
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appending(path: "macvm-static-ip-\(UUID().uuidString).macvm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let value = try StaticIPv4(cidr: "10.0.0.5/16", gateway: "10.0.0.1")

        let error = #expect(throws: MacVMError.self) { try GuestStaticIPv4.requirePassword(bundle, os: .macOS, for: value) }
        #expect(error?.code == "unsupported")
        try GuestStaticIPv4.requirePassword(bundle, os: .macOS, for: nil)
        try GuestStaticIPv4.requirePassword(bundle, os: .linux, for: value)

        try GuestCredentials.storePassword("", in: bundle)
        #expect(throws: MacVMError.self) { try GuestStaticIPv4.requirePassword(bundle, os: .macOS, for: value) }
        try GuestCredentials.storePassword("pw", in: bundle)
        try GuestStaticIPv4.requirePassword(bundle, os: .macOS, for: value)
    }

    @Test func windowsIsUnsupported() {
        let bundle = VMBundle(url: URL(filePath: "/vms/static-ip-test.macvm"))
        let error = #expect(throws: MacVMError.self) { try GuestStaticIPv4.command(nil, mac: "02:00:00:00:00:01", os: .windows, bundle: bundle) }
        #expect(error?.code == "unsupported")
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
            "ubuntu-26.04.1-desktop-arm64.autoinstall.iso",
        ]
        for name in names { FileManager.default.createFile(atPath: root.appending(path: name).path, contents: nil) }

        #expect(ISOCache.cachedISOs(of: .ubuntu, in: root).map(\.lastPathComponent)
                == ["ubuntu-26.04-desktop-arm64.iso", "ubuntu-26.04.1-desktop-arm64.iso"])
        ISOCache.removeStalePartials(of: .ubuntu, keeping: "ubuntu-26.04.2-desktop-arm64.iso", in: root)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(left == ["ubuntu-26.04-desktop-arm64.iso", "ubuntu-26.04.1-desktop-arm64.iso", "ubuntu-26.04-desktop-arm64.iso.part.lock",
                         "ubuntu-26.04.2-desktop-arm64.iso.part", "Fedora-Workstation-Live-44-1.7.aarch64.iso.part",
                         "ubuntu-26.04.1-desktop-arm64.autoinstall.iso"])
    }
}

struct UbuntuAutoinstallTests {
    /// Ubuntu 26.04.1 桌面版 arm64 安装盘里的 `boot/grub/grub.cfg`。
    static let grubConfig = """
        set timeout=30

        loadfont unicode

        set menu_color_normal=white/black
        set menu_color_highlight=black/light-gray

        set cmdline=
        smbios --type 4 --get-string 5 --set proc_version
        regexp "Snapdragon.*" "$proc_version"
        if [ $? = 0 ]; then
          # Work around Snapdragon X firmware bug. cutmem is not allowed in lockdown mode.
          if [ $lockdown != "y" ]; then
            cutmem 0x8800000000 0x8fffffffff
          fi
          # arm64.nopauth works around 8cx Gen 3 firmware bug
          cmdline="clk_ignore_unused pd_ignore_unused arm64.nopauth"
        fi

        menuentry "Try or Install Ubuntu" {
            set gfxpayload=keep
            linux  /casper/vmlinuz $cmdline  --- quiet splash console=tty0
            initrd /casper/initrd
        }
        menuentry 'Boot from next volume' {
            exit 1
        }
        menuentry 'UEFI Firmware Settings' {
            fwsetup
        }

        """

    private func options(agent: URL? = nil, shares: [ShareConfig] = [], rosetta: Bool = false, token: String? = nil) -> UbuntuAutoinstall.Options {
        UbuntuAutoinstall.Options(hostname: "My_Desk.1", user: "ethan", password: "s3cret", sshPublicKey: "ssh-ed25519 AAAA test",
                                  shares: shares, rosetta: rosetta, timezone: "Asia/Shanghai", agentBinary: agent, agentToken: token)
    }

    @Test func sha512CryptMatchesGlibcVectors() {
        #expect(ShadowPassword.sha512Crypt("Hello world!", salt: "saltstring")
                == "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
        // 盐最长 16 个字符，多出的截掉。
        #expect(ShadowPassword.sha512Crypt("This is just a test", salt: "toolongsaltstring")
                == "$6$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0")
    }

    @Test func grubConfigBootsInstallerUnattendedAtSameLength() throws {
        let patched = try UbuntuAutoinstall.grubConfig(patching: Self.grubConfig)
        #expect(patched.utf8.count == Self.grubConfig.utf8.count)
        #expect(patched.hasPrefix("set timeout=0\n"))
        #expect(patched.contains("linux  /casper/vmlinuz $cmdline  autoinstall noprompt --- quiet splash console=tty0\n"))
        #expect(patched.contains("initrd /casper/initrd\n"))
        #expect(!patched.contains("Boot from next volume"))
        #expect(throws: MacVMError.self) { try UbuntuAutoinstall.grubConfig(patching: "set timeout=5\n") }
    }

    @Test func bootISORewritesGrubConfigInPlace() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "macvm-autoinstall-\(UUID().uuidString)")
        let tree = dir.appending(path: "tree/boot/grub")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.grubConfig.write(to: tree.appending(path: "grub.cfg"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appending(path: "tree/boot/other.txt"), atomically: true, encoding: .utf8)
        let iso = dir.appending(path: "ubuntu-26.04.1-desktop-arm64.iso")
        try await Subprocess.run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-o", iso.path, dir.appending(path: "tree").path])

        let extent = try ISO9660.extent(of: "boot/grub/grub.cfg", in: iso)
        #expect(extent.length == Self.grubConfig.utf8.count)
        #expect(throws: MacVMError.self) { try ISO9660.extent(of: "boot/grub/missing.cfg", in: iso) }

        let boot = try UbuntuAutoinstall.bootISO(for: iso)
        #expect(boot.lastPathComponent == "ubuntu-26.04.1-desktop-arm64.autoinstall.iso")
        let data = try Data(contentsOf: boot)
        let start = Int(extent.offset)
        let patched = String(decoding: data[start..<(start + extent.length)], as: UTF8.self)
        #expect(patched == (try UbuntuAutoinstall.grubConfig(patching: Self.grubConfig)))
        #expect(try Data(contentsOf: iso).count == data.count)
        #expect(try UbuntuAutoinstall.bootISO(for: iso) == boot)
    }

    @Test func userDataHashesPasswordAndRunsSetupScript() {
        let data = UbuntuAutoinstall.userData(options())
        #expect(data.hasPrefix("#cloud-config\nautoinstall:\n  version: 1\n"))
        #expect(data.contains("  locale: en_US.UTF-8\n"))
        #expect(data.contains("    hostname: \"my-desk-1\"\n"))
        #expect(data.contains("    password: \"$6$"))
        #expect(!data.contains("s3cret"))
        #expect(data.contains("      - \"ssh-ed25519 AAAA test\"\n"))
        #expect(data.contains("sh /run/macvm-seed/macvm-setup.sh /run/macvm-seed /target"))
        #expect(data.contains("  early-commands:\n    - \"nmcli networking off"))
        #expect(data.contains("  apt:\n    geoip: false\n"))
        #expect(data.contains(#"printf '[Manager]\\nDefaultTimeoutStopSec=5s\\n'"#))
    }

    @Test func setupScriptConfiguresTarget() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "macvm-target-\(UUID().uuidString)")
        let seed = dir.appending(path: "seed"), target = dir.appending(path: "target")
        for path in ["etc/sudoers.d", "etc/netplan", "etc/gdm3", "usr/local/bin"] {
            try FileManager.default.createDirectory(at: target.appending(path: path), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["00-installer-config.yaml", "01-network-manager-all.yaml"] {
            FileManager.default.createFile(atPath: target.appending(path: "etc/netplan/\(name)").path, contents: Data())
        }
        try "# GDM configuration storage\n\n[daemon]\n# AutomaticLoginEnable = true\n\n[security]\n"
            .write(to: target.appending(path: "etc/gdm3/custom.conf"), atomically: true, encoding: .utf8)
        let o = options(shares: [ShareConfig(hostPath: "/Users/e/My Code", tag: "code", readOnly: true)], rosetta: true, token: "abc123")
        try "abc123".write(to: seed.appending(path: UbuntuAutoinstall.agentTokenName), atomically: true, encoding: .utf8)
        let script = seed.appending(path: UbuntuAutoinstall.setupScriptName)
        try UbuntuAutoinstall.setupScript(o).write(to: script, atomically: true, encoding: .utf8)
        try await Subprocess.run("/bin/sh", [script.path, seed.path, target.path])

        func read(_ path: String) throws -> String { try String(contentsOf: target.appending(path: path), encoding: .utf8) }
        #expect(try read("etc/sudoers.d/90-macvm") == "ethan ALL=(ALL) NOPASSWD:ALL\n")
        #expect(try read(String(AgentToken.linuxPath.dropFirst())) == "abc123")
        let mode = try FileManager.default.attributesOfItem(atPath: target.appending(path: String(AgentToken.linuxPath.dropFirst())).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try read("etc/NetworkManager/conf.d/90-macvm.conf") == "[connection]\nipv4.dhcp-client-id=mac\n")
        #expect(try read("etc/binfmt.d/rosetta.conf") == CloudInit.rosettaBinfmtRule + "\n")
        #expect(try read("etc/fstab") == "code /mnt/code virtiofs ro,nofail 0 0\nrosetta /media/rosetta virtiofs ro,nofail 0 0\n")
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "mnt/code").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.appending(path: "etc/netplan").path) == ["01-network-manager-all.yaml"])
        #expect(try read("etc/dconf/profile/user") == "user-db:user\nsystem-db:local\n")
        #expect(try read("etc/dconf/db/local.d/90-macvm") == """
            [org/gnome/desktop/screensaver]
            lock-enabled=false
            ubuntu-lock-on-suspend=false

            [org/gnome/settings-daemon/plugins/power]
            sleep-inactive-ac-type='nothing'
            sleep-inactive-battery-type='nothing'

            """)
        #expect(try read("etc/gdm3/custom.conf")
                == "# GDM configuration storage\n\n[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=ethan\n# AutomaticLoginEnable = true\n\n[security]\n")
    }

    @Test func finishSetupDetachesBootISOAndSeed() async throws {
        let library = VMLibrary(root: FileManager.default.temporaryDirectory.appending(path: "macvm-tests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: library.root) }
        let bundle = try await VMFactory.withNewBundle(named: "desk", in: library) { $0 }
        let seed = bundle.url.appending(path: UbuntuAutoinstall.seedFileName)
        FileManager.default.createFile(atPath: seed.path, contents: Data())
        let network = NetworkConfig(mode: .nat, macAddress: "02:00:00:00:00:01")
        try bundle.saveConfig(VMConfig(name: "desk", os: .linux, cpuCount: 2, memorySize: 4 << 30,
                                       disks: [DiskConfig(path: "disk.img"), DiskConfig(path: UbuntuAutoinstall.seedFileName, readOnly: true)],
                                       networks: [network], installMedia: ["/tmp/ubuntu.autoinstall.iso", "/tmp/drivers.iso"]))
        try UbuntuAutoinstall.finishSetup(bundle)
        let config = try bundle.loadConfig()
        #expect(config.installMedia == ["/tmp/drivers.iso"])
        #expect(config.disks.map(\.path) == ["disk.img"])
        #expect(config.networks == [network])
        #expect(!FileManager.default.fileExists(atPath: seed.path))
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

    @Test func setupScriptLocksDirectoryBeforeWritingIntoIt() throws {
        var o = options
        o.installAgent = true
        o.installGPUDriver = true
        o.agentToken = "abc123"
        let script = WindowsUnattend.setupScript(o)
        let lock = try #require(script.range(of: "CreateDirectory($macvm, $acl)"))
        let verify = try #require(script.range(of: "throw \"$macvm has an untrusted owner"))
        let driver = try #require(script.range(of: "Copy-Item -Recurse"))
        let write = try #require(script.range(of: "WriteAllText('\(AgentToken.windowsPath)', 'abc123')"))
        let copy = try #require(script.range(of: "Copy-Item -LiteralPath (Join-Path $PSScriptRoot"))
        #expect(lock.lowerBound < verify.lowerBound && verify.lowerBound < driver.lowerBound)
        #expect(driver.lowerBound < write.lowerBound && write.lowerBound < copy.lowerBound)
    }

    @Test func prepareDirectoryIsASCII() {
        let ascii = AgentInstaller.windowsPrepareDirectory.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(ascii)
    }

    @Test func setupScriptInstallsAgentOnlyWhenBundled() {
        var o = options
        #expect(!WindowsUnattend.setupScript(o).contains("Register-ScheduledTask"))
        o.installAgent = true
        let script = WindowsUnattend.setupScript(o)
        #expect(script.contains("Register-ScheduledTask") && script.contains("-UserId 'a<b'"))
        #expect(script.contains("-TaskName \(AgentInstaller.windowsDesktopTaskName) -Action (New-ScheduledTaskAction -Execute $exe -Argument '--desktop-supervisor') -Trigger (New-ScheduledTaskTrigger -AtStartup)"))
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

    @Test func sharedLinuxCannotSwitchToQEMU() throws {
        var config = VMConfig(name: "l", os: .linux, cpuCount: 2, memorySize: 1 << 30, disks: [])
        try config.addShare(hostPath: "/usr/bin")
        #expect(throws: MacVMError.self) { try config.switchEngine(to: .qemu) }
        #expect(config.engine == .vz)
    }

    @Test func rosettaLinuxCannotSwitchToQEMU() throws {
        var config = VMConfig(name: "l", os: .linux, cpuCount: 2, memorySize: 1 << 30, disks: [])
        config.rosetta = true
        #expect(throws: MacVMError.self) { try config.switchEngine(to: .qemu) }
        #expect(config.engine == .vz)
    }

    @Test func bridgedLinuxCannotSwitchToQEMU() throws {
        var config = VMConfig(name: "l", os: .linux, cpuCount: 2, memorySize: 1 << 30, disks: [],
                              networks: [NetworkConfig(mode: .bridged, interface: "en0")])
        let error = #expect(throws: MacVMError.self) { try config.switchEngine(to: .qemu) }
        #expect(error?.code == "unsupported")
        #expect(config.engine == .vz)
    }

    @Test func leftoverGuestStaticIPv4BlocksSwitchToQEMU() throws {
        var config = VMConfig(name: "l", os: .linux, cpuCount: 2, memorySize: 1 << 30, disks: [],
                              networks: [NetworkConfig(mode: .nat, macAddress: "02:00:00:00:00:01")])
        config.guestStaticIPv4 = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "192.168.1.1")
        let error = #expect(throws: MacVMError.self) { try config.switchEngine(to: .qemu) }
        #expect(error?.code == "unsupported")
        #expect(config.engine == .vz)
    }

    @Test func encodedPowerShellIsUTF16LEBase64() throws {
        let script = "Write-Output '你好'\nexit 3"
        let command = AgentInstaller.encodedPowerShell(script)
        let encoded = try #require(command.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        #expect(String(data: data, encoding: .utf16LittleEndian) == script)
    }

    /// 只有 `LC_CODE_SIGNATURE` 的最小 Mach-O：SuperBlob 里一个 CodeDirectory、一个签名 blob。
    @Test func agentFingerprintIgnoresSignatureBlob() throws {
        let hex = "cffaedfe0c0000010000000002000000010000001000000000000000000000001d000000100000003000000038000000fade0cc00000003800000002000000000000001c000100000000002cfade0c0200000010636f646564697221fade0b010000000c73696731"
        var bytes = stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
        }
        #expect(AgentUpdate.fingerprint(Data(bytes)) == "d6ede52a4223af0f0f79c79e5673d492d23dad44b683a0fb53966cd4e1ad9725")
        bytes[bytes.count - 1] ^= 0xff
        #expect(AgentUpdate.fingerprint(Data(bytes)) == "d6ede52a4223af0f0f79c79e5673d492d23dad44b683a0fb53966cd4e1ad9725")
        #expect(AgentUpdate.fingerprint(Data("plain".utf8)) == SHA256.hash(data: Data("plain".utf8)).map { String(format: "%02x", $0) }.joined())
    }

    @Test func agentUpdateScripts() throws {
        let linux = AgentUpdate.linuxScript(user: "dev")
        // 重启会结束整个 cgroup，必须是最后一步且不等它完成。
        #expect(linux.split(separator: "\n").last == "systemctl restart --no-block macvm-agent")
        #expect(linux.contains("ExecStart=\(AgentInstaller.linuxPath) --user dev"))

        let mac = AgentInstaller.macOSInstallScript(user: "dev", detachOutput: true)
        let lines = mac.split(separator: "\n").map(String.init)
        let detach = try #require(lines.firstIndex(of: "exec >/dev/null 2>&1"))
        let bootout = try #require(lines.firstIndex { $0.hasPrefix("launchctl bootout") })
        #expect(detach < bootout)
        #expect(!AgentInstaller.macOSInstallScript(user: "dev", detachOutput: false).contains("exec >/dev/null"))

        let windows = AgentUpdate.windowsScript(user: "dev")
        #expect(windows.unicodeScalars.allSatisfy { $0.isASCII })
        // 替换脚本写成文件，放在单引号 here-string 里，结束标记必须顶格。
        #expect(windows.contains("\n'@, [Text.Encoding]::ASCII)"))
        #expect(windows.hasSuffix("Start-ScheduledTask -TaskName \(AgentUpdate.windowsUpdateTaskName)"))
    }

    @Test func guestMigrationsReachLatestRevision() {
        for os in [GuestOS.linux, .macOS, .windows] {
            let revisions = GuestMigration.all.filter { $0.os == os }.map(\.revision).sorted()
            #expect(revisions == Array(0..<GuestRevision.latest(for: os)).map { $0 + 1 })
        }
        var config = VMConfig(name: "w", os: .windows, cpuCount: 2, memorySize: 1 << 30, disks: [])
        #expect(GuestMigration.pending(for: config).isEmpty)
        config.guestRevision = 0
        #expect(GuestMigration.pending(for: config).map(\.revision) == [1, 2])
    }

    @Test func legacyConfigStartsAtRevisionZero() throws {
        let config = VMConfig(name: "w", os: .windows, cpuCount: 2, memorySize: 1 << 30, disks: [])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        #expect(json["guestRevision"] as? Int == GuestRevision.latest(for: .windows))
        json["guestRevision"] = nil
        let legacy = try JSONDecoder().decode(VMConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.guestRevision == 0)
    }

    @Test func computerNameIsValidForWindows() {
        #expect(WindowsInstaller.computerName(for: "win_11") == "win11")
        #expect(WindowsInstaller.computerName(for: "abcdefghijklmn-foo") == "abcdefghijklmn")
        #expect(WindowsInstaller.computerName(for: "win-") == "win")
        #expect(WindowsInstaller.computerName(for: "_") == "*")
        #expect(WindowsInstaller.computerName(for: "2024") == "*")
    }

    @Test func localeComesFromLangINI() {
        let ini = "[Available UI Languages]\r\nzh-cn = 3\r\n\r\n[Fallback Languages]\r\nen-us = en-us\r\n"
        #expect(WindowsInstaller.locale(inLangINI: ini) == "zh-CN")
        #expect(WindowsInstaller.locale(inLangINI: "[Available UI Languages]\nsr-latn-rs = 3\n") == "sr-Latn-RS")
        #expect(WindowsInstaller.locale(inLangINI: "[Fallback Languages]\nde-de = de-de\n") == "en-US")
        #expect(WindowsInstaller.locale(inLangINI: "") == "en-US")
    }

    @Test func setupScriptDisablesSSHPasswordLogin() throws {
        let script = WindowsUnattend.setupScript(options)
        let disable = try #require(script.range(of: "@('PasswordAuthentication no')"))
        let restart = try #require(script.range(of: "Restart-Service sshd"))
        #expect(disable.lowerBound < restart.lowerBound)
    }

    @Test func unattendEscapesXML() throws {
        let xml = WindowsUnattend.unattend(options)
        #expect(xml.contains("<Name>a&lt;b</Name>"))
        #expect(xml.contains("<Value>p&amp;w</Value>"))
        _ = try XMLDocument(xmlString: xml)
        _ = try XMLDocument(xmlString: WindowsUnattend.autounattend())
    }

    @Test func unattendSetsTimeZoneWhenKnown() throws {
        var o = options
        o.timeZone = "China Standard Time"
        let xml = WindowsUnattend.unattend(o)
        #expect(xml.contains("<TimeZone>China Standard Time</TimeZone>"))
        _ = try XMLDocument(xmlString: xml)
        o.timeZone = nil
        #expect(!WindowsUnattend.unattend(o).contains("<TimeZone>"))
    }

    @Test func mapsTZDatabaseNamesToWindowsTimeZones() {
        #expect(WindowsUnattend.windowsTimeZone(for: "Asia/Shanghai") == "China Standard Time")
        #expect(WindowsUnattend.windowsTimeZone(for: "America/New_York") == "Eastern Standard Time")
        #expect(WindowsUnattend.windowsTimeZone(for: "Etc/UTC") == "UTC")
        #expect(WindowsUnattend.windowsTimeZone(for: "Nowhere/City") == nil)
    }
}

struct CloudInitTests {
    private func options(password: String?) -> CloudInit.Options {
        CloudInit.Options(hostname: "dev", user: "ethan", password: password, sshPublicKey: "ssh-ed25519 AAAA test",
                          macAddress: "02:00:00:00:00:01", timezone: "Asia/Shanghai", agentBinary: nil)
    }

    @Test func setsTimezone() {
        #expect(CloudInit.userData(options(password: nil)).contains("\ntimezone: \"Asia/Shanghai\"\n"))
        var o = options(password: nil)
        o.timezone = nil
        #expect(!CloudInit.userData(o).contains("timezone:"))
    }

    @Test func writesAgentTokenRootOnly() {
        var o = options(password: nil)
        #expect(!CloudInit.userData(o).contains(AgentToken.linuxPath))
        o.agentToken = "abc123"
        #expect(CloudInit.userData(o).contains("  - path: \(AgentToken.linuxPath)\n    permissions: '0600'\n    content: \"abc123\""))
    }

    @Test func withoutPasswordLocksPasswordLogin() {
        let data = CloudInit.userData(options(password: nil))
        #expect(data.contains("lock_passwd: true"))
        #expect(!data.contains("chpasswd:"))
    }

    @Test func hostnameDropsCharactersHostnamesReject() {
        #expect(CloudInit.Options(hostname: "My_VM.2", user: "u", sshPublicKey: "k", macAddress: "02:00:00:00:00:01").hostname == "My-VM-2")
        #expect(CloudInit.hostname(for: "dev-1", fallback: "linux") == "dev-1")
        #expect(CloudInit.hostname(for: "_", fallback: "linux") == "linux")
        #expect(CloudInit.metaData(instanceID: "i", hostname: "dev") == "instance-id: i\nlocal-hostname: \"dev\"\n")
    }

    @Test func passwordUnlocksConsoleLoginButNotSSH() {
        let data = CloudInit.userData(options(password: #"p"w\d"#))
        #expect(data.contains("lock_passwd: false"))
        #expect(data.contains("chpasswd:\n  expire: false\n  users:\n    - name: \"ethan\"\n      password: \"p\\\"w\\\\d\"\n      type: text\n"))
        #expect(data.contains("ssh_pwauth: false"))
    }
}
