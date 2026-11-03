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
        """
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String
    @Option(help: "虚拟化引擎：vz 或 qemu。") var engine: Engine?
    @Option(name: .customLong("cpus"), help: "vCPU 数。") var cpuCount: Int?
    @Option(help: "内存，如 8G。") var memory: String?
    @Option(help: "开机时的显示尺寸，宽x高，如 2560x1600。") var display: String?

    func validate() throws {
        if let display, Display.parse(display) == nil { throw ValidationError("尺寸格式应为 宽x高，如 2560x1600") }
    }

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in "已更新 \(s.name)" }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            if BundleLock.holder(of: bundle) != nil { throw MacVMError.alreadyRunning(name) }
            var config = try bundle.loadConfig()
            if let engine {
                if engine == .qemu, config.os == .macOS { throw MacVMError.unsupported("macOS 客户机只能用 vz 引擎") }
                if engine == .qemu { _ = try QEMUInstallation.require() }
                if engine == .vz, config.os == .windows, !WindowsSupport.isAvailable {
                    throw MacVMError.unsupported("当前 macOS 不支持用 vz 运行 Windows")
                }
                // 安装中的虚拟机依赖 QEMU 的光驱启动与按键，不能换引擎。
                guard config.installMedia.isEmpty || engine == config.engine else {
                    throw MacVMError.invalidConfig("安装尚未完成，不能切换引擎")
                }
                config.engine = engine
            }
            if let cpuCount { config.cpuCount = cpuCount }
            if let memory { config.memorySize = try ByteSize.parse(memory) }
            if let display, let (width, height) = Display.parse(display) {
                config.display.width = width
                config.display.height = height
            }
            try bundle.saveConfig(config)
            return try VMStatus.summary(of: bundle)
        }
    }
}
