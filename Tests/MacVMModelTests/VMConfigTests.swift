import Foundation
import MacVMModel
import Testing

struct VMConfigTests {
    @Test func roundTrip() throws {
        let config = VMConfig(
            name: "dev", os: .linux, cpuCount: 4, memorySize: 4 << 30,
            disks: [DiskConfig(path: "disk.img", bus: .nvme, sync: .none)],
            networks: [NetworkConfig(macAddress: "02:00:00:00:00:01")],
            shares: [ShareConfig(hostPath: "/tmp", tag: "tmp", readOnly: true, samePath: true)],
            rosetta: true, installMedia: ["/x.iso"]
        )
        #expect(try VMConfig.decode(config.encoded()) == config)
    }

    @Test func missingOptionalFieldsUseDefaults() throws {
        let json = #"{"version":1,"name":"a","os":"windows","cpuCount":2,"memorySize":1073741824,"disks":[]}"#
        let config = try VMConfig.decode(Data(json.utf8))
        #expect(config.engine == .vz)
        #expect(config.networks == [NetworkConfig()])
        #expect(config.audio)
        #expect(!config.microphone)
        #expect(!config.screenLock)
        #expect(config.installMedia.isEmpty)
    }

    @Test func rejectsNewerVersion() {
        let json = #"{"version":999,"name":"a","os":"linux","cpuCount":2,"memorySize":1,"disks":[]}"#
        #expect(throws: MacVMError.self) { try VMConfig.decode(Data(json.utf8)) }
    }
}

struct SuspendPolicyTests {
    @Test func rules() {
        func make(_ os: GuestOS, _ engine: Engine, headless: Bool = false, media: [String] = []) -> VMConfig {
            VMConfig(name: "x", os: os, engine: engine, cpuCount: 1, memorySize: 1, disks: [], installMedia: media, headless: headless)
        }
        #expect(make(.macOS, .vz).supportsSuspend)
        #expect(!make(.linux, .vz).supportsSuspend)
        #expect(make(.linux, .vz, headless: true).supportsSuspend)
        #expect(!make(.windows, .vz, headless: true).supportsSuspend)
        #expect(make(.windows, .qemu).supportsSuspend)
        #expect(!make(.windows, .qemu, media: ["a.iso"]).supportsSuspend)
    }
}

struct ByteSizeTests {
    @Test(arguments: [("512M", UInt64(512) << 20), ("8G", 8 << 30), ("1.5G", 3 << 29), ("2TiB", 2 << 40), ("4096", 4096)])
    func parses(text: String, bytes: UInt64) throws {
        #expect(try ByteSize.parse(text) == bytes)
    }

    @Test(arguments: ["", "abc", "-1G", "0", "infG", "INF", "nanG", "1e30T", "99999999999T", "0.0001K", "0.5B"])
    func rejects(text: String) {
        #expect(throws: MacVMError.self) { try ByteSize.parse(text) }
    }

    @Test func formats() {
        #expect(ByteSize.format(8 << 30) == "8G")
        #expect(ByteSize.format(3 << 29) == "1.5G")
    }
}

struct VMLibraryTests {
    @Test(arguments: ["dev", "ubuntu-24.04", "a_b", String(repeating: "x", count: 40)])
    func acceptsNames(name: String) throws {
        try VMLibrary.validate(name: name)
    }

    @Test(arguments: ["", ".hidden", "-x", "a/b", "空格 名", String(repeating: "x", count: 41)])
    func rejectsNames(name: String) {
        #expect(throws: MacVMError.self) { try VMLibrary.validate(name: name) }
    }

    @Test func socketPathFitsSunPath() {
        let bundle = VMBundle(url: URL(filePath: "/x/\(String(repeating: "x", count: 40)).macvm"))
        #expect(bundle.controlSocketURL.path.utf8.count < 104)
    }

    @Test func sameNameInDifferentLibrariesGetsDistinctSockets() {
        let a = VMBundle(url: URL(filePath: "/x/a/dev.macvm"))
        let b = VMBundle(url: URL(filePath: "/x/b/dev.macvm"))
        #expect(a.controlSocketURL != b.controlSocketURL)
        #expect(a.controlSocketURL == VMBundle(url: URL(filePath: "/x/a/dev.macvm/")).controlSocketURL)
    }
}

struct OutputContractTests {
    @Test func errorCodesAndExitCodesAreUnique() {
        let codes = MacVMError.catalog.map(\.code)
        let exits = MacVMError.catalog.map(\.exitCode)
        #expect(Set(codes).count == codes.count)
        #expect(Set(exits).count == exits.count)
        #expect(!exits.contains(0) && !exits.contains(1) && !exits.contains(64))
    }

    @Test func failureEnvelopeShape() throws {
        struct R: Encodable, Sendable {}
        let data = try JSONEnvelope<R>.failure(.vmNotFound("x")).encoded()
        #expect(String(decoding: data, as: UTF8.self) == #"{"error":{"code":"vm_not_found","message":"Virtual machine not found: x"},"schemaVersion":1}"#)
    }

    @Test func shareTagForLinuxIsASCIIAndUnique() {
        #expect(ShareConfig.tag(for: "/Users/a/My 项目", os: .linux, taken: []) == "My")
        #expect(ShareConfig.tag(for: "/Users/a/项目", os: .linux, taken: []) == "share")
        #expect(ShareConfig.tag(for: "/Users/a/src", os: .linux, taken: ["src", "src-2"]) == "src-3")
        let long = ShareConfig.tag(for: "/x/" + String(repeating: "a", count: 50), os: .linux, taken: [String(repeating: "a", count: 36)])
        #expect(long == String(repeating: "a", count: 34) + "-2")
    }

    @Test func shareTagForMacOSKeepsNameWithinLimit() {
        #expect(ShareConfig.tag(for: "/Users/a/项目", os: .macOS, taken: []) == "项目")
        let tag = ShareConfig.tag(for: "/x/" + String(repeating: "项", count: 20), os: .macOS, taken: [])
        #expect(tag.utf8.count <= ShareConfig.maxTagBytes)
        #expect(tag == String(repeating: "项", count: 12))
    }

    @Test func addAndRemoveShares() throws {
        var linux = VMConfig(name: "l", os: .linux, cpuCount: 2, memorySize: 1 << 30, disks: [])
        try linux.addShare(hostPath: "/usr/bin")
        try linux.addShare(hostPath: "/bin")
        #expect(linux.shares.map(\.tag) == ["bin", "bin-2"])
        #expect(throws: MacVMError.self) { try linux.addShare(hostPath: "/usr/bin") }
        #expect(throws: MacVMError.self) { try linux.addShare(hostPath: "/usr/sbin", tag: "bin") }
        #expect(throws: MacVMError.self) { try linux.addShare(hostPath: "/usr/sbin", tag: String(repeating: "a", count: 37)) }
        #expect(throws: MacVMError.self) { try linux.addShare(hostPath: "/no/such/dir") }
        try linux.addShare(hostPath: "/usr/sbin", tag: "tools", readOnly: true)
        #expect(linux.shares.last == ShareConfig(hostPath: "/usr/sbin", tag: "tools", readOnly: true))

        try linux.removeShare("tools")
        try linux.removeShare("/bin")
        #expect(linux.shares.map(\.tag) == ["bin"])
        #expect(throws: MacVMError.self) { try linux.removeShare("tools") }

        var windows = VMConfig(name: "w", os: .windows, cpuCount: 2, memorySize: 1 << 30, disks: [])
        #expect(throws: MacVMError.self) { try windows.addShare(hostPath: "/usr/bin") }
    }

    @Test func audioDiffersOnlyForSoundAndMicrophone() {
        let booted = VMConfig(name: "m", os: .macOS, cpuCount: 2, memorySize: 1 << 30, disks: [])
        var saved = booted
        saved.display.retina = true
        #expect(!saved.audioDiffers(from: booted))
        saved.microphone = true
        #expect(saved.audioDiffers(from: booted))
        saved = booted
        saved.audio = false
        #expect(saved.audioDiffers(from: booted))
    }
}

struct GuestAccountTests {
    @Test func acceptsPortableNames() throws {
        for user in ["ethan", "dev_1", "a.b-c", "_svc", String(repeating: "a", count: 20)] { try GuestAccount.validate(user: user) }
    }

    @Test func rejectsNamesSomeGuestCannotCreate() {
        for user in ["", "Ethan", "1abc", "-x", "a b", "x;rm", String(repeating: "a", count: 21), "root", "administrator"] {
            #expect(throws: MacVMError.self) { try GuestAccount.validate(user: user) }
        }
    }

    @Test func passwordsMustSurviveStorageAndGuestConfig() throws {
        try GuestAccount.validate(password: #"p a"s\w"#)
        for password in ["", " lead", "trail ", "two\nlines", "tab\tin"] {
            #expect(throws: MacVMError.self) { try GuestAccount.validate(password: password) }
        }
    }
}

struct PortForwardTests {
    @Test func parsesWithAndWithoutAddress() throws {
        #expect(try PortForward.parse("8080:80") == PortForward(address: "127.0.0.1", hostPort: 8080, guestPort: 80))
        #expect(try PortForward.parse("0.0.0.0:2222:22") == PortForward(address: "0.0.0.0", hostPort: 2222, guestPort: 22))
        #expect(try PortForward.parse("0.0.0.0:2222:22").spec == "0.0.0.0:2222:22")
    }

    @Test(arguments: ["", "80", "a:b", "0:80", "8080:0", "8080:70000", "::1:80:80", "localhost:80:80", "1.2.3:80:80", "8080:+80", "1:2:3:4"])
    func rejects(text: String) {
        #expect(throws: MacVMError.self) { try PortForward.parse(text) }
    }

    @Test func conflictsOnSamePortWhenAddressesOverlap() {
        let local = PortForward(hostPort: 8080, guestPort: 80)
        #expect(local.conflicts(with: PortForward(hostPort: 8080, guestPort: 81)))
        #expect(local.conflicts(with: PortForward(address: "0.0.0.0", hostPort: 8080, guestPort: 80)))
        #expect(!local.conflicts(with: PortForward(address: "192.168.1.2", hostPort: 8080, guestPort: 80)))
        #expect(!local.conflicts(with: PortForward(hostPort: 8081, guestPort: 80)))
        #expect(throws: MacVMError.self) { try PortForward.parseAll(["8080:80", "0.0.0.0:8080:81"]) }
    }

    @Test func addAndRemove() throws {
        var config = VMConfig(name: "a", os: .linux, cpuCount: 1, memorySize: 1 << 30, disks: [])
        try config.addForward(PortForward.parse("8080:80"))
        try config.addForward(PortForward.parse("0.0.0.0:2222:22"))
        try config.addForward(PortForward.parse("9000:9000"))
        #expect(throws: MacVMError.self) { try config.addForward(PortForward.parse("8080:81")) }
        try config.removeForward("8080")
        try config.removeForward("0.0.0.0:2222")
        try config.removeForward("9000:9000")
        #expect(config.forwards.isEmpty)
        #expect(throws: MacVMError.self) { try config.removeForward("8080") }
    }

    @Test func roundTripsAndDefaultsToNone() throws {
        var config = VMConfig(name: "a", os: .linux, cpuCount: 1, memorySize: 1 << 30, disks: [])
        config.forwards = [PortForward(hostPort: 8080, guestPort: 80)]
        #expect(try VMConfig.decode(config.encoded()) == config)
        let json = #"{"version":1,"name":"a","os":"linux","cpuCount":2,"memorySize":1073741824,"disks":[]}"#
        #expect(try VMConfig.decode(Data(json.utf8)).forwards.isEmpty)
    }
}

struct NetworkConfigTests {
    @Test func bridgedConfigReadsAsNATKeepingMAC() throws {
        let json = #"{"mode":"bridged","interface":"en0","macAddress":"02:00:00:00:00:01"}"#
        let net = try JSONDecoder().decode(NetworkConfig.self, from: Data(json.utf8))
        #expect(net == NetworkConfig(mode: .nat, macAddress: "02:00:00:00:00:01"))
    }

    @Test func unknownModeIsRejected() {
        let json = #"{"mode":"carrier-pigeon"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(NetworkConfig.self, from: Data(json.utf8)) }
    }
}
