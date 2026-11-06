public import MacVMModel

extension VMConfig {
    /// 换用 `engine` 运行，磁盘与系统不变。macOS、有共享目录或开着 Rosetta 的只能用 vz；Windows 用 vz 需要本机支持且没装 3D 驱动；
    /// 安装中的虚拟机依赖 QEMU 的光驱启动与按键，不能换。
    public mutating func switchEngine(to engine: Engine) throws {
        guard engine != self.engine else { return }
        if engine == .qemu, os == .macOS { throw MacVMError.unsupported(String(l10n: "macOS guests can only use the vz engine")) }
        if engine == .qemu, !shares.isEmpty { throw MacVMError.unsupported(String(l10n: "The QEMU engine doesn't support shared folders; remove \(name)'s shared folders first")) }
        if engine == .qemu, rosetta { throw MacVMError.unsupported(String(l10n: "\(name) uses Rosetta, which the QEMU engine doesn't support, so it can only use the vz engine")) }
        if engine == .qemu { _ = try QEMUInstallation.require() }
        if engine == .vz, graphicsAcceleration {
            throw MacVMError.unsupported(String(l10n: "\(name) has the 3D graphics driver installed, so it can only use the qemu engine; VZ has no 3D support, and Windows would crash at startup"))
        }
        if engine == .vz, os == .windows, !WindowsSupport.isAvailable {
            throw MacVMError.unsupported(String(l10n: "This version of macOS can't run Windows with the vz engine"))
        }
        guard installMedia.isEmpty else { throw MacVMError.invalidConfig(String(l10n: "Can't switch engines until installation finishes")) }
        self.engine = engine
    }
}
