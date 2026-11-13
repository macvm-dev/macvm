import Foundation

/// 第一次 SIGINT/SIGTERM 请求客户机关机，第二次立即断电。
@MainActor
public final class SignalHandler {
    private var sources: [any DispatchSourceSignal] = []
    private var requested = false

    public init(runner: any MachineRunner) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self, weak runner] in
                MainActor.assumeIsolated {
                    guard let self, let runner else { return }
                    if !self.requested, (try? runner.requestStop()) != nil {
                        self.requested = true
                        FileHandle.standardError.write(Data(("\n" + String(l10n: "Asked the guest to shut down. Press Ctrl-C again to power off immediately.") + "\n").utf8))
                    } else {
                        Task { try? await runner.forceStop() }
                    }
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    public func cancel() {
        sources.forEach { $0.cancel() }
    }
}
