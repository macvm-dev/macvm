import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Forward: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Forward host TCP ports to a running VM until you press Ctrl-C."),
        discussion: String(l10n: """
        Each forward is [address:]host-port:guest-port. The address defaults to 127.0.0.1 (this Mac only); use 0.0.0.0 to let other devices on the network connect.
        Nothing is saved in the VM's configuration; to forward ports whenever the VM runs, use macvm set --add-forward.
        Once every port is listening, the command prints the result (one line with --json) and keeps running. It exits when you press Ctrl-C, or with not_running when the VM stops.
          macvm forward dev 8080:80 0.0.0.0:2222:22
        """)
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
    @Argument(help: ArgumentHelp(String(l10n: "Forwards as [address:]host-port:guest-port."))) var forwards: [String]

    struct Result: Encodable, Sendable { let forwards: [PortForward] }

    func validate() throws {
        if forwards.isEmpty { throw ValidationError(String(l10n: "Give at least one forward, e.g. 8080:80")) }
    }

    @MainActor
    func run() async throws {
        var forwarder: PortForwarder?
        try await Output.run(json: global.json, human: { (r: Result) in
            r.forwards.map { String(l10n: "Forwarding \($0.address):\(String($0.hostPort)) → guest port \(String($0.guestPort))") }.joined(separator: "\n")
        }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            let specs = try PortForward.parseAll(forwards)
            guard BundleLock.holder(of: bundle) != nil else { throw MacVMError.notRunning(name) }
            let started = PortForwarder(bundle: bundle) { forward, error in
                let message = (error as? MacVMError)?.message ?? error.localizedDescription
                FileHandle.standardError.write(Data("macvm: \(forward.spec): \(message)\n".utf8))
            }
            if let error = PortForwarder.combined(started.apply(specs)) {
                started.close()
                throw error
            }
            forwarder = started
            return Result(forwards: specs)
        }
        guard let forwarder else { return }
        defer { forwarder.close() }
        let bundle = try VMLibrary.default.bundle(named: name)
        let stop = StopSignal()
        while !stop.received {
            if BundleLock.holder(of: bundle) == nil {
                FileHandle.standardError.write(Data("macvm: \(MacVMError.notRunning(name).message)\n".utf8))
                throw ExitCode(MacVMError.notRunning(name).exitCode)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// 记下是否收到过 SIGINT 或 SIGTERM。
@MainActor
private final class StopSignal {
    private(set) var received = false
    private var sources: [any DispatchSourceSignal] = []

    init() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.received = true } }
            source.resume()
            sources.append(source)
        }
    }
}
