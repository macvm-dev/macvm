import Foundation
import MacVMModel
import Testing

struct VMConfigTests {
    @Test func roundTrip() throws {
        let config = VMConfig(
            name: "dev", os: .linux, cpuCount: 4, memorySize: 4 << 30,
            disks: [DiskConfig(path: "disk.img", bus: .nvme, sync: .none)],
            networks: [NetworkConfig(mode: .bridged, interface: "en0", macAddress: "02:00:00:00:00:01")],
            shares: [ShareConfig(hostPath: "/tmp", tag: "tmp", readOnly: true, samePath: true)],
            rosetta: true, installMedia: ["/x.iso"]
        )
        #expect(try VMConfig.decode(config.encoded()) == config)
    }

    @Test func missingOptionalFieldsUseDefaults() throws {
        let json = #"{"version":1,"name":"a","os":"windows","cpuCount":2,"memorySize":1073741824,"disks":[]}"#
        let config = try VMConfig.decode(Data(json.utf8))
        #expect(config.networks == [NetworkConfig()])
        #expect(config.audio)
        #expect(!config.microphone)
        #expect(config.installMedia.isEmpty)
    }

    @Test func rejectsNewerVersion() {
        let json = #"{"version":999,"name":"a","os":"linux","cpuCount":2,"memorySize":1,"disks":[]}"#
        #expect(throws: MacVMError.self) { try VMConfig.decode(Data(json.utf8)) }
    }
}

struct ByteSizeTests {
    @Test(arguments: [("512M", UInt64(512) << 20), ("8G", 8 << 30), ("1.5G", 3 << 29), ("2TiB", 2 << 40), ("4096", 4096)])
    func parses(text: String, bytes: UInt64) throws {
        #expect(try ByteSize.parse(text) == bytes)
    }

    @Test(arguments: ["", "abc", "-1G", "0"])
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
        #expect(String(decoding: data, as: UTF8.self) == #"{"error":{"code":"vm_not_found","message":"虚拟机不存在：x"},"schemaVersion":1}"#)
    }
}
