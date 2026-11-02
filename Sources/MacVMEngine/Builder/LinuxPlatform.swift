import Foundation
import MacVMModel
@preconcurrency import Virtualization

extension ConfigBuilder {
    func configureLinuxPlatform(_ vz: VZVirtualMachineConfiguration) throws {
        vz.platform = try genericPlatform()
        vz.bootLoader = try efiBootLoader()
    }

    func genericPlatform() throws -> VZGenericPlatformConfiguration {
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try MachineIdentity.loadGeneric(from: bundle)
        return platform
    }

    func efiBootLoader() throws -> VZEFIBootLoader {
        let loader = VZEFIBootLoader()
        guard FileManager.default.fileExists(atPath: bundle.efiVariableStoreURL.path) else {
            throw MacVMError.invalidConfig("缺少 EFI 变量存储：\(bundle.efiVariableStoreURL.path)")
        }
        loader.variableStore = VZEFIVariableStore(url: bundle.efiVariableStoreURL)
        return loader
    }
}
