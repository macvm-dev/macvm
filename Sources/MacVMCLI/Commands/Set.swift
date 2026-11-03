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
        """
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String
    @Option(help: "虚拟化引擎：vz 或 qemu。") var engine: Engine?
    @Option(name: .customLong("cpus"), help: "vCPU 数。") var cpuCount: Int?
    @Option(help: "内存，如 8G。") var memory: String?
    @Option(help: "开机时的显示尺寸，宽x高，如 2560x1600。") var display: String?
    @Option(help: "应用窗口里按屏幕像素请求分辨率（QEMU 引擎）：on 或 off。") var retina: Toggle?

    enum Toggle: String, ExpressibleByArgument { case on, off }

    func validate() throws {
        if let display, Display.parse(display) == nil { throw ValidationError("尺寸格式应为 宽x高，如 2560x1600") }
    }

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in "已更新 \(s.name)" }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            let onlyRetina = engine == nil && cpuCount == nil && memory == nil && display == nil
            if !onlyRetina, BundleLock.holder(of: bundle) != nil { throw MacVMError.alreadyRunning(name) }
            var config = try bundle.loadConfig()
            if let retina { config.display.retina = retina == .on }
            if let engine { try config.switchEngine(to: engine) }
            if let cpuCount { config.cpuCount = cpuCount }
            if let memory { config.memorySize = try ByteSize.parse(memory) }
            if let display, let (width, height) = Display.parse(display) {
                if config.os == .windows { throw WindowsSupport.fixedDisplayError }
                config.display.width = width
                config.display.height = height
            }
            try bundle.saveConfig(config)
            return try VMStatus.summary(of: bundle)
        }
    }
}
