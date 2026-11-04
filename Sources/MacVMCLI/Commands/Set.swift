import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Set: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "修改已停止虚拟机的配置。",
        discussion: """
        --engine 切换虚拟化引擎，磁盘与系统保持不变。例如 Windows：日常编译测试用 vz（占用最低），需要声音或挂起时切到 qemu。
        macOS 客户机只能用 vz。
        --retina 只影响应用窗口里 QEMU 虚拟机的分辨率，运行中也可修改，打开的窗口下次调整大小时生效。
        --disk-size 只扩大系统盘镜像，客户机里的分区要另行扩展（云镜像建的 Linux 下次开机自动扩展）。
        --remove-share 先于 --add-share 执行，先移除再加回即可改只读。共享目录只用于 VZ 引擎的 macOS、Linux 客户机。
        """
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String
    @Option(help: "虚拟化引擎：vz 或 qemu。") var engine: Engine?
    @Option(name: .customLong("cpus"), help: "vCPU 数。") var cpuCount: Int?
    @Option(help: "内存，如 8G。") var memory: String?
    @Option(help: "开机时的显示尺寸，宽x高，如 2560x1600。") var display: String?
    @Option(help: "应用窗口里按屏幕像素请求分辨率（QEMU 引擎）：on 或 off。") var retina: Toggle?
    @Option(help: "扩大系统盘到此容量，如 256G；只能扩大。") var diskSize: String?
    @Option(help: "添加共享目录：主机路径[:名称][:ro]，可重复。") var addShare: [String] = []
    @Option(help: "移除共享目录：主机路径或名称，可重复。") var removeShare: [String] = []

    enum Toggle: String, ExpressibleByArgument { case on, off }

    func validate() throws {
        if let display, Display.parse(display) == nil { throw ValidationError("尺寸格式应为 宽x高，如 2560x1600") }
    }

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in "已更新 \(s.name)" }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            let onlyRetina = engine == nil && cpuCount == nil && memory == nil && display == nil
                && diskSize == nil && addShare.isEmpty && removeShare.isEmpty
            if !onlyRetina { try bundle.requireStopped() }
            var config = try bundle.loadConfig()
            if let retina { config.display.retina = retina == .on }
            for share in removeShare {
                // 先于换引擎：移除最后的共享目录后才能换到 qemu。名称原样匹配，路径要与添加时一样标准化；都不匹配时按原样报错。
                let path = Create.standardizedPath(share)
                try config.removeShare(config.shares.first { $0.tag == share || $0.hostPath == path }?.hostPath ?? share)
            }
            if let engine { try config.switchEngine(to: engine) }
            if let cpuCount { config.cpuCount = cpuCount }
            if let memory { config.memorySize = try ByteSize.parse(memory) }
            if let display, let (width, height) = Display.parse(display) {
                if config.os == .windows { throw WindowsSupport.fixedDisplayError }
                config.display.width = width
                config.display.height = height
            }
            for spec in try addShare.map(Create.parseShare) {
                try config.addShare(hostPath: spec.hostPath, tag: spec.tag, readOnly: spec.readOnly)
            }
            // 磁盘在所有配置改动校验之后才扩大：配置有错时镜像保持原样。
            if let diskSize { try DiskImage.grow(at: bundle.diskURL, to: ByteSize.parse(diskSize)) }
            try bundle.saveConfig(config)
            return try VMStatus.summary(of: bundle)
        }
    }
}
