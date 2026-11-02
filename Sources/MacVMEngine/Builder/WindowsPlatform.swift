import Foundation
import MacVMModel
import MacVMPrivate
@preconcurrency import Virtualization

extension ConfigBuilder {
    func configureWindowsPlatform(_ vz: VZVirtualMachineConfiguration) throws {
        let platform = try genericPlatform()
        guard PrivateVZ.setPMUEmulation(true, on: platform) else {
            throw MacVMError.unsupported("当前 macOS 的 Virtualization.framework 不提供 PMU 模拟，无法运行 Windows")
        }
        vz.platform = platform
        vz.bootLoader = try efiBootLoader()
    }
}

public enum WindowsSupport {
    /// 本机能否运行 Windows 客户机。
    public static var isAvailable: Bool {
        PrivateVZ.supportsPMUEmulation(on: VZGenericPlatformConfiguration())
    }
}
