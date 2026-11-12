import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Set: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Change the configuration of a stopped VM."),
        discussion: String(l10n: """
        --engine switches the virtualization engine without touching the disk or the installed system. For Windows, for example, use vz for everyday builds and tests (lowest overhead) and switch to qemu when you need sound or suspend.
        macOS guests can only use vz.
        --retina applies only to QEMU VMs and Linux on VZ shown in the app's window. You can change it while the VM is running; it takes effect the next time an open window is resized.
        --clipboard syncs the text clipboard between the app's window and the guest (on by default). macOS and Windows guests sync through the agent, so you can change this while they run; Linux guests sync through spice-vdagent and must be shut down first.
        --screen-lock sets whether the guest locks its screen once it's idle and the display has gone to sleep (off by default). The guest agent applies it in the guest: right away if the VM is running, otherwise when the agent starts at the next boot. macOS guests need the guest password saved in the VM bundle.
        --disk-size only grows the system disk image; you need to expand the partition in the guest yourself, except for Linux from cloud images, which expands it automatically at the next boot.
        --remove-share runs before --add-share, so to make a shared folder read-only or writable, remove it and add it back. Shared folders work only with macOS and Linux guests on the VZ engine.
        --add-forward forwards a TCP port on the host to a port in the guest while the VM runs, written as [address:]host-port:guest-port. The address defaults to 127.0.0.1 (this Mac only); use 0.0.0.0 to let other devices on the network connect. You can change forwards while the VM is running; they take effect right away. --remove-forward takes the host port, address:host-port, or the full forward, and runs before --add-forward.
        """)
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
    @Option(help: ArgumentHelp(String(l10n: "Virtualization engine: vz or qemu."))) var engine: Engine?
    @Option(name: .customLong("cpus"), help: ArgumentHelp(String(l10n: "Number of vCPUs."))) var cpuCount: Int?
    @Option(help: ArgumentHelp(String(l10n: "Memory size, e.g. 8G."))) var memory: String?
    @Option(help: ArgumentHelp(String(l10n: "Display size at startup as WIDTHxHEIGHT, e.g. 2560x1600."))) var display: String?
    @Option(help: ArgumentHelp(String(l10n: "Use full Retina resolution in the app's window (QEMU engine and Linux on VZ): on or off."))) var retina: Toggle?
    @Option(help: ArgumentHelp(String(l10n: "Sync the text clipboard: on or off."))) var clipboard: Toggle?
    @Option(help: ArgumentHelp(String(l10n: "Lock the screen when the guest is idle: on or off."))) var screenLock: Toggle?
    @Option(help: ArgumentHelp(String(l10n: "Grow the system disk to this size, e.g. 256G (disks can't shrink)."))) var diskSize: String?
    @Option(help: ArgumentHelp(String(l10n: "Add a shared folder as host-path[:name][:ro] (repeatable)."))) var addShare: [String] = []
    @Option(help: ArgumentHelp(String(l10n: "Remove a shared folder by host path or name (repeatable)."))) var removeShare: [String] = []
    @Option(help: ArgumentHelp(String(l10n: "Forward a host TCP port to the guest as [address:]host-port:guest-port (repeatable)."))) var addForward: [String] = []
    @Option(help: ArgumentHelp(String(l10n: "Remove a port forward by host port, address:host-port, or the full forward (repeatable)."))) var removeForward: [String] = []

    enum Toggle: String, ExpressibleByArgument { case on, off }

    func validate() throws {
        if let display, Display.parse(display) == nil { throw ValidationError(String(l10n: "Size must be WIDTHxHEIGHT, e.g. 2560x1600")) }
    }

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in String(l10n: "Updated \(s.name)") }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            var config = try bundle.loadConfig()
            let onlyLive = engine == nil && cpuCount == nil && memory == nil && display == nil
                && diskSize == nil && addShare.isEmpty && removeShare.isEmpty
                && (clipboard == nil || !config.clipboardChangeNeedsStop)
            if !onlyLive { try bundle.requireStopped() }
            if let retina { config.display.retina = retina == .on }
            if let clipboard { config.clipboard = clipboard == .on }
            if let screenLock { config.screenLock = screenLock == .on }
            for share in removeShare {
                // 先于换引擎：移除最后的共享目录后才能换到 qemu。名称原样匹配，路径要与添加时一样标准化；都不匹配时按原样报错。
                let path = Create.standardizedPath(share)
                try config.removeShare(config.shares.first { $0.tag == share || $0.hostPath == path }?.hostPath ?? share)
            }
            if let engine { try config.switchEngine(to: engine) }
            if let cpuCount { config.cpuCount = cpuCount }
            if let memory { config.memorySize = try ByteSize.parse(memory) }
            if let display, let (width, height) = Display.parse(display) {
                if config.os == .windows, config.engine == .vz { throw WindowsSupport.fixedDisplayError }
                config.display.width = width
                config.display.height = height
            }
            for spec in try addShare.map(Create.parseShare) {
                try config.addShare(hostPath: spec.hostPath, tag: spec.tag, readOnly: spec.readOnly)
            }
            for forward in removeForward { try config.removeForward(forward) }
            for forward in try addForward.map(PortForward.parse) { try config.addForward(forward) }
            // 磁盘在所有配置改动校验之后才扩大：配置有错时镜像保持原样。
            if let diskSize { try DiskImage.grow(at: bundle.diskURL, to: ByteSize.parse(diskSize)) }
            try bundle.saveConfig(config)
            // 监听失败时配置照样保存、命令报错。
            if !(addForward.isEmpty && removeForward.isEmpty), BundleLock.holder(of: bundle) != nil {
                try ControlClient.applyForwards(bundle)
            }
            if screenLock != nil, config.guestAgent, BundleLock.holder(of: bundle) != nil {
                try GuestScreenLock.apply(bundle, config: config)
            }
            return try VMStatus.summary(of: bundle)
        }
    }
}
