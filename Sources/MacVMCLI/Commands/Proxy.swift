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
                    throw MacVMError.notRunning(String(l10n: "guest port \(port) isn't ready"))
                }
                return fd
            } catch {
                guard Date() < deadline else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Connect stdin and stdout to a TCP port on the guest (for use as an ssh ProxyCommand)."),
        discussion: String(l10n: "Starts the VM in the background if it isn't running. A VM that was shut down or powered off stays off; start it with macvm start first.")
    )

    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
    @Option(help: ArgumentHelp(String(l10n: "Guest port."))) var port: UInt16 = 22
    @Option(help: ArgumentHelp(String(l10n: "Seconds to wait for the guest to be ready."))) var timeout: Int = 120
    @Flag(help: ArgumentHelp(String(l10n: "Connect to the guest's IP address directly instead of through the guest agent (useful before the agent is installed)."))) var tcp = false

    func run() async throws {
        try await Output.run(json: false, human: { (_: Empty) in nil }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            if BundleLock.holder(of: bundle) == nil {
                // ssh 客户端断线后会自动重连，不能把用户刚关掉的虚拟机重新开起来。
                if bundle.wasPoweredOff { throw MacVMError.notRunning(String(l10n: "\(name) (shut down; start it with macvm start \(name) or in the app, then reconnect)")) }
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
