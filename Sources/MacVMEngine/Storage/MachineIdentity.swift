import Foundation
import MacVMModel
@preconcurrency import Virtualization

/// 包内机器标识文件的创建与读取。克隆后必须重新生成，否则两台虚拟机会被客户机视为同一台机器。
enum MachineIdentity {
    static func createGeneric(in bundle: VMBundle) throws {
        try write(VZGenericMachineIdentifier().dataRepresentation, to: bundle.machineIdentifierURL)
    }

    static func loadGeneric(from bundle: VMBundle) throws -> VZGenericMachineIdentifier {
        guard let id = VZGenericMachineIdentifier(dataRepresentation: try read(bundle.machineIdentifierURL)) else {
            throw MacVMError.invalidConfig(String(l10n: "Corrupt machine identifier: \(bundle.machineIdentifierURL.path)"))
        }
        return id
    }

    static func createMac(in bundle: VMBundle) throws {
        try write(VZMacMachineIdentifier().dataRepresentation, to: bundle.machineIdentifierURL)
    }

    static func loadMac(from bundle: VMBundle) throws -> VZMacMachineIdentifier {
        guard let id = VZMacMachineIdentifier(dataRepresentation: try read(bundle.machineIdentifierURL)) else {
            throw MacVMError.invalidConfig(String(l10n: "Corrupt machine identifier: \(bundle.machineIdentifierURL.path)"))
        }
        return id
    }

    static func saveHardwareModel(_ model: VZMacHardwareModel, in bundle: VMBundle) throws {
        try write(model.dataRepresentation, to: bundle.hardwareModelURL)
    }

    static func loadHardwareModel(from bundle: VMBundle) throws -> VZMacHardwareModel {
        guard let model = VZMacHardwareModel(dataRepresentation: try read(bundle.hardwareModelURL)) else {
            throw MacVMError.invalidConfig(String(l10n: "Corrupt hardware model: \(bundle.hardwareModelURL.path)"))
        }
        guard model.isSupported else {
            throw MacVMError.unsupported(String(l10n: "This Mac doesn't support the virtual machine's hardware model; update macOS on this Mac"))
        }
        return model
    }

    static func regenerate(in bundle: VMBundle, os: GuestOS) throws {
        switch os {
        case .macOS: try createMac(in: bundle)
        case .linux, .windows: try createGeneric(in: bundle)
        }
    }

    private static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch {
            throw MacVMError.io(String(l10n: "Couldn't read \(url.path): \(error.localizedDescription)"))
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .atomic) } catch {
            throw MacVMError.io(String(l10n: "Couldn't write \(url.path): \(error.localizedDescription)"))
        }
    }
}
