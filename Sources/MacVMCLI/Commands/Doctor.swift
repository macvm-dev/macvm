import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "检查本机与本程序签名对各项功能的支持情况。")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await Output.run(json: global.json, human: Self.render) { HostCapabilities.current() }
    }

    static func render(_ c: HostCapabilities) -> String {
        func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        return """
        macOS \(c.hostOS)，\(c.performanceCores) 个性能核，内存 \(ByteSize.format(c.physicalMemory))
        \(mark(c.virtualization)) 虚拟化（Apple Silicon + com.apple.security.virtualization）
        \(mark(c.windows)) Windows 客户机用 VZ 运行（Virtualization.framework PMU 模拟）
        \(mark(c.qemu != nil)) QEMU 引擎\(c.qemu.map { "：" + $0 } ?? "（brew install qemu；安装 Windows 需要）")
        \(mark(c.rosetta)) Linux Rosetta\(c.rosetta ? "" : "（softwareupdate --install-rosetta）")
        \(mark(c.bridgedNetworking)) 桥接网络（com.apple.vm.networking）\(c.bridgeInterfaces.isEmpty ? "" : "：" + c.bridgeInterfaces.joined(separator: ", "))
        \(mark(c.saveRestore)) 挂起恢复
        虚拟机目录：\(c.libraryPath)
        """
    }
}
