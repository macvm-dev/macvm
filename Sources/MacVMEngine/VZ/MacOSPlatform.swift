import Foundation
import MacVMModel
@preconcurrency import Virtualization

extension ConfigBuilder {
    func configureMacOSPlatform(_ vz: VZVirtualMachineConfiguration) throws {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = try MachineIdentity.loadHardwareModel(from: bundle)
        platform.machineIdentifier = try MachineIdentity.loadMac(from: bundle)
        guard FileManager.default.fileExists(atPath: bundle.auxiliaryStorageURL.path) else {
            throw MacVMError.invalidConfig(String(l10n: "Missing auxiliary storage: \(bundle.auxiliaryStorageURL.path)"))
        }
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()
    }
}
