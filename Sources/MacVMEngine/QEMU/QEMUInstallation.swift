public import Foundation
public import MacVMModel

/// 用户经 Homebrew 安装的 QEMU：可执行文件与 aarch64 UEFI 固件。
public struct QEMUInstallation: Sendable {
    public let binary: URL
    public let firmwareCode: URL
    /// 新建虚拟机时复制一份作为该机的 EFI 变量存储。
    public let firmwareVarsTemplate: URL

    /// 查找顺序：环境变量 `MACVM_QEMU`（可执行文件路径），Homebrew 的 Apple Silicon 与 Intel 前缀。
    public static func locate() -> QEMUInstallation? {
        var candidates: [String] = []
        if let custom = ProcessInfo.processInfo.environment["MACVM_QEMU"] { candidates.append(custom) }
        candidates += ["/opt/homebrew/bin/qemu-system-aarch64", "/usr/local/bin/qemu-system-aarch64"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let binary = URL(filePath: path).resolvingSymlinksInPath()
            let share = binary.deletingLastPathComponent().deletingLastPathComponent().appending(path: "share/qemu")
            let code = share.appending(path: "edk2-aarch64-code.fd")
            let vars = share.appending(path: "edk2-arm-vars.fd")
            if FileManager.default.fileExists(atPath: code.path), FileManager.default.fileExists(atPath: vars.path) {
                return QEMUInstallation(binary: binary, firmwareCode: code, firmwareVarsTemplate: vars)
            }
        }
        return nil
    }

    public static func require() throws -> QEMUInstallation {
        guard let found = locate() else {
            throw MacVMError.unsupported("QEMU 引擎需要先安装 QEMU：brew install qemu")
        }
        return found
    }

    static func varsURL(_ bundle: VMBundle) -> URL { bundle.url.appending(path: "qemu-efi.vars") }

    /// 该虚拟机还没有 QEMU 用的 EFI 变量存储时从模板复制。
    func ensureVars(for bundle: VMBundle) throws {
        let url = Self.varsURL(bundle)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.copyItem(at: firmwareVarsTemplate, to: url)
    }
}
