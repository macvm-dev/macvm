import Foundation
@testable import MacVMEngine
import MacVMModel
import Testing

struct VMTemplateTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "macvm-template-tests-\(UUID().uuidString)")
    var library: VMLibrary { VMLibrary(root: root.appending(path: "VMs")) }
    var templates: TemplateLibrary { TemplateLibrary(root: root.appending(path: "Templates")) }

    /// 一台已关机的 Linux 虚拟机：16G 稀疏系统盘、机器标识与一个快照目录。
    private func makeSource(named name: String = "src") async throws -> VMBundle {
        try await VMFactory.withNewBundle(named: name, in: library) { bundle in
            try DiskImage.createSparse(at: bundle.diskURL, size: 16 << 30)
            try MachineIdentity.createGeneric(in: bundle)
            try FileManager.default.createDirectory(at: bundle.snapshotsURL.appending(path: "before"), withIntermediateDirectories: true)
            let config = VMConfig(name: name, os: .linux, cpuCount: 2, memorySize: 2 << 30, disks: [DiskConfig(path: "disk.img")],
                                  networks: [NetworkConfig(macAddress: "02:00:00:00:00:01")])
            try bundle.saveConfig(config)
            return bundle
        }
    }

    @Test func saveCopiesStateButNotSnapshots() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeSource()
        let template = try await VMTemplate.save(source, as: "base", in: templates)

        #expect(template.url.deletingLastPathComponent().standardizedFileURL == templates.root.standardizedFileURL)
        #expect(try template.loadConfig().name == "base")
        #expect(try source.loadConfig().name == "src")
        #expect(!FileManager.default.fileExists(atPath: template.snapshotsURL.path))
        #expect(try Data(contentsOf: template.machineIdentifierURL) != Data(contentsOf: source.machineIdentifierURL))
        #expect(try templates.template(named: "base") == template)
        #expect(VMTemplate.summaries(in: templates).map(\.name) == ["base"])
        #expect(VMTemplate.summaries(in: templates).first?.diskSize == 16 << 30)
    }

    @Test func instantiateAppliesResourcesWithNewIdentity() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try await VMTemplate.save(makeSource(), as: "base", in: templates)
        let vm = try await VMTemplate.instantiate(template, as: "dev", in: library, cpuCount: 4, memorySize: 4 << 30, diskSize: 32 << 30) {
            $0.audio = false
        }

        let config = try vm.loadConfig()
        #expect(config.name == "dev" && config.cpuCount == 4 && config.memorySize == 4 << 30)
        #expect(!config.audio && config.networks.first?.macAddress != "02:00:00:00:00:01")
        #expect(try DiskImage.allocatedSize(at: vm.diskURL).logical == 32 << 30)
        #expect(try Data(contentsOf: vm.machineIdentifierURL) != Data(contentsOf: template.machineIdentifierURL))
        #expect(try library.bundle(named: "dev") == vm)
    }

    @Test func instantiateRejectsSmallerDiskWithoutLeavingBundle() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try await VMTemplate.save(makeSource(), as: "base", in: templates)
        await #expect(throws: MacVMError.self) {
            _ = try await VMTemplate.instantiate(template, as: "dev", in: library, diskSize: 8 << 30)
        }
        #expect(!FileManager.default.fileExists(atPath: library.bundleURL(named: "dev").path))
    }

    @Test func saveRefusesSuspendedMachine() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeSource()
        try Data().write(to: source.savedStateURL)
        await #expect(throws: MacVMError.self) { _ = try await VMTemplate.save(source, as: "base", in: templates) }
        #expect(!FileManager.default.fileExists(atPath: templates.storage.bundleURL(named: "base").path))
    }

    @Test func missingTemplateHasOwnError() {
        #expect(throws: MacVMError.templateNotFound("nope")) { _ = try templates.template(named: "nope") }
        #expect(throws: MacVMError.templateNotFound("nope")) { try VMTemplate.delete(named: "nope", in: templates) }
    }

    @Test func deleteRemovesPartialTemplate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = templates.storage.bundleURL(named: "half")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(VMTemplate.summaries(in: templates).isEmpty)
        try VMTemplate.delete(named: "half", in: templates)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

struct SnapshotTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "macvm-snapshot-tests-\(UUID().uuidString)")
    var library: VMLibrary { VMLibrary(root: root) }

    private func makeBundle() async throws -> VMBundle {
        try await VMFactory.withNewBundle(named: "vm", in: library) { bundle in
            try Data("before".utf8).write(to: bundle.diskURL)
            try bundle.saveConfig(VMConfig(name: "vm", os: .linux, cpuCount: 2, memorySize: 2 << 30, disks: [DiskConfig(path: "disk.img")]))
            return bundle
        }
    }

    @Test func restoreReplacesStateFiles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try await makeBundle()
        _ = try Snapshot.save(bundle, name: "s1")
        try Data("after".utf8).write(to: bundle.diskURL)
        try Snapshot.restore(bundle, name: "s1")
        #expect(try Data(contentsOf: bundle.diskURL) == Data("before".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
        #expect(try Snapshot.list(bundle).map(\.name) == ["s1"])
    }

    @Test func namesOutsideSnapshotsDirectoryAreRejected() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try await makeBundle()
        _ = try Snapshot.save(bundle, name: "s1")
        for name in ["..", "../..", "../disk.img", "s1/.."] {
            #expect(throws: MacVMError.self) { try Snapshot.delete(bundle, name: name) }
            #expect(throws: MacVMError.self) { try Snapshot.restore(bundle, name: name) }
        }
        #expect(FileManager.default.fileExists(atPath: bundle.diskURL.path))
    }

    @Test func listSkipsSnapshotWhoseNameIsNotItsDirectory() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try await makeBundle()
        _ = try Snapshot.save(bundle, name: "s1")
        let metadata = bundle.snapshotsURL.appending(path: "s1/snapshot.json")
        let forged = try String(contentsOf: metadata, encoding: .utf8).replacingOccurrences(of: "\"s1\"", with: "\"../..\"")
        try forged.write(to: metadata, atomically: true, encoding: .utf8)
        #expect(try Snapshot.list(bundle).isEmpty)
    }
}

struct DiskImageTests {
    @Test func sizeBeyondFileOffsetRangeThrows() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "macvm-disk-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: MacVMError.self) { try DiskImage.createSparse(at: url, size: UInt64(Int64.max) + 1) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

struct TemplateSettingsTests {
    @Test func templatePathIsOptional() throws {
        let old = try JSONDecoder().decode(MacVMSettings.self, from: Data(#"{"libraryPath":"/tmp/vms"}"#.utf8))
        #expect(old.templatePath == nil && old.templateRoot == TemplateLibrary.defaultRoot)
        let custom = MacVMSettings(templatePath: "~/Templates")
        #expect(custom.templateRoot.path(percentEncoded: false).hasSuffix("/Templates/"))
        #expect(!custom.templateRoot.path(percentEncoded: false).hasPrefix("~"))
    }
}
