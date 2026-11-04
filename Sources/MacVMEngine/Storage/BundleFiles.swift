import Foundation
import MacVMModel

/// 包内随虚拟机状态变化、需要随克隆与快照一起复制的文件（不含 `config.json`）。
enum BundleFiles {
    static func stateFiles(of bundle: VMBundle, config: VMConfig) -> [String] {
        var names = config.disks.filter { !$0.path.hasPrefix("/") && !$0.path.hasPrefix("~") }.map(\.path)
        for url in [bundle.auxiliaryStorageURL, bundle.efiVariableStoreURL, bundle.hardwareModelURL, bundle.machineIdentifierURL,
                    QEMUInstallation.varsURL(bundle)] {
            names.append(url.lastPathComponent)
        }
        return names.filter { FileManager.default.fileExists(atPath: bundle.url.appending(path: $0).path) }
    }
}
