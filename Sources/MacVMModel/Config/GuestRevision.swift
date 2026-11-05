/// 客户机里由安装流程做好的配置的修订号，每个系统各自计数，记在 `VMConfig.guestRevision`。
/// 安装流程每多做一件已有虚拟机里没有的事就加一，同时在引擎里补一条把已有虚拟机带到这一修订的迁移。
public enum GuestRevision {
    public static func latest(for os: GuestOS) -> Int {
        switch os {
        case .windows: 2
        case .linux, .macOS: 0
        }
    }
}
