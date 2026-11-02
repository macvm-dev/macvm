public import ArgumentParser
import Foundation
import MacVMEngine
public import MacVMModel

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "创建虚拟机。",
        discussion: """
        Linux 云镜像（推荐）：--image 指定镜像，首次使用时下载并缓存；开机即带用户与 macvm 专用 SSH 密钥。
          macvm create dev --image debian-13 --memory 8G
        安装介质：创建空磁盘，从 --iso 指定的介质启动安装（Linux、Windows）。
          macvm create box --os linux --iso ~/Downloads/fedora-aarch64.iso
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "虚拟机名称（字母、数字、. _ -，最长 40）。")
    var name: String

    @Option(help: "客户机系统：linux、windows、macos。")
    var os: GuestOS = .linux

    @Option(name: .customLong("cpus"), help: "vCPU 数，默认为主机性能核数。")
    var cpuCount: Int?

    @Option(help: "内存，如 4G。默认 Linux 4G、其他 8G，且不超过主机内存一半。")
    var memory: String?

    @Option(help: "磁盘容量（稀疏，按实际写入占用），如 64G。")
    var disk: String?

    @Option(help: ArgumentHelp("Linux 云镜像。", valueName: LinuxImage.catalog.map(\.id).joined(separator: "|")))
    var image: String?

    @Option(help: "云镜像里创建的登录用户，默认与主机用户同名。")
    var user: String = NSUserName()

    @Option(name: .customLong("iso"), help: "以只读 U 盘挂载的安装介质，可重复。")
    var installMedia: [String] = []

    @Option(help: "共享目录：主机路径[:tag][:ro]，可重复。")
    var share: [String] = []

    @Option(help: "网络：nat 或 bridged[:网卡名]。")
    var network: String = "nat"

    @Flag(help: "Linux：挂载 Rosetta，运行 x86_64 程序。")
    var rosetta = false

    @Flag(inversion: .prefixedNo, help: "不挂键盘鼠标，只用 SSH 访问；可挂起。云镜像默认开启，安装介质默认关闭。")
    var headless: Bool?

    @Flag(help: "后台运行时把客户机控制台输出写进 run.log。")
    var console = false

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in "已创建 \(s.name)：\(s.path)" }) {
            guard os.usesEFI else {
                throw MacVMError.invalidConfig("macOS 客户机请用 macvm install-macos 创建")
            }
            let options = VMFactory.Options(
                name: name, os: os, cpuCount: cpuCount,
                memorySize: try memory.map(ByteSize.parse), diskSize: try disk.map(ByteSize.parse),
                installMedia: installMedia, network: try Self.parseNetwork(network),
                shares: try share.map(Self.parseShare), rosetta: rosetta, serialConsole: console,
                image: try image.map(LinuxImage.named), user: user,
                showProgress: !global.json && isatty(STDERR_FILENO) == 1, headless: headless
            )
            let bundle = try await VMFactory.createEFIGuest(options)
            SSHConfigCommand.refresh()
            return try VMStatus.summary(of: bundle)
        }
    }

    static func parseNetwork(_ text: String) throws -> NetworkConfig {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "nat": return NetworkConfig(mode: .nat)
        case "bridged": return NetworkConfig(mode: .bridged, interface: parts.count > 1 ? parts[1] : nil)
        default: throw MacVMError.invalidConfig("未知网络模式：\(text)（可选 nat、bridged[:网卡名]）")
        }
    }

    static func parseShare(_ text: String) throws -> ShareConfig {
        var parts = text.split(separator: ":").map(String.init)
        guard let first = parts.first else { throw MacVMError.invalidConfig("共享目录参数为空") }
        let path = URL(filePath: (first as NSString).expandingTildeInPath).standardizedFileURL.path
        parts.removeFirst()
        let readOnly = parts.last == "ro"
        if readOnly { parts.removeLast() }
        let tag = parts.first ?? URL(filePath: path).lastPathComponent
        return ShareConfig(hostPath: path, tag: tag, readOnly: readOnly)
    }
}

extension GuestOS: ExpressibleByArgument {}
