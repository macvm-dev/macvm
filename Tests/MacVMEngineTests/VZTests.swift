import Foundation
@testable import MacVMEngine
import MacVMModel
import Testing
import Virtualization

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
