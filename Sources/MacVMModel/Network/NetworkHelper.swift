public import Foundation

/// 网络辅助程序 macvm-netd：随 App 安装的 root 守护进程，替引擎以 vmnet 的桥接模式收发以太网帧。
/// vmnet 的桥接模式要求 root 或 Apple 不对外发放的 entitlement，引擎所在的进程两者都没有。
public enum NetworkHelper {
    public static let machServiceName = "cn.barey.macvm.netd"
    /// `SMAppService.daemon(plistName:)` 用的文件名，放在 App 的 `Contents/Library/LaunchDaemons` 下。
    public static let launchdPlistName = "cn.barey.macvm.netd.plist"

    public static func serviceInterface() -> NSXPCInterface { NSXPCInterface(with: (any NetworkHelperService).self) }
    public static func clientInterface() -> NSXPCInterface { NSXPCInterface(with: (any NetworkHelperClient).self) }
}

/// 辅助进程导出的接口。每条 XPC 连接至多一条桥接，连接断开时桥接随之拆除。
@objc public protocol NetworkHelperService {
    /// 确认辅助进程在运行；回传它看到的可桥接网卡（BSD 名）。
    func ping(reply: @escaping @Sendable ([String]) -> Void)

    /// 桥接到主机网卡 `interface`，回传一端 `SOCK_DGRAM` 的 Unix socket，每个数据报是一个以太网帧。
    /// `macAddress` 是客户机网卡的地址，辅助进程只从源地址是它的帧里认 IP。失败时句柄为 nil，附错误说明。
    func openBridge(interface: String, macAddress: String, reply: @escaping @Sendable (FileHandle?, String?) -> Void)
}

/// 连接辅助进程的一方导出的接口。
@objc public protocol NetworkHelperClient {
    /// 从客户机发出的 ARP 里认出的 IPv4 地址变了。
    func guestAddressChanged(_ address: String)
}
