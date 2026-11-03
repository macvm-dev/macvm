/// 运行虚拟机的虚拟化引擎。
public enum Engine: String, Codable, Sendable, CaseIterable {
    /// Apple Virtualization.framework：资源占用最低，macOS 客户机唯一可用的引擎。
    case vz
    /// Homebrew 安装的 QEMU（hvf 加速）：功能更全（声音、Windows 挂起、原版安装程序），占用更高。
    case qemu
}
