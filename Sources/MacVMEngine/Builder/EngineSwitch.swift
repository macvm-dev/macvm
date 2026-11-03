public import MacVMModel

extension VMConfig {
    /// 换用 `engine` 运行，磁盘与系统不变。macOS 只能用 vz；Windows 用 vz 需要本机支持；
    /// 安装中的虚拟机依赖 QEMU 的光驱启动与按键，不能换。
    public mutating func switchEngine(to engine: Engine) throws {
        guard engine != self.engine else { return }
        if engine == .qemu, os == .macOS { throw MacVMError.unsupported("macOS 客户机只能用 vz 引擎") }
        if engine == .qemu { _ = try QEMUInstallation.require() }
        if engine == .vz, os == .windows, !WindowsSupport.isAvailable {
            throw MacVMError.unsupported("当前 macOS 不支持用 vz 运行 Windows")
        }
        guard installMedia.isEmpty else { throw MacVMError.invalidConfig("安装尚未完成，不能切换引擎") }
        self.engine = engine
    }
}
