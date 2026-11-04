import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct IP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "显示虚拟机的 IP 地址。")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String
    @Option(help: "最多等待的秒数。") var wait: Int = 0

    struct Result: Encodable, Sendable { let ipAddress: String }

    func run() async throws {
        try await Output.run(json: global.json, human: { (r: Result) in r.ipAddress }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            guard let ip = try await VMStatus.waitForIPAddress(bundle, timeout: TimeInterval(wait), interval: 1) else {
                throw BundleLock.holder(of: bundle) == nil ? MacVMError.notRunning(name) : MacVMError.timeout("未找到 \(name) 的 DHCP 租约")
            }
            return Result(ipAddress: ip)
        }
    }
}
