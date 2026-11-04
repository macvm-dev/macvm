import Foundation
import MacVMModel

/// 一次新建虚拟机的请求。开始时存进 `CreationStore`，结束（成功或失败）时删掉；
/// App 中途退出留下的就是被中断的，下次启动时可以继续或放弃。
struct CreationRequest: Codable, Sendable, Equatable {
    enum Source: Codable, Hashable, Sendable {
        case cloudImage(String)
        /// `LinuxDesktop` 的原始值。
        case desktop(String)
        case iso, ipswLatest, ipswFile
        /// 从微软下载 Windows ISO。
        case windowsLatest
        /// 模板名。
        case template(String)

        var isCloudImage: Bool {
            if case .cloudImage = self { true } else { false }
        }

        var template: String? {
            if case .template(let name) = self { name } else { nil }
        }
    }

    var name: String
    var os: GuestOS
    var source: Source
    var cpus: Int
    var memoryGB: Int
    var diskGB: Int
    var rosetta: Bool
    /// 用户选的 ISO 或 IPSW。
    var file: URL?
    var productKey: String?
    /// 客户机登录用户名；nil 时与主机用户同名。
    var user: String?
    /// 客户机登录密码；nil 时 macOS、Windows、自动安装的 Ubuntu 桌面版随机生成，Linux 云镜像只能用 SSH 密钥登录。
    var password: String?
    /// 桌面版不自动安装，开机后在窗口里图形安装；nil 等同 false。
    var manualInstall: Bool?
    /// 建包时作为 `VMBundle.creationMarkerURL` 的令牌写进包里，用来认出本请求留下的半成品。
    var id = UUID()
}

/// 未结束的新建请求，存在设置文件旁的 `creations.json`。含客户机密码与 Windows 产品密钥，文件只给本用户读写。
enum CreationStore {
    static var fileURL: URL {
        MacVMSettings.fileURL.deletingLastPathComponent().appending(path: "creations.json")
    }

    static func load() -> [CreationRequest] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CreationRequest].self, from: data)) ?? []
    }

    static func save(_ requests: [CreationRequest]) throws {
        let url = fileURL
        guard !requests.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(requests).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
