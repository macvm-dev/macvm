import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Proxy: AsyncParsableCommand {
    /// 客户机刚开机时端口还没监听，重试到超时。
    static func openWithRetry(_ bundle: VMBundle, config: VMConfig, port: UInt16, timeout: Int) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while true {
            do {
                let fd = try await GuestConnection.open(bundle, config: config, port: port, timeout: TimeInterval(timeout))
                if config.engine != .qemu { return fd }
                // QEMU 的用户态网络先接受连接，客户机端口没人监听时随即关闭。SSH 服务端先发握手串，
                // 所以 22 端口要等到 "SSH-" 才算通；其他端口由客户端先说话，只能确认没有立即被关闭。
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, port == 22 ? 5000 : 300)
                var head = [UInt8](repeating: 0, count: 4)
                let n = ready == 1 ? recv(fd, &head, 4, MSG_PEEK) : -1
                if (ready == 1 && n <= 0) || (port == 22 && (n < 4 || head != Array("SSH-".utf8))) {
                    close(fd)
                    throw MacVMError.notRunning("客户机端口 \(port) 未就绪")
                }
                return fd
            } catch {
                guard Date() < deadline else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    static let configuration = CommandConfiguration(
        abstract: "把标准输入输出接到客户机的 TCP 端口，供 ssh 的 ProxyCommand 使用。",
        discussion: "虚拟机未运行时自动在后台启动；上次是关机或断电停下的不启动，先用 macvm start 开机。"
    )

    @Argument(help: "虚拟机名称。") var name: String
    @Option(help: "客户机端口。") var port: UInt16 = 22
    @Option(help: "等待客户机就绪的最长秒数。") var timeout: Int = 120
    @Flag(help: "不经客户机代理，直连客户机 IP（代理尚未安装时使用）。") var tcp = false

    func run() async throws {
        try await Output.run(json: false, human: { (_: Empty) in nil }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            if BundleLock.holder(of: bundle) == nil {
                // ssh 客户端断线后会自动重连，不能把用户刚关掉的虚拟机重新开起来。
                if bundle.wasPoweredOff { throw MacVMError.notRunning("\(name)（已关机，用 macvm start \(name) 或在 App 里开机后再连）") }
                _ = try await Start.launch(bundle, timeout: timeout)
            }
            var config = try bundle.loadConfig()
            if tcp { config.guestAgent = false }
            if config.guestAgent { try await Wait.untilReady(bundle, config: config, timeout: timeout) }
            let fd = try await Self.openWithRetry(bundle, config: config, port: port, timeout: timeout)
            GuestConnection.pump((STDIN_FILENO, STDOUT_FILENO), fd)
            close(fd)
            return Empty()
        }
    }
}
